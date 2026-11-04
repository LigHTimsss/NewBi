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

    var pages: [VideoPage] { detail?.pages ?? [] }
    var currentPart: VideoPage? { pages.indices.contains(partIndex) ? pages[partIndex] : nil }
    var currentCid: Int? { currentPart?.cid ?? detail?.cid }
    var maxCoins: Int { 2 }

    init(card: VideoCard) {
        self.card = card
        comments = CommentModel(oid: card.id)
    }

    func load() async {
        async let relatedTask = try? BiliClient.shared.get(.related(bvid: card.bvid), as: [VideoCard].self)
        do {
            let detail = try await BiliClient.shared.get(.view(bvid: card.bvid), as: VideoDetail.self)
            self.detail = detail
            if card.id == 0 { comments = CommentModel(oid: detail.aid) }
            let relation = RelationModel(mid: detail.owner.mid)
            self.relation = relation

            // 登录后从上次看到的位置续播（跨设备同步）；多 P 时直接回到上次看的那一 P
            let loggedIn = BiliClient.csrfToken != nil
            let resume = loggedIn ? await resumePosition(detail) : nil
            if let cid = resume?.cid ?? card.cid, let index = pages.firstIndex(where: { $0.cid == cid }) {
                partIndex = index
            }
            configureParts()
            await player.load(bvid: detail.bvid, cid: currentCid ?? detail.cid, startAt: resume?.seconds)
            updateNowPlaying()
            if let resume {
                let part = pages.count > 1 ? "P\(partIndex + 1) " : ""
                resumeHint = "已定位到上次观看位置 \(part)\(Int(resume.seconds).durationText)"
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
            // 没网但已缓存：直接播本地文件
            if let record = DownloadManager.shared.completed(bvid: card.bvid, cid: card.cid ?? 0)
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
        guard let detail, pages.indices.contains(index), index != partIndex else { return }
        await reportProgress()
        partIndex = index
        configureParts()
        await player.load(bvid: detail.bvid, cid: pages[index].cid)
        updateNowPlaying()
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

    /// 上报播放进度，让历史记录和其它设备的续播保持同步（离开页面、进入后台、切分 P 时调用）
    func reportProgress() async {
        guard let detail, let cid = currentCid, let csrf = BiliClient.csrfToken, player.currentTime > 0 else { return }
        let finished = player.duration > 0 && player.currentTime >= player.duration - 5
        try? await BiliClient.shared.post(.historyReport, form: [
            "aid": "\(detail.aid)", "cid": "\(cid)",
            "progress": finished ? "-1" : "\(Int(player.currentTime))", "csrf": csrf,
        ])
    }
}

/// 「视频详情」画板：顶部播放器 + 简介/评论 Tab + UP 主、三连、相关推荐。
/// 全屏不另开页面：同一个播放器视图原地放大到整屏（AVPlayerLayer、弹幕图层都不重建），界面转为横屏。
struct VideoDetailView: View {
    let card: VideoCard
    /// 连播队列：播完后换到下一个视频（由 VideoDestination 原地替换）
    var onAdvance: ((VideoCard) -> Void)? = nil
    @State private var model: VideoDetailModel?
    @State private var upNext: VideoCard?
    @State private var tab = 0
    @State private var isFullscreen = false
    @State private var locked = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var parentOpenURL
    @AppStorage("backgroundPlay") private var backgroundPlay = true

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                player
                    .frame(height: isFullscreen ? geo.size.height : geo.size.width * 9 / 16)

                if !isFullscreen {
                    DetailTabs(selection: $tab, replyCount: model?.comments.total ?? model?.detail?.stat.reply)
                    if let model {
                        if tab == 0 {
                            IntroSection(model: model)
                        } else {
                            CommentSection(model: model.comments)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(isFullscreen ? Color.black : Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .task {
            guard model == nil else { return }
            // 从迷你播放条点回来：直接接回同一个播放器，不重新取流
            if let restored = NowPlaying.shared.claim(for: card) {
                model = restored
                configureQueue(restored)
                return
            }
            // 延迟创建：避免视图重建时重复创建 AVPlayer
            let created = VideoDetailModel(card: card)
            model = created
            configureQueue(created)
            await created.load()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // 从上层页面（UP 主空间、相关推荐）返回：取消待定的暂停
            if let model { NowPlaying.shared.detailAppeared(model) }
            BackGesture.shared.isBlocked = isFullscreen
        }
        // 返回时若正在播放就缩成迷你播放条；进入相关推荐等其它页面时暂停。
        // 都不是时模型随页面释放，PlayerController 在 deinit 中清理
        .onDisappear {
            if let model { NowPlaying.shared.detailDisappeared(model) }
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if isFullscreen { Orientation.lock(.portrait) }
            BackGesture.shared.isBlocked = false
        }
        .toast(Binding(get: { model?.resumeHint }, set: { model?.resumeHint = $0 }), bottomPadding: 40)
        // 评论里的时间点：跳到该位置并继续播放；其它链接交回上层
        .environment(\.openURL, OpenURLAction { url in
            if case .seek(let seconds) = AppLink.parse(url), let model {
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
            guard phase == .background, let model else { return }
            Task { await model.reportProgress() }
            guard !backgroundPlay, !model.player.isPictureInPictureActive else { return }
            model.player.pause()
        }
    }

    private var player: some View {
        ZStack {
            if let model {
                PlayerSurface(controller: model.player)
                    .ignoresSafeArea(edges: isFullscreen ? .all : [])
                if isFullscreen {
                    FullscreenOverlay(model: model, locked: $locked, onExit: { setFullscreen(false) })
                } else {
                    CompactOverlay(
                        controller: model.player,
                        card: model.card,
                        onBack: { dismiss() },
                        onFullscreen: { setFullscreen(true) }
                    )
                }
            } else {
                Color.black
            }
        }
        .overlay(alignment: .bottom) {
            if let next = upNext {
                UpNextCard(next: next, queueTitle: PlayQueue.shared.title) {
                    upNext = nil
                    onAdvance?(next)
                } onCancel: {
                    withAnimation(Motion.component) { upNext = nil }
                }
                .frame(maxWidth: 460)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea(edges: isFullscreen ? .all : .top))
    }

    /// 在连播队列里时：播完弹出「即将播放」，3 秒后换到下一个
    private func configureQueue(_ model: VideoDetailModel) {
        guard onAdvance != nil else { return }
        let bvid = card.bvid
        model.player.onEnded = {
            guard let next = PlayQueue.shared.next(after: bvid) else { return }
            withAnimation(Motion.component) { upNext = next }
        }
    }

    private func setFullscreen(_ on: Bool, preferred: UIInterfaceOrientationMask = .landscapeRight) {
        if !on { locked = false }
        isFullscreen = on
        // 全屏里左右滑是拖进度，关掉侧滑返回
        BackGesture.shared.isBlocked = on
        if on {
            Orientation.lock(.landscape, preferred: preferred)
        } else {
            Orientation.lock(.portrait)
        }
    }

    private func followDeviceOrientation() {
        guard model != nil, !locked else { return }
        let device = UIDevice.current.orientation
        if let mask = Orientation.interfaceMask(for: device), !isFullscreen {
            setFullscreen(true, preferred: mask)
        } else if device == .portrait, isFullscreen {
            setFullscreen(false)
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
                    GlassCircleButton(systemImage: "tv", label: "投屏", size: 36, glass: .clear)
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

private struct DetailTabs: View {
    @Binding var selection: Int
    var replyCount: Int?
    @Namespace private var ns
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            tab("简介", index: 0)
            tab("评论", index: 1, badge: replyCount?.biliCount)
            Spacer()
            Button {} label: {
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
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private func tab(_ title: String, index: Int, badge: String? = nil) -> some View {
        let on = selection == index
        return Button {
            withAnimation(Motion.component) { selection = index }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 15, weight: on ? .bold : .medium))
                    if let badge { Text(badge).font(.system(size: 12)) }
                }
                .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                ZStack {
                    if on { Capsule().fill(accent).matchedGeometryEffect(id: "detailTab", in: ns) }
                }
                .frame(width: 16, height: 3)
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
                            NavigationLink(value: card) { VideoRow(card: card) }
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
            NavigationLink(value: Route.space(mid: owner.mid)) {
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
