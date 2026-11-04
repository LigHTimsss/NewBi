import SwiftUI

@MainActor
@Observable
final class VideoDetailModel {
    let card: VideoCard
    let player = PlayerController()
    /// 卡片 id 即 aid，评论不必等详情返回；只有 BV 号时（评论里的链接）等详情拿到 aid 再建
    private(set) var comments: CommentModel
    private(set) var detail: VideoDetail?
    private(set) var related: [VideoCard] = []
    private(set) var onlineText: String?
    /// 与 UP 主的关注关系，详情返回后创建
    private(set) var relation: RelationModel?
    private(set) var isFavoured = false
    private(set) var isLiked = false
    /// 我已投的硬币数（0–2，一个视频最多 2 枚）
    private(set) var coins = 0
    /// 本次在页面里点赞 / 投币带来的计数变化（详情里的统计数不会实时刷新）
    private(set) var likeDelta = 0
    private(set) var coinDelta = 0
    private(set) var favDelta = 0
    private(set) var error: String?
    /// 断网时用离线缓存播放（详情接口拿不到时）
    private(set) var offline: DownloadRecord?
    /// 多 P：当前播放的分 P 下标
    private(set) var partIndex = 0
    /// 「已定位到上次观看位置」提示
    var resumeHint: String?
    /// 连播队列里播完后弹出的「即将播放」。放在模型里而不是视图 @State：
    /// 播放器的 onEnded 回调只弱引用模型，不捕获视图（捕获视图会连带强引用模型，形成循环引用）
    var upNext: VideoCard?

    var pages: [VideoPage] { detail?.pages ?? [] }
    var currentPart: VideoPage? { pages.indices.contains(partIndex) ? pages[partIndex] : nil }
    var currentCid: Int? { currentPart?.cid ?? detail?.cid }
    var maxCoins: Int { 2 }

    /// 从离线缓存列表点开的那一 P（同一个 BV 可能缓存了好几个分 P）：优先播它，不被续播记录带去别的分 P
    let pinnedCid: Int?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(card: VideoCard, pinnedCid: Int? = nil) {
        self.card = card
        self.pinnedCid = pinnedCid
        comments = CommentModel(oid: card.id)
    }

    /// 详情拿不到、也没有离线缓存时，播放区里的「重试」
    func retry() {
        guard !player.isClosed else { return }
        error = nil
        loadTask?.cancel()
        loadTask = Task { await self.load() }
    }

    /// 舞台打开视频时就开始取流（和展开动画同时进行），页面出现时不再重复。
    /// 加载放在模型自己持有的任务里：页面的 .task 被取消（收起成胶囊）不会打断加载，关掉时由 close() 取消
    func loadIfNeeded() async {
        if loadTask == nil, !player.isClosed {
            loadTask = Task { await self.load() }
        }
        await loadTask?.value
    }

    /// 舞台关掉或换走这个视频时调用：取消还在路上的请求，播放器立即收尾（不等 deinit）
    func close() {
        loadTask?.cancel()
        upNext = nil
        player.shutdown()
    }

    func load() async {
        async let relatedTask = try? BiliClient.shared.get(.related(bvid: card.bvid), as: [VideoCard].self)
        // 离线缓存里点开的那一 P：不等详情，立刻播本地文件（没网时也一样）
        var pinnedLocal: DownloadRecord?
        if let pinnedCid, player.playingCid == nil,
           let record = DownloadManager.shared.completed(bvid: card.bvid, cid: pinnedCid) {
            pinnedLocal = record
            offline = record
            await player.load(bvid: record.bvid, cid: record.cid)
            player.setNowPlaying(title: record.title, artist: record.ownerName ?? "离线缓存", cover: record.cover)
        }
        do {
            let detail = try await BiliClient.shared.get(.view(bvid: card.bvid), as: VideoDetail.self)
            // 等详情期间已关掉：不再装流、不再接管锁屏
            guard !Task.isCancelled, !player.isClosed else { return }
            self.detail = detail
            if card.id == 0 { comments = CommentModel(oid: detail.aid) }
            let relation = RelationModel(mid: detail.owner.mid)
            self.relation = relation

            // 登录后从上次看到的位置续播（跨设备同步）；多 P 时直接回到上次看的那一 P（指定了分 P 时以指定的为准）
            let loggedIn = BiliClient.csrfToken != nil
            let resume = loggedIn ? await resumePosition(detail) : nil
            guard !Task.isCancelled, !player.isClosed else { return }
            if let cid = pinnedCid ?? resume?.cid ?? card.cid, let index = pages.firstIndex(where: { $0.cid == cid }) {
                partIndex = index
            }
            configureParts()
            let cid = pinnedLocal?.cid ?? currentCid ?? detail.cid
            // 续播位置只用在它所属的那一 P 上
            let startAt = resume.flatMap { $0.cid == cid ? $0.seconds : nil }
            var resumed = startAt != nil
            if pinnedLocal != nil {
                // 本地文件已经在播：还没看多少时才跳到上次位置，不打断已经在看的
                if let startAt, player.currentTime < 5 { player.seek(seconds: startAt) } else { resumed = false }
            } else {
                await player.load(bvid: detail.bvid, cid: cid, startAt: startAt)
            }
            updateNowPlaying()
            if resumed, let startAt {
                let part = pages.count > 1 ? "P\(partIndex + 1) " : ""
                resumeHint = "已定位到上次观看位置 \(part)\(Int(startAt).durationText)"
            }

            await relation.refresh()
            if loggedIn {
                if let state = try? await BiliClient.shared.get(.archiveRelation(aid: detail.aid), as: ArchiveRelation.self) {
                    isLiked = state.like
                    coins = state.coin
                    isFavoured = state.favorite
                } else {
                    isFavoured = (try? await BiliClient.shared.get(.favoured(aid: detail.aid), as: FavouredInfo.self).favoured) ?? false
                }
            }
            onlineText = try? await BiliClient.shared.get(.onlineTotal(bvid: detail.bvid, cid: currentCid ?? detail.cid), as: OnlineTotal.self).total
        } catch {
            // 已关掉（请求被取消）：不再回退到离线播放
            guard !Task.isCancelled, !player.isClosed else { return }
            // 没网但已缓存：直接播本地文件（指定的那一 P 已经在播就不动）
            if pinnedLocal != nil {
                // 简介区显示离线信息
            } else if let record = DownloadManager.shared.completed(bvid: card.bvid, cid: card.cid ?? 0)
                ?? DownloadManager.shared.record(bvid: card.bvid).flatMap({ $0.state == .completed ? $0 : nil }) {
                offline = record
                await player.load(bvid: record.bvid, cid: record.cid)
                player.setNowPlaying(title: record.title, artist: record.ownerName ?? "离线缓存", cover: record.cover)
            } else {
                self.error = error.localizedDescription
            }
        }
        related = await relatedTask ?? []
    }

    /// 上次看到的分 P 与位置；离开头和结尾都要有一段距离才续播
    private func resumePosition(_ detail: VideoDetail) async -> (cid: Int, seconds: Double)? {
        guard let info = try? await BiliClient.shared.get(.playerInfo(bvid: detail.bvid, cid: detail.cid), as: PlayerInfo.self),
              let cid = info.lastPlayCid, cid > 0, let ms = info.lastPlayTime else { return nil }
        let duration = detail.pages?.first(where: { $0.cid == cid })?.duration ?? (cid == detail.cid ? detail.duration : 0)
        let seconds = Double(ms) / 1000
        return seconds > 5 && seconds < Double(duration) - 10 ? (cid, seconds) : nil
    }

    // MARK: 多 P

    /// 切换分 P：同一个播放器换流，弹幕跟着换；评论、简介不变（同一个 aid）
    func selectPart(_ index: Int) async {
        guard let detail, pages.indices.contains(index), index != partIndex, !player.isClosed else { return }
        // 先同步记下旧一 P 的进度，再换流
        flushProgress()
        partIndex = index
        configureParts()
        await player.load(bvid: detail.bvid, cid: pages[index].cid)
        updateNowPlaying()
    }

    /// 舞台上已经是这个视频、又从离线缓存点了它的某一 P：能就地展示就返回 true
    /// （没指定分 P、正在播的就是它、或者能原地切过去）；否则返回 false，由舞台换一个新的播放器
    func show(part cid: Int?) -> Bool {
        guard let cid, !player.isClosed else { return !player.isClosed }
        if cid == (player.playingCid ?? pinnedCid ?? currentCid) { return true }
        guard let index = pages.firstIndex(where: { $0.cid == cid }) else { return false }
        Task { await selectPart(index) }
        return true
    }

    private func configureParts() {
        player.hasPreviousPart = partIndex > 0
        player.hasNextPart = partIndex < pages.count - 1
        player.onRequestPart = { [weak self] offset in
            guard let self else { return }
            Task { await self.selectPart(self.partIndex + offset) }
        }
    }

    private func updateNowPlaying() {
        guard let detail else { return }
        let title = pages.count > 1 ? "P\(partIndex + 1) \(currentPart?.part ?? "") · \(detail.title)" : detail.title
        player.setNowPlaying(title: title, artist: detail.owner.name, cover: detail.pic)
    }

    // MARK: 点赞 / 投币 / 三连

    /// 用户在页面里收藏 / 取消收藏（服务器初始状态直接赋值，不计入 favDelta）
    func setFavoured(_ value: Bool) {
        guard value != isFavoured else { return }
        isFavoured = value
        favDelta += value ? 1 : -1
    }

    /// 乐观更新：先变界面，失败再回滚
    func toggleLike() async throws {
        guard let detail, let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能点赞") }
        let target = !isLiked
        setLiked(target)
        do {
            try await BiliClient.shared.post(.archiveLike, form: ["aid": "\(detail.aid)", "like": target ? "1" : "2", "csrf": csrf])
        } catch {
            setLiked(!target)
            throw error
        }
    }

    func addCoins(_ count: Int, alsoLike: Bool) async throws {
        guard let detail, let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能投币") }
        try await BiliClient.shared.post(.coinAdd, form: [
            "aid": "\(detail.aid)", "multiply": "\(count)", "select_like": alsoLike ? "1" : "0", "csrf": csrf,
        ])
        coins += count
        coinDelta += count
        if alsoLike, !isLiked { setLiked(true) }
    }

    /// 一键三连：服务器分别返回点赞、投币、收藏是否成功（硬币不够时投币会失败）
    func triple() async throws -> TripleResult {
        guard let detail, let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能三连") }
        let result = try await BiliClient.shared.post(.archiveTriple, form: ["aid": "\(detail.aid)", "csrf": csrf], as: TripleResult.self)
        if result.like, !isLiked { setLiked(true) }
        if result.coin {
            let added = max(0, (result.multiply ?? maxCoins) - coins)
            coins += added
            coinDelta += added
        }
        if result.fav { setFavoured(true) }
        return result
    }

    private func setLiked(_ value: Bool) {
        guard value != isLiked else { return }
        isLiked = value
        likeDelta += value ? 1 : -1
    }

    /// 上报播放进度，让历史记录和其它设备的续播保持同步（离开页面、进入后台、切分 P、关掉 / 换走时调用）。
    /// 调用时同步取快照：引擎里实际装着的那一项的 CID 和它的时钟（两者同时提交，不会把上一 P 的进度记到新 CID 上）；
    /// 网络请求在后台发，调用方紧接着切 P、关掉播放器都不影响已经取好的快照
    func flushProgress() {
        let aid = detail?.aid ?? offline?.aid ?? card.id
        guard aid > 0, let cid = player.playingCid, let csrf = BiliClient.csrfToken else { return }
        let time = player.currentTime
        let duration = player.duration
        guard time > 0 else { return }
        let finished = duration > 0 && time >= duration - 5
        let form = [
            "aid": "\(aid)", "cid": "\(cid)",
            "progress": finished ? "-1" : "\(Int(time))", "csrf": csrf,
        ]
        Task { try? await BiliClient.shared.post(.historyReport, form: form) }
    }
}

/// 「视频详情」画板：顶部播放器 + 简介/评论 Tab + UP 主、三连、相关推荐。
/// 放在舞台（VideoStage）上，不在导航栈里：从卡片封面展开、返回时收进迷你胶囊或卡片都由舞台负责。
/// 全屏不另开页面：同一个播放器视图原地放大到整屏（AVPlayerLayer、弹幕图层都不重建），界面转为横屏。
struct VideoDetailView: View {
    let model: VideoDetailModel
    /// 连播队列：播完后换到下一个视频（舞台原地替换）
    var onAdvance: ((VideoCard) -> Void)? = nil
    @State private var tab = 0
    /// 简介 → 评论的横滑进度 0…1，Tab 下划线跟手
    @State private var pageProgress: CGFloat = 0
    @State private var isFullscreen = false
    @State private var locked = false
    /// 在画面上下拉收起：只认从画面里（进度条以上）开始的竖向拖动
    @State private var pulling: Bool?
    @State private var playerBox = FrameBox()
    /// 「点我发弹幕」的输入框
    @State private var composing = false
    @State private var draft = ""
    /// 全屏里点收藏：收藏夹面板挂在这一层（简介区在全屏时是收起的）
    @State private var showFavorite = false
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var parentOpenURL
    @AppStorage("backgroundPlay") private var backgroundPlay = true

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                player
                    .frame(height: isFullscreen ? geo.size.height : geo.size.width * 9 / 16)

                // 全屏时不移除，只收起：退出全屏后简介 / 评论原样还在（不重新淡入、滚动位置不丢）
                VStack(spacing: 0) {
                    DetailTabs(
                        selection: tab,
                        progress: pageProgress,
                        replyCount: model.comments.total ?? model.detail?.stat.reply,
                        onCompose: startComposing
                    ) { index in
                        withAnimation(Motion.component) { tab = index }
                    }
                    DetailPager(model: model, tab: $tab, progress: $pageProgress)
                }
                .frame(height: isFullscreen ? 0 : nil)
                .clipped()
                .opacity(isFullscreen ? 0 : 1)
                .allowsHitTesting(!isFullscreen)
                .accessibilityHidden(isFullscreen)
            }
        }
        .background(isFullscreen ? Color.black : Theme.background)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .task {
            configureQueue()
            await model.loadIfNeeded()
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        // 收起后模型由舞台持有（迷你胶囊）；关掉 / 换走时舞台调用 model.close() 显式收尾
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if isFullscreen {
                Orientation.lock(.portrait)
                VideoStage.shared.isFullscreen = false
            }
        }
        .toast(Binding(get: { model.resumeHint }, set: { model.resumeHint = $0 }), bottomPadding: 40)
        .alert("发弹幕", isPresented: $composing) {
            TextField("发一条友善的弹幕", text: $draft)
            Button("发送", action: sendDraft)
            Button("取消", role: .cancel) { draft = "" }
        } message: {
            Text("弹幕会出现在当前播放位置")
        }
        .sheet(isPresented: $showFavorite) {
            if let detail = model.detail, let mid = session.user?.mid {
                FavoriteSheet(aid: detail.aid, mid: mid) { favoured in
                    model.setFavoured(favoured)
                    model.resumeHint = favoured ? "已收藏" : "已取消收藏"
                }
            }
        }
        // 评论里的时间点：跳到该位置并继续播放；其它链接交回上层
        .environment(\.openURL, OpenURLAction { url in
            if case .seek(let seconds) = AppLink.parse(url) {
                model.player.seek(seconds: Double(seconds))
                model.player.play()
                model.resumeHint = "已跳到 \(seconds.durationText)"
                return .handled
            }
            parentOpenURL(url)
            return .handled
        })
        // 横过手机自动进入全屏，竖回来退出（锁屏时不跟随）
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            followDeviceOrientation()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            model.flushProgress()
            guard !backgroundPlay, !model.player.isPictureInPictureActive else { return }
            model.player.pause()
        }
    }

    private var player: some View {
        ZStack {
            // 收起 / 展开途中画面在舞台上（跟着容器走），这里空着
            if !model.player.isMinimized {
                PlayerSurface(controller: model.player)
                    .ignoresSafeArea(edges: isFullscreen ? .all : [])
                // 第一帧出来之前盖着封面（和卡片、舞台同一张图），不黑屏
                VideoPoster(card: model.card)
                    .opacity(model.player.hasFrame ? 0 : 1)
                    .animation(Motion.micro, value: model.player.hasFrame)
                    .allowsHitTesting(false)
                if isFullscreen {
                    FullscreenOverlay(
                        model: model,
                        locked: $locked,
                        onExit: { setFullscreen(false) },
                        // 评论：退出全屏、切到评论 Tab
                        onComments: {
                            setFullscreen(false)
                            withAnimation(Motion.component) { tab = 1 }
                        },
                        onFavorite: requestFavorite
                    )
                } else {
                    CompactOverlay(
                        controller: model.player,
                        card: model.card,
                        onBack: { VideoStage.shared.back() },
                        onFullscreen: { setFullscreen(true) }
                    )
                }
                // 在控件之上、只占中间一块：返回 / 全屏等按钮照常能点
                PlayerStatusView(model: model)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            if let next = model.upNext {
                UpNextCard(next: next, queueTitle: PlayQueue.shared.title) {
                    model.upNext = nil
                    onAdvance?(next)
                } onCancel: {
                    withAnimation(Motion.component) { model.upNext = nil }
                }
                .frame(maxWidth: 460)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea(edges: isFullscreen ? .all : .top).opacity(model.player.isMinimized ? 0 : 1))
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { playerBox.maxY = $0 }
        // 在画面上往下拉：页面跟手缩小，松手收进胶囊 / 卡片（同 iOS 的下拉关闭）。
        // 用整屏坐标：拖动中页面在缩小，局部坐标会跟着变
        .simultaneousGesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onChanged { value in
                    if pulling == nil {
                        let t = value.translation
                        // 进度条那一条不算（那里左右拖是调进度）
                        pulling = value.startLocation.y < playerBox.maxY - 50 && t.height > abs(t.width)
                    }
                    if pulling == true { VideoStage.shared.pageDragChanged(value.translation, kind: .down) }
                }
                .onEnded { value in
                    if pulling == true {
                        VideoStage.shared.pageDragEnded(value.translation, velocity: value.velocity, kind: .down)
                    }
                    pulling = nil
                },
            including: isFullscreen ? .subviews : .all
        )
    }

    /// 在连播队列里时：播完弹出「即将播放」，3 秒后换到下一个
    private func configureQueue() {
        guard onAdvance != nil else { return }
        let model = self.model
        let bvid = model.card.bvid
        // 只弱引用模型、不捕获视图（self）：否则 模型 → 播放器 → 回调 → 视图 → 模型 成环，关掉视频后永不释放
        model.player.onEnded = { [weak model] in
            guard let model, let next = PlayQueue.shared.next(after: bvid) else { return }
            withAnimation(Motion.component) { model.upNext = next }
        }
    }

    private func startComposing() {
        guard session.isLoggedIn else {
            model.resumeHint = "登录后才能发送弹幕"
            return
        }
        guard model.player.playingCid != nil else {
            model.resumeHint = "视频开始播放后才能发弹幕"
            return
        }
        composing = true
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty else { return }
        let model = model
        Task {
            do {
                try await model.player.sendDanmaku(text)
                model.resumeHint = "发送成功"
            } catch {
                model.resumeHint = error.localizedDescription
            }
        }
    }

    private func requestFavorite() {
        guard session.isLoggedIn else {
            model.resumeHint = "登录后才能收藏"
            return
        }
        guard model.detail != nil else { return }
        showFavorite = true
    }

    private func setFullscreen(_ on: Bool, preferred: UIInterfaceOrientationMask = .landscapeRight) {
        if !on { locked = false }
        isFullscreen = on
        // 全屏里不能收起（左右滑是拖进度）
        VideoStage.shared.isFullscreen = on
        if on {
            Orientation.lock(.landscape, preferred: preferred)
        } else {
            Orientation.lock(.portrait)
        }
    }

    private func followDeviceOrientation() {
        guard !locked, !model.player.isMinimized else { return }
        let device = UIDevice.current.orientation
        if let mask = Orientation.interfaceMask(for: device), !isFullscreen {
            setFullscreen(true, preferred: mask)
        } else if device == .portrait, isFullscreen {
            setFullscreen(false)
        }
    }
}

// MARK: - 播放区状态提示

/// 播放区中间的提示：移动网络确认、取流失败、详情拿不到。都带一个能直接解决问题的按钮
private struct PlayerStatusView: View {
    let model: VideoDetailModel

    private struct Status: Equatable {
        let text: String
        let action: String
        let kind: Kind
        enum Kind { case cellular, stream, detail }
    }

    private var status: Status? {
        let player = model.player
        if player.needsCellularConfirm {
            return Status(text: "正在使用移动网络，播放将消耗流量", action: "继续播放", kind: .cellular)
        }
        if let error = player.error {
            return Status(text: error, action: "重试", kind: .stream)
        }
        if let error = model.error, model.detail == nil, model.offline == nil {
            return Status(text: error, action: "重试", kind: .detail)
        }
        return nil
    }

    var body: some View {
        let status = status
        ZStack {
            if let status {
                // 盖在封面上压暗，文字才看得清；本身不接收触摸
                Color.black.opacity(0.5).allowsHitTesting(false)
                VStack(spacing: 12) {
                    Text(status.text)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button(status.action) { perform(status.kind) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 300)
            }
        }
        .animation(Motion.micro, value: status)
    }

    private func perform(_ kind: Status.Kind) {
        switch kind {
        case .cellular: model.player.confirmCellular()
        case .stream: model.player.retry()
        case .detail: model.retry()
        }
    }
}

// MARK: - 竖屏小窗控件

private struct CompactOverlay: View {
    let controller: PlayerController
    let card: VideoCard
    var onBack: () -> Void
    var onFullscreen: () -> Void
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Color.clear
            if showControls {
                controls.transition(.opacity)
            }
        }
        .contentShape(.rect)
        // 手势与 B 站一致：双击暂停/播放，单击显隐控件
        .onTapGesture(count: 2) { controller.togglePlay() }
        .onTapGesture {
            withAnimation(Motion.micro) { showControls.toggle() }
            scheduleHide()
        }
        .onAppear { scheduleHide() }
    }

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassCircleButton(systemImage: "chevron.left", label: "返回", size: 36, glass: .clear, action: onBack)
                    Spacer()
                    // 系统投屏 / 音频输出选择（和全屏抽屉里的是同一个）
                    RoutePicker(activeTint: UIColor(accent))
                        .frame(width: 36, height: 36)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .accessibilityLabel("投屏")
                    moreMenu
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Spacer()
            PlaybackBar(controller: controller, onFullscreen: onFullscreen)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 60)
                .allowsHitTesting(false)
        }
    }

    /// 右上角「更多」：稍后再看、分享
    private var moreMenu: some View {
        Menu {
            Button {
                Task {
                    do {
                        try await WatchLater.add(aid: card.id)
                        ToastCenter.shared.show("已添加到稍后再看")
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            } label: {
                Label("稍后再看", systemImage: "clock.badge.plus")
            }
            if let url = URL(string: "https://www.bilibili.com/video/\(card.bvid)") {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel("更多")
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, controller.isPlaying else { return }
            withAnimation(Motion.micro) { showControls = false }
        }
    }
}

/// 独立子视图：只有它读取 currentTime，4 Hz 的进度刷新不会让整页重算
private struct PlaybackBar: View {
    let controller: PlayerController
    var onFullscreen: () -> Void
    @Environment(\.accent) private var accent
    @State private var dragFraction: Double?

    var body: some View {
        let fraction = dragFraction ?? (controller.duration > 0 ? controller.currentTime / controller.duration : 0)
        HStack(spacing: 10) {
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")

            Text(Int(controller.duration * fraction).durationText)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                    Capsule().fill(accent).frame(width: geo.size.width * fraction, height: 3)
                    Circle().fill(.white)
                        .frame(width: dragFraction == nil ? 10 : 14)
                        .offset(x: geo.size.width * fraction - 5)
                        .animation(Motion.micro, value: dragFraction == nil)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                        .onEnded { _ in
                            if let dragFraction { controller.seek(to: dragFraction) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 28)

            Text(Int(controller.duration).durationText)

            Button { controller.danmakuEnabled.toggle() } label: {
                Image(systemName: controller.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    .foregroundStyle(controller.danmakuEnabled ? accent : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("弹幕开关")
            .accessibilityValue(controller.danmakuEnabled ? "开" : "关")

            Button(action: onFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28)
            }
            .accessibilityLabel("全屏")
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - 简介 / 评论

/// 简介 / 评论两页并排放在一个横向分页 ScrollView 里：左右滑切换，两页都常驻
/// （切回来不重建、不再淡入、滚动位置不丢）。评论页第一次滑到 / 点到时才挂上，不拖慢进入视频页。
private struct DetailPager: View {
    let model: VideoDetailModel
    @Binding var tab: Int
    @Binding var progress: CGFloat
    @State private var commentsMounted = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                IntroSection(model: model)
                    .containerRelativeFrame(.horizontal)
                    .id(0)
                Group {
                    if commentsMounted {
                        CommentSection(model: model.comments)
                    } else {
                        Color.clear
                    }
                }
                .containerRelativeFrame(.horizontal)
                .id(1)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollPosition(id: Binding(get: { tab }, set: { if let value = $0 { tab = value } }))
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.containerSize.width > 0 ? geo.contentOffset.x / geo.containerSize.width : 0
        } action: { _, value in
            progress = min(max(value, 0), 1)
            if value > 0.01, !commentsMounted { commentsMounted = true }
        }
        .onChange(of: tab, initial: true) { _, value in
            if value == 1 { commentsMounted = true }
        }
        .sensoryFeedback(.selection, trigger: tab)
    }
}

/// 下划线位置由横滑进度插值，滑动中间被拉长一点（液体感），松手吸附
private struct DetailTabs: View {
    var selection: Int
    var progress: CGFloat
    var replyCount: Int?
    var onCompose: () -> Void
    var onSelect: (Int) -> Void
    /// 两个标签下划线槽位的中心（在本视图坐标系中）
    @State private var slots: [Int: CGPoint] = [:]
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            tab("简介", index: 0)
            tab("评论", index: 1, badge: replyCount?.biliCount)
            Spacer()
            Button(action: onCompose) {
                HStack(spacing: 6) {
                    Text("点我发弹幕").foregroundStyle(Theme.secondaryText)
                    Text("弹")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Theme.selection, in: .circle)
                }
                .font(.system(size: 13))
                .padding(.leading, 12)
                .padding(.trailing, 5)
                .frame(height: 32)
            }
            .buttonStyle(PressableStyle())
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { indicator }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private static let space = "detailTabs"

    @ViewBuilder
    private var indicator: some View {
        if let start = slots[0], let end = slots[1] {
            let t = progress
            // 中途拉长，两端回到 16pt
            let width = 16 + 18 * sin(t * .pi)
            Capsule()
                .fill(accent)
                .frame(width: width, height: 3)
                .shadow(color: accent.opacity(0.5), radius: 3)
                .position(x: start.x + (end.x - start.x) * t, y: start.y)
                .allowsHitTesting(false)
        }
    }

    private func tab(_ title: String, index: Int, badge: String? = nil) -> some View {
        let on = selection == index
        return Button {
            onSelect(index)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 15, weight: on ? .bold : .medium))
                    if let badge { Text(badge).font(.system(size: 12)) }
                }
                .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                .animation(Motion.micro, value: on)
                // 下划线的槽位：真正的下划线是上面 overlay 里的那一条
                Color.clear
                    .frame(width: 16, height: 3)
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        let frame = proxy.frame(in: .named(Self.space))
                        return CGPoint(x: frame.midX, y: frame.midY)
                    } action: { slots[index] = $0 }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct IntroSection: View {
    let model: VideoDetailModel
    @State private var toast: String?
    @State private var showFavorite = false
    @State private var showCache = false
    @State private var showCoin = false
    /// 长按点赞蓄力中（点赞、投币、收藏三个图标外圈同时走一圈，满了即三连）
    @State private var charging = false
    @State private var tripled = 0
    @Environment(SessionStore.self) private var session
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .toast($toast, bottomPadding: 24)
            .sheet(isPresented: $showFavorite) {
                if let detail = model.detail, let mid = session.user?.mid {
                    FavoriteSheet(aid: detail.aid, mid: mid) { favoured in
                        model.setFavoured(favoured)
                        toast = favoured ? "已收藏" : "已取消收藏"
                    }
                }
            }
            .sheet(isPresented: $showCache) {
                if let detail = model.detail {
                    CacheSheet(detail: detail, part: model.currentPart, qualities: model.player.qualities, current: model.player.quality)
                }
            }
            .sheet(isPresented: $showCoin) {
                CoinSheet(model: model) { toast = $0 }
            }
    }

    /// 缓存按钮：未缓存 / 缓存中 xx% / 已缓存（多 P 时针对当前这一 P）
    private var cacheAction: some View {
        let record = model.detail.flatMap { detail in
            model.currentCid.flatMap { DownloadManager.shared.record(bvid: detail.bvid, cid: $0) }
        }
        let (title, icon): (String, String) = switch record?.state {
        case .completed: ("已缓存", "checkmark.circle.fill")
        case .some: ("\(Int((record?.progress ?? 0) * 100))%", "arrow.down.circle")
        case nil: ("缓存", "arrow.down.to.line")
        }
        return action(icon, title, on: record?.state == .completed) {
            switch record?.state {
            case .completed: toast = "已缓存，没网也能看"
            case .some: toast = "正在缓存，可在「我的 → 离线缓存」查看"
            case nil: showCache = true
            }
        }
    }

    private var content: some View {
        ScrollView {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: 14) {
                    uploader(detail.owner)
                    Text(detail.title)
                        .font(.serif(17))
                        .tracking(1)
                        .lineSpacing(3)
                    HStack(spacing: 12) {
                        Label((detail.stat.view ?? 0).biliCount, systemImage: "play.rectangle")
                        Label((detail.stat.danmaku ?? 0).biliCount, systemImage: "text.bubble")
                        Text(Date(timeIntervalSince1970: TimeInterval(detail.pubdate)), format: .dateTime.year().month().day())
                        if let tname = detail.tname { Text(tname) }
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, -6)

                    actions(detail.stat)
                    if model.pages.count > 1 {
                        PartPicker(model: model)
                    }
                    QueueStrip(bvid: model.card.bvid)
                    Theme.separator.frame(height: 1)

                    LazyVStack(spacing: 12) {
                        ForEach(Array(model.related.enumerated()), id: \.element.id) { index, card in
                            VideoLink(card: card) { VideoRow(card: card) }
                                .buttonStyle(PressableStyle())
                                .watchLaterMenu(card)
                                .riseIn(index: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            } else if let record = model.offline {
                // 断网：只显示缓存时记下的信息
                VStack(alignment: .leading, spacing: 10) {
                    Label("离线播放 · \(record.qualityName)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent.accentText(scheme))
                    Text(record.title).font(.serif(17)).tracking(1).lineSpacing(3)
                    if let owner = record.ownerName {
                        Text(owner).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else if let error = model.error {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().padding(.top, 40)
            }
        }
    }

    private func uploader(_ owner: Owner) -> some View {
        HStack(spacing: 10) {
            // 点头像或名字进入 UP 主空间
            RouteLink(route: Route.space(mid: owner.mid)) {
                HStack(spacing: 10) {
                    RemoteImage(url: owner.face, size: CGSize(width: 40, height: 40))
                        .frame(width: 40, height: 40)
                        .clipShape(.circle)
                    Text(owner.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            Spacer()
            if let relation = model.relation {
                FollowButton(relation: relation, compact: true) { toast = $0 }
            }
        }
    }

    private func actions(_ stat: VideoStat) -> some View {
        HStack {
            likeAction(stat)
            action(model.coins > 0 ? "bitcoinsign.circle.fill" : "bitcoinsign.circle", ((stat.coin ?? 0) + model.coinDelta).biliCount,
                   on: model.coins > 0, charge: charging) {
                if !session.isLoggedIn {
                    toast = "登录后才能投币"
                } else if model.coins >= model.maxCoins {
                    toast = "已经投过 \(model.maxCoins) 枚硬币了"
                } else {
                    showCoin = true
                }
            }
            action(model.isFavoured ? "star.fill" : "star", ((stat.favorite ?? 0) + model.favDelta).biliCount,
                   on: model.isFavoured, charge: charging) {
                if session.isLoggedIn { showFavorite = true } else { toast = "登录后才能收藏" }
            }
            cacheAction
            if let detail = model.detail, let url = URL(string: "https://www.bilibili.com/video/\(detail.bvid)") {
                ShareLink(item: url) { actionLabel("arrowshape.turn.up.right", (stat.share ?? 0).biliCount, on: false, charge: false) }
                    .buttonStyle(PressableStyle())
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.isLiked)
        .sensoryFeedback(.success, trigger: tripled)
    }

    /// 点赞：单击赞 / 取消；长按 1.2 秒一键三连（与 B 站一致）
    private func likeAction(_ stat: VideoStat) -> some View {
        actionLabel(model.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", ((stat.like ?? 0) + model.likeDelta).biliCount,
                    on: model.isLiked, charge: charging)
            .contentShape(.rect)
            .onTapGesture { like() }
            .onLongPressGesture(minimumDuration: 1.2) {
                triple()
            } onPressingChanged: { pressing in
                guard session.isLoggedIn else { return }
                charging = pressing
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("长按一键三连")
            .accessibilityAction { like() }
            .accessibilityAction(named: "一键三连") { triple() }
    }

    private func like() {
        Task {
            do { try await model.toggleLike() } catch { toast = error.localizedDescription }
        }
    }

    private func triple() {
        charging = false
        guard session.isLoggedIn else { toast = "登录后才能三连"; return }
        Task {
            do {
                let result = try await model.triple()
                tripled += 1
                if result.like, result.coin, result.fav {
                    toast = "三连成功"
                } else {
                    var done: [String] = []
                    if result.like { done.append("已点赞") }
                    if result.fav { done.append("已收藏") }
                    toast = (done + (result.coin ? [] : ["硬币不足或已投满"])).joined(separator: "，")
                }
                await session.refresh()
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func action(_ icon: String, _ title: String, on: Bool = false, charge: Bool = false, perform: @escaping () -> Void = {}) -> some View {
        Button(action: perform) { actionLabel(icon, title, on: on, charge: charge) }
            .buttonStyle(PressableStyle())
    }

    private func actionLabel(_ icon: String, _ title: String, on: Bool, charge: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .symbolEffect(.bounce, value: on)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                // 三连蓄力环
                .overlay {
                    Circle()
                        .trim(from: 0, to: charge ? 1 : 0)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: accent.opacity(0.6), radius: 4)
                        .animation(charge ? .linear(duration: 1.2) : .easeOut(duration: 0.2), value: charge)
                }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .contentTransition(.numericText())
        }
        .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 54)
    }
}

/// 多 P 选集：横向胶囊，当前分 P 高亮并自动滚到可见位置；分 P 多时可展开成网格
private struct PartPicker: View {
    let model: VideoDetailModel
    @State private var expanded = false
    @Namespace private var ns
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选集").font(.system(size: 15, weight: .semibold))
                Text("\(model.partIndex + 1) / \(model.pages.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    withAnimation(Motion.component) { expanded.toggle() }
                } label: {
                    Label(expanded ? "收起" : "全部", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(PressableStyle())
            }

            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.cid) { index, page in
                        chip(index, page, fullWidth: true)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.cid) { index, page in
                                chip(index, page, fullWidth: false).id(index)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollClipDisabled()
                    .onAppear { proxy.scrollTo(model.partIndex, anchor: .center) }
                    .onChange(of: model.partIndex) { _, index in
                        withAnimation(Motion.component) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.partIndex)
    }

    private func chip(_ index: Int, _ page: VideoPage, fullWidth: Bool) -> some View {
        let on = index == model.partIndex
        return Button {
            Task { await model.selectPart(index) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if on {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: model.player.isPlaying)
                    }
                    Text("P\(page.page)")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                Text(page.part)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .lineLimit(fullWidth ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: fullWidth ? nil : 150, alignment: .leading)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(on ? accent.opacity(0.14) : Theme.separator.opacity(0.5))
                if on {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accent.opacity(0.6), lineWidth: 1)
                        .matchedGeometryEffect(id: "part", in: ns)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("第 \(page.page) P：\(page.part)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 横向视频行：相关推荐、搜索结果
struct VideoRow: View {
    let card: VideoCard
    /// 搜索结果里带关键词高亮
    var attributedTitle: AttributedString?
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: card.pic, size: CGSize(width: 150, height: 84))
                .frame(width: 150, height: 84)
                .overlay(alignment: .bottomTrailing) {
                    Text(card.duration.durationText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
                .clipShape(.rect(cornerRadius: 10))
                .videoCover(cornerRadius: 10)
            VStack(alignment: .leading) {
                Text(attributedTitle ?? AttributedString(card.title))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(subtitle ?? "\(card.owner?.name ?? "") · \((card.stat?.view ?? 0).biliCount)播放")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 84)
    }
}

/// 只在手势开始时读一次的位置，不触发重绘
final class FrameBox {
    var maxY: CGFloat = .infinity
}
