import Foundation

@MainActor
@Observable
final class CommentModel {
    enum Sort: Int, CaseIterable {
        case hot = 3, time = 2

        var title: String { self == .hot ? "按热度" : "按时间" }
    }

    /// 评论区 oid（视频为 aid）
    let oid: Int
    /// 评论区类型：1 视频 · 11 图文动态 · 17 文字 / 转发动态
    let type: Int
    private(set) var sort: Sort = .hot
    private var loadedTop: [Reply] = []
    private var loadedReplies: [Reply] = []
    var top: [Reply] { loadedTop.filter { !isDeleted($0) } }
    var replies: [Reply] { loadedReplies.filter { !isDeleted($0) } }

    func isDeleted(_ reply: Reply) -> Bool {
        OwnedContentDeletion.shared.contains(reply, oid: oid, type: type)
    }
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var isEnd = false
    private(set) var error: String?
    /// 本地点赞状态（乐观更新），rpid → 是否已赞
    private(set) var likeOverrides: [Int: Bool] = [:]

    @ObservationIgnored private var offset = ""
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(oid: Int, type: Int = 1) {
        self.oid = oid
        self.type = type
    }

    func loadIfNeeded() {
        guard replies.isEmpty, top.isEmpty, !isLoading else { return }
        load(reset: true)
    }

    func reload() async {
        load(reset: true)
        await loadTask?.value
    }

    func toggleSort() {
        sort = sort == .hot ? .time : .hot
        load(reset: true)
    }

    func loadMore(after reply: Reply) {
        guard reply.id == replies.last?.id else { return }
        load(reset: false)
    }

    private func load(reset: Bool) {
        if reset {
            loadTask?.cancel()
            offset = ""
            isEnd = false
            isLoading = false
        }
        guard !isLoading, !isEnd else { return }
        isLoading = true
        let mode = sort.rawValue, offset = offset
        loadTask = Task {
            do {
                let page = try await BiliClient.shared.get(.replies(oid: oid, type: type, mode: mode, offset: offset), as: ReplyPage.self)
                guard !Task.isCancelled else { return }
                if reset {
                    loadedTop = page.topReplies ?? []
                    loadedReplies = []
                }
                let known = Set(loadedTop.map(\.id) + loadedReplies.map(\.id))
                loadedReplies += (page.replies ?? []).filter { !known.contains($0.id) }
                total = page.cursor.allCount ?? total
                self.offset = page.cursor.paginationReply?.nextOffset ?? ""
                isEnd = page.cursor.isEnd || self.offset.isEmpty
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: 点赞

    func isLiked(_ reply: Reply) -> Bool {
        likeOverrides[reply.id] ?? (reply.action == 1)
    }

    func likeCount(_ reply: Reply) -> Int {
        let original = reply.action == 1
        guard let override = likeOverrides[reply.id], override != original else { return reply.like }
        return reply.like + (override ? 1 : -1)
    }

    /// 先改界面再请求，失败回滚
    func toggleLike(_ reply: Reply) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能点赞") }
        let target = !isLiked(reply)
        likeOverrides[reply.id] = target
        do {
            try await BiliClient.shared.post(.replyAction, form: [
                "oid": "\(oid)", "type": "\(type)", "rpid": "\(reply.id)", "action": target ? "1" : "0", "csrf": csrf,
            ])
        } catch {
            likeOverrides[reply.id] = !target
            throw error
        }
    }

    // MARK: 发评论

    /// - Parameters:
    ///   - root: 楼层（回复楼中楼时为该楼主评论）
    ///   - parent: 直接回复的那条
    /// - Returns: 新评论；顶层评论会插到列表最前
    @discardableResult
    func send(_ text: String, root: Reply? = nil, parent: Reply? = nil) async throws -> Reply? {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能评论") }
        if let root, isDeleted(root) { throw BiliError.api(code: -404, message: "该评论已删除") }
        if let parent, isDeleted(parent) { throw BiliError.api(code: -404, message: "该回复已删除") }
        var form = ["oid": "\(oid)", "type": "\(type)", "message": text, "plat": "1", "csrf": csrf]
        if let root {
            form["root"] = "\(root.id)"
            form["parent"] = "\((parent ?? root).id)"
        }
        let result = try await BiliClient.shared.post(.replyAdd, form: form, as: ReplyAddResult.self)
        if root == nil, let reply = result.reply {
            loadedReplies.insert(reply, at: 0)
            total = (total ?? 0) + 1
        }
        return result.reply
    }
}

/// 楼中楼（评论详情）
@MainActor
@Observable
final class ReplyThreadModel {
    let oid: Int
    let type: Int
    let root: Reply
    private var loadedReplies: [Reply] = []
    var replies: [Reply] { loadedReplies.filter { !OwnedContentDeletion.shared.contains($0, oid: oid, type: type) } }
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var generation = 0

    var isEnd: Bool { total.map { loadedReplies.count >= $0 } ?? false }
    var visibleTotal: Int { max(0, (total ?? root.rcount) - (loadedReplies.count - replies.count)) }

    init(oid: Int, type: Int = 1, root: Reply) {
        self.oid = oid
        self.type = type
        self.root = root
    }

    func reload() async {
        generation += 1
        loadedReplies = []
        total = nil
        page = 1
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !isEnd else { return }
        let generation = generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let result = try await BiliClient.shared.get(.subReplies(oid: oid, type: type, root: root.id, page: page), as: SubReplyPage.self)
            guard !Task.isCancelled, generation == self.generation else { return }
            let known = Set(loadedReplies.map(\.id))
            let fresh = (result.replies ?? []).filter { !known.contains($0.id) }
            loadedReplies += fresh
            total = fresh.isEmpty ? loadedReplies.count : result.page.count // 空页视为到底
            page += 1
            error = nil
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            self.error = error.localizedDescription
        }
    }

    func append(_ reply: Reply) {
        loadedReplies.append(reply)
        total = (total ?? 0) + 1
    }
}
