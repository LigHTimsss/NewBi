import SwiftUI

@MainActor
@Observable
final class DynamicModel {
    enum Filter: String, CaseIterable {
        case all = "全部", video = "视频"

        var type: String { self == .all ? "all" : "video" }
    }

    var filter: Filter = .all {
        didSet { if filter != oldValue { load(reset: true) } }
    }
    private var loadedItems: [DynamicItem] = []
    var items: [DynamicItem] { loadedItems.filter { !OwnedContentDeletion.shared.contains($0) } }
    private(set) var ups: [DynamicUp] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    /// 本地点赞状态（乐观更新）
    private(set) var likeOverrides: [String: Bool] = [:]

    @ObservationIgnored private var offset = ""
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 非 nil 时只看这个 UP 主的动态（空间页「动态」Tab），不需要登录
    let hostMid: Int?
    /// 空间页里搜 TA 的动态（空为不搜）
    private(set) var keyword = ""
    @ObservationIgnored private var searchPage = 1
    /// 关注流属于哪个账号。换账号 / 退出时整份清空，迟到的旧账号响应按 epoch 丢弃
    private(set) var owner: Int?
    @ObservationIgnored private var epoch = 0

    init(hostMid: Int? = nil) {
        self.hostMid = hostMid
    }

    /// 换了账号（或退出）：清掉上一个账号的列表、关注 UP 主条、点赞覆盖，取消在途请求
    func reset(owner: Int?) {
        self.owner = owner
        epoch += 1
        loadTask?.cancel()
        loadTask = nil
        loadedItems = []
        ups = []
        likeOverrides = [:]
        offset = ""
        hasMore = true
        isLoading = false
        error = nil
    }

    func refresh() async {
        guard hostMid == nil else {
            load(reset: true)
            await loadTask?.value
            return
        }
        let epoch = epoch
        async let portal = try? BiliClient.shared.get(.dynamicPortal, as: DynamicPortal.self)
        load(reset: true)
        await loadTask?.value
        let list = await portal?.upList?.items
        guard epoch == self.epoch else { return }
        if let list { ups = list }
    }

    func loadIfNeeded() {
        if items.isEmpty, !isLoading { load(reset: true) }
    }

    /// 空间页搜 TA 的动态；空字符串回到全部动态
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hostMid != nil, trimmed != keyword else { return }
        keyword = trimmed
        loadedItems = []
        load(reset: true)
    }

    func loadMore(after item: DynamicItem) {
        guard item.id == items.last?.id else { return }
        load(reset: false)
    }

    private func load(reset: Bool) {
        if reset {
            loadTask?.cancel()
            offset = ""
            searchPage = 1
            hasMore = true
            isLoading = false
        }
        guard !isLoading, hasMore else { return }
        isLoading = true
        let type = filter.type, offset = offset, hostMid = hostMid, epoch = epoch, owner = owner
        let keyword = keyword, searchPage = searchPage
        loadTask = Task {
            do {
                let endpoint: Endpoint = if let hostMid, !keyword.isEmpty {
                    .spaceDynamicSearch(mid: hostMid, keyword: keyword, page: searchPage, offset: offset)
                } else {
                    hostMid.map { .spaceDynamic(mid: $0, offset: offset) } ?? .dynamicFeed(type: type, offset: offset)
                }
                let feed = try await BiliClient.shared.get(endpoint, as: DynamicFeed.self)
                guard !Task.isCancelled, epoch == self.epoch else { return }
                let known = reset ? [] : Set(loadedItems.map(\.id))
                let fresh = (feed.items ?? []).filter { !known.contains($0.id) }
                loadedItems = reset ? fresh : loadedItems + fresh
                // 整页重新拉到了：点赞状态以服务器为准
                if reset { likeOverrides = [:] }
                self.offset = feed.offset ?? ""
                self.searchPage = searchPage + 1
                // 搜索结果按页码翻，offset 可能为空
                hasMore = (feed.hasMore ?? false) && (!keyword.isEmpty || !self.offset.isEmpty)
                if reset, hostMid == nil, type == "all", let owner, let baseline = feed.updateBaseline {
                    DynamicBadge.shared.markSeen(baseline: baseline, mid: owner)
                }
                error = nil
            } catch {
                guard !Task.isCancelled, epoch == self.epoch else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: 点赞

    func isLiked(_ item: DynamicItem) -> Bool {
        likeOverrides[item.id] ?? (item.modules.stat?.like?.status ?? false)
    }

    func likeCount(_ item: DynamicItem) -> Int {
        let base = item.modules.stat?.like?.count ?? 0
        let original = item.modules.stat?.like?.status ?? false
        guard let override = likeOverrides[item.id], override != original else { return base }
        return base + (override ? 1 : -1)
    }

    private struct ThumbBody: Encodable, Sendable {
        let dynIDStr: String
        let up: Int
        let spmid: String

        private enum CodingKeys: String, CodingKey {
            case up, spmid
            case dynIDStr = "dyn_id_str"
        }
    }

    /// 先改界面再请求，失败回滚
    func toggleLike(_ item: DynamicItem) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能点赞") }
        let target = !isLiked(item)
        let epoch = epoch
        likeOverrides[item.id] = target
        do {
            try await BiliClient.shared.postJSON(.dynamicThumb(csrf: csrf), body: ThumbBody(dynIDStr: item.id, up: target ? 1 : 2, spmid: "333.1365.0.0"))
        } catch {
            // 期间换了账号：覆盖值已经清空，不再回滚到新账号身上
            if epoch == self.epoch { likeOverrides[item.id] = !target }
            throw error
        }
    }
}

/// 底栏「动态」红点：按账号记住上次看到的 baseline，回到前台时查一次有没有新动态
@MainActor
@Observable
final class DynamicBadge {
    static let shared = DynamicBadge()
    private(set) var hasNew = false
    /// 正在为哪个账号查：换账号后旧账号的结果不再写进来
    @ObservationIgnored private var current: Int?

    private static func key(_ mid: Int) -> String { "dynamicBaseline.\(mid)" }

    func markSeen(baseline: String, mid: Int) {
        UserDefaults.standard.set(baseline, forKey: Self.key(mid))
        if current == mid { hasNew = false }
    }

    func check(mid: Int?) async {
        if current != mid {
            current = mid
            hasNew = false
        }
        guard let mid, BiliClient.csrfToken != nil, let baseline = UserDefaults.standard.string(forKey: Self.key(mid)),
              let update = try? await BiliClient.shared.get(.dynamicUpdate(baseline: baseline), as: DynamicUpdate.self),
              current == mid else { return }
        hasNew = update.updateNum > 0
    }
}

// MARK: - 页面

/// 动态：关注 UP 主头像条 + 全部 / 视频 + 动态卡片流
struct DynamicView: View {
    /// 变化时刷新（底栏有红点时切过来、或在动态页再点一次「动态」）
    var refreshToken = 0
    @Environment(SessionStore.self) private var session
    @State private var model = DynamicModel()
    @State private var commentTarget: CommentTarget?
    @State private var viewer: ImageViewerRequest?

    var body: some View {
        Group {
            if session.isLoggedIn {
                if model.owner == session.mid {
                    feed
                } else {
                    // 刚换账号、上一个账号的列表还没清掉的那一帧：不画旧内容
                    Color.clear
                }
            } else {
                VStack(alignment: .leading) {
                    title.padding(.horizontal, 20)
                    LoginPrompt(message: "登录后查看关注的 UP 主发布的新作品")
                }
            }
        }
        .sheet(item: $commentTarget) { target in
            DynamicCommentSheet(target: target)
        }
        .imageViewer($viewer)
        // 按账号归属：换账号 / 退出时先清空上一个账号的内容，再为新账号加载（第一帧就不会出现旧账号的动态）
        .task(id: session.mid) {
            if model.owner != session.mid { model.reset(owner: session.mid) }
            if session.mid != nil, model.items.isEmpty { await model.refresh() }
        }
        .onChange(of: refreshToken) {
            guard session.isLoggedIn else { return }
            Task { await model.refresh() }
        }
    }

    private var title: some View {
        Text("动态").font(.serif(34)).tracking(2).padding(.top, 4)
    }

    private var feed: some View {
        @Bindable var dynamic = model
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    title
                    Spacer()
                    GlassSegmented(options: DynamicModel.Filter.allCases, selection: $dynamic.filter, title: \.rawValue)
                        .frame(width: 150)
                }
                .padding(.horizontal, 16)

                if !model.ups.isEmpty { upStrip }

                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    DynamicCard(
                        item: item,
                        model: model,
                        onComment: { commentTarget = CommentTarget(item: item) },
                        onImage: { urls, i in viewer = ImageViewerRequest(urls: urls, index: i) }
                    )
                    .padding(.horizontal, 16)
                    .riseIn(index: index)
                    .onAppear { model.loadMore(after: item) }
                }

                footer
            }
            .padding(.bottom, 16)
        }
        .contentMargins(.bottom, 96, for: .scrollContent)
        .refreshable { await model.refresh() }
    }

    /// 最近有更新的关注 UP 主
    private var upStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(model.ups) { up in
                    NavigationLink(value: Route.space(mid: up.mid)) {
                        VStack(spacing: 6) {
                            // 在直播的人换成粉色直播圈（点头像进直播间），否则有更新时是主题色光圈
                            let isLive = LiveStatusCenter.shared.room(for: up.mid) != nil
                            LiveAvatar(mid: up.mid, url: up.face, size: 52)
                                .padding(2.5)
                                .overlay { if up.hasUpdate == true && !isLive { UpdateRing() } }
                            Text(up.uname)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(up.hasUpdate == true ? "\(up.uname)，有更新" : up.uname)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let error = model.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
            }
        } else if model.items.isEmpty {
            ContentUnavailableView("暂无新动态", systemImage: "safari", description: Text("关注的 UP 主发布新作品后会出现在这里"))
        } else if !model.hasMore {
            Text("没有更多了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}

/// 有更新的 UP 主：强调色渐变描边
private struct UpdateRing: View {
    @Environment(\.accent) private var accent

    var body: some View {
        Circle()
            .strokeBorder(
                AngularGradient(colors: [accent, accent.opacity(0.4), accent], center: .center),
                lineWidth: 2
            )
    }
}

/// 动态的评论面板；模型放在 @State 里，父视图刷新时不会重建、不会重复请求
struct DynamicCommentSheet: View {
    @State private var model: CommentModel

    init(target: CommentTarget) {
        _model = State(initialValue: CommentModel(oid: target.oid, type: target.type))
    }

    var body: some View {
        NavigationStack {
            CommentSection(model: model, linksToSpace: false)
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct CommentTarget: Identifiable {
    let oid: Int
    let type: Int
    var id: String { "\(type)-\(oid)" }

    init(oid: Int, type: Int) {
        self.oid = oid
        self.type = type
    }

    /// 动态自带评论区信息；缺失时按纯文字动态处理
    init(item: DynamicItem) {
        oid = item.basic?.commentIDStr.flatMap { Int($0) } ?? Int(item.id) ?? 0
        type = item.basic?.commentType ?? 17
    }
}

// MARK: - 卡片

struct DynamicCard: View {
    let item: DynamicItem
    let model: DynamicModel
    var onComment: () -> Void
    var onImage: ([String], Int) -> Void
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var confirmVideoDelete = false
    @Environment(SessionStore.self) private var session
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DynamicBody(modules: item.modules, expanded: $expanded, onImage: onImage)
            if item.isForward, let orig = item.orig {
                // 转发：原动态放在浅底卡片里
                VStack(alignment: .leading, spacing: 8) {
                    if let author = orig.modules.author {
                        NavigationLink(value: Route.space(mid: author.mid)) {
                            Text("@\(author.name)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(accent.accentText(scheme))
                        }
                        .buttonStyle(PressableStyle())
                    }
                    DynamicBody(modules: orig.modules, expanded: .constant(false), onImage: onImage)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.selection, in: .rect(cornerRadius: 14))
            }
            stats
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: 22))
        .alert("删除这条动态？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await OwnedContentDeletion.shared.delete(item, session: session)
                        ToastCenter.shared.show("动态已删除")
                    } catch { ToastCenter.shared.show(OwnedContentDeletion.failureMessage(error)) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("删除后无法恢复。") }
        .modifier(VideoDeletionPresentation(card: videoCard, confirmation: $confirmVideoDelete))
        .onChange(of: session.mid) { _, _ in confirmDelete = false; confirmVideoDelete = false }
    }

    private var videoCard: VideoCard {
        item.modules.dynamic?.video(author: item.modules.author)
            ?? VideoCard(id: 0, bvid: "", cid: nil, title: "", pic: "", duration: 0, owner: nil, stat: nil)
    }

    @ViewBuilder
    private var header: some View {
        if let author = item.modules.author {
            HStack(spacing: 10) {
                NavigationLink(value: Route.space(mid: author.mid)) {
                    HStack(spacing: 10) {
                        LiveAvatar(mid: author.mid, url: author.face, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(author.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(author.isVIP ? accent.accentText(scheme) : .primary)
                                .lineLimit(1)
                            Text([author.pubTime, author.pubAction].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(PressableStyle())
                Spacer(minLength: 0)
                if OwnedContentDeletion.owns(author.mid, session: session) {
                    Menu {
                        if item.type == "DYNAMIC_TYPE_AV" {
                            Button("删除视频稿件", systemImage: "trash", role: .destructive) { confirmVideoDelete = true }
                                .disabled(videoCard.id <= 0)
                        } else {
                            Button("删除动态", systemImage: "trash", role: .destructive) { confirmDelete = true }
                                .disabled(OwnedContentDeletion.shared.pendingDynamics.contains(item.id))
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(.rect)
                    }
                    .accessibilityLabel("动态更多操作")
                }
                if let pin = item.modules.pinLabel {
                    Label(pin, systemImage: "pin.fill")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.accentText(scheme))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(accent.opacity(0.12), in: .capsule)
                        .accessibilityLabel("置顶动态")
                }
            }
        }
    }

    private var stats: some View {
        let liked = model.isLiked(item)
        return HStack {
            statButton("arrowshape.turn.up.right", item.modules.stat?.forward?.count, label: "转发") { share() }
            statButton("bubble.left", item.modules.stat?.comment?.count, label: "评论", action: onComment)
            statButton(liked ? "hand.thumbsup.fill" : "hand.thumbsup", model.likeCount(item), label: liked ? "取消点赞" : "点赞", on: liked) {
                Task {
                    do { try await model.toggleLike(item) } catch { ToastCenter.shared.show(error.localizedDescription) }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: liked)
        }
        .font(.system(size: 13))
        .animation(Motion.component, value: liked)
    }

    /// 转发：打开分享框（动态链接 t.bilibili.com/<id>），标题用「谁的动态」+ 正文开头
    private func share() {
        guard let url = URL(string: "https://t.bilibili.com/\(item.id)") else { return }
        let name = item.modules.author?.name ?? ""
        let text = item.modules.dynamic?.title ?? item.modules.dynamic?.text?.text ?? ""
        let summary = String(text.replacingOccurrences(of: "\n", with: " ").prefix(30))
        let title = [name.isEmpty ? "动态" : "\(name)的动态", summary].filter { !$0.isEmpty }.joined(separator: "：")
        ShareCenter.shared.share(title: title, url: url)
    }

    private func statButton(_ icon: String, _ count: Int?, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: on)
                Text(count.map { $0 > 0 ? $0.biliCount : label } ?? label)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(count.map { "\(label) \($0)" } ?? label)
    }
}

/// 动态正文：标题、富文本（超过 6 行可展开）、视频、图片、专栏
private struct DynamicBody: View {
    let modules: DynamicModules
    @Binding var expanded: Bool
    var onImage: ([String], Int) -> Void

    private var content: DynamicContent? { modules.dynamic }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = content?.title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            if let text = content?.text, !text.text.isEmpty {
                RichText(text.text, emotes: text.emotes)
                    .lineLimit(expanded ? nil : 6)
                    .onTapGesture { withAnimation(Motion.component) { expanded.toggle() } }
            }
            if let video = content?.video(author: modules.author) {
                VideoLink(card: video) { DynamicVideo(card: video) }
                    .buttonStyle(PressableStyle())
                    .watchLaterMenu(video)
            }
            let images = content?.images ?? []
            if !images.isEmpty {
                ImageGrid(images: images) { onImage(images.map(\.url), $0) }
            }
        }
    }
}

private struct DynamicVideo: View {
    let card: VideoCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: card.pic, size: CGSize(width: 370, height: 208))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 40)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 10) {
                        if let view = card.stat?.view { Label(view.biliCount, systemImage: "play.rectangle") }
                        if let danmaku = card.stat?.danmaku { Label(danmaku.biliCount, systemImage: "text.bubble") }
                        Spacer(minLength: 0)
                        if card.duration > 0 { Text(card.duration.durationText) }
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                }
                .clipShape(.rect(cornerRadius: 14))
                .videoCover(cornerRadius: 14)
            Text(card.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
    }
}

/// 1 张按原比例；2 / 4 张两列；其余三列正方形
private struct ImageGrid: View {
    let images: [DynamicImage]
    var onTap: (Int) -> Void

    var body: some View {
        if images.count == 1, let image = images.first {
            Button { onTap(0) } label: {
                RemoteImage(url: image.url, size: CGSize(width: 260, height: 260 / image.aspectRatio), cropOnServer: false)
                    .aspectRatio(image.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: image.aspectRatio < 1 ? 220 : 300)
                    .clipShape(.rect(cornerRadius: 12))
                    .imageZoomSource(image.url)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("查看图片")
        } else {
            let columns = images.count == 2 || images.count == 4 ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(Array(images.prefix(9).enumerated()), id: \.offset) { index, image in
                    Button { onTap(index) } label: {
                        RemoteImage(url: image.url, size: CGSize(width: 180, height: 180), cropOnServer: false)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                            .imageZoomSource(image.url)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("查看图片 \(index + 1)")
                }
            }
        }
    }
}
