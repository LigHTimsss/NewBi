import Foundation

/// 只记录服务器已确认的删除结果，防止在途列表响应把已删内容重新插回界面。
@MainActor
@Observable
final class OwnedContentDeletion {
    static let shared = OwnedContentDeletion()

    struct CommentID: Hashable, Sendable {
        let type: Int
        let oid: Int
        let rpid: Int
    }

    private(set) var videos: Set<Int> = []
    private(set) var dynamics: Set<String> = []
    private(set) var comments: Set<CommentID> = []
    private(set) var pendingDynamics: Set<String> = []
    private(set) var pendingComments: Set<CommentID> = []

    static func owns(_ owner: Int?, session: SessionStore) -> Bool {
        guard let owner, owner > 0, let mid = session.mid else { return false }
        return owner == mid
    }

    func contains(_ reply: Reply, oid: Int, type: Int) -> Bool {
        comments.contains(CommentID(type: type, oid: oid, rpid: reply.id))
    }

    func contains(_ item: DynamicItem) -> Bool {
        if dynamics.contains(item.id) { return true }
        // 删除视频不等于删除别人转发它的动态；这里只处理原视频投稿动态。
        guard item.type == "DYNAMIC_TYPE_AV",
              let raw = item.modules.dynamic?.major?.archive?.aid, let aid = Int(raw) else { return false }
        return videos.contains(aid)
    }

    func delete(_ item: DynamicItem, session: SessionStore) async throws {
        guard Self.owns(item.modules.author?.mid, session: session), let mid = session.mid else {
            throw BiliError.api(code: -403, message: "只能删除当前登录账号自己的动态")
        }
        guard item.type != "DYNAMIC_TYPE_AV" else {
            throw BiliError.api(code: -400, message: "视频投稿动态请通过删除视频稿件入口操作")
        }
        guard let csrf = BiliClient.csrfToken else { throw loginRequired }
        guard !dynamics.contains(item.id), pendingDynamics.insert(item.id).inserted else {
            throw BiliError.api(code: -400, message: "这条动态正在删除或已删除")
        }
        defer { pendingDynamics.remove(item.id) }
        struct Body: Encodable, Sendable { let dyn_id_str: String }
        try await BiliClient.shared.postJSON(.dynamicDelete(csrf: csrf), body: Body(dyn_id_str: item.id), expectedMid: mid)
        dynamics.insert(item.id)
    }

    func delete(_ reply: Reply, oid: Int, type: Int, session: SessionStore) async throws {
        guard Self.owns(reply.member.midValue, session: session), let mid = session.mid else {
            throw BiliError.api(code: -403, message: "只能删除当前登录账号自己的评论")
        }
        guard let csrf = BiliClient.csrfToken else { throw loginRequired }
        let key = CommentID(type: type, oid: oid, rpid: reply.id)
        guard !comments.contains(key), pendingComments.insert(key).inserted else {
            throw BiliError.api(code: -400, message: "这条评论正在删除或已删除")
        }
        defer { pendingComments.remove(key) }
        try await BiliClient.shared.post(.replyDelete, form: [
            "oid": String(oid), "type": String(type), "rpid": String(reply.id), "csrf": csrf,
        ], expectedMid: mid)
        comments.insert(key)
    }

    /// 只由官方管理页返回的、与目标 aid 匹配的成功响应调用。
    func confirmedVideo(_ card: VideoCard) {
        guard card.id > 0 else { return }
        videos.insert(card.id)
        if let playing = VideoStage.shared.model,
           (playing.detail?.aid ?? playing.card.id) == card.id {
            playing.player.pause()
            VideoStage.shared.close()
        }
    }

    static func failureMessage(_ error: Error) -> String {
        if let bili = error as? BiliError, case .api = bili {
            return "删除失败：\(error.localizedDescription)"
        }
        // 断网或响应解析失败时，服务器可能已执行，不能自动重试或断言没有删除。
        return "未能确认删除结果，请先刷新核对：\(error.localizedDescription)"
    }

    private var loginRequired: BiliError { .api(code: -101, message: "登录已失效，请重新登录") }
}
