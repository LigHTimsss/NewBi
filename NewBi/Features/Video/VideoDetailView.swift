import SwiftUI

@MainActor
@Observable
final class VideoDetailModel {
    let card: VideoCard
    let player = PlayerController()
    /// 卡片 id 即 aid，评论不必等详情返回
    let comments: CommentModel
    private(set) var detail: VideoDetail?
    private(set) var related: [VideoCard] = []
    private(set) var onlineText: String?
    /// 与 UP 主的关注关系，详情返回后创建
    private(set) var relation: RelationModel?
    private(set) var isFavoured = false
    private(set) var error: String?
    /// 断网时用离线缓存播放（详情接口拿不到时）
    private(set) var offline: DownloadRecord?
    /// 「已定位到上次观看位置」提示
    var resumeHint: String?

    init(card: VideoCard) {
        self.card = card
        comments = CommentModel(oid: card.id)
    }

    func load() async {
        async let relatedTask = try? BiliClient.shared.get(.related(bvid: card.bvid), as: [VideoCard].self)
        do {
            let detail = try await BiliClient.shared.get(.view(bvid: card.bvid), as: VideoDetail.self)
            self.detail = detail
            let relation = RelationModel(mid: detail.owner.mid)
            self.relation = relation

            // 登录后从上次看到的位置续播（跨设备同步）
            let loggedIn = BiliClient.csrfToken != nil
            let resume = loggedIn ? await resumePosition(detail) : nil
            await player.load(bvid: detail.bvid, cid: detail.cid, startAt: resume)
            if let resume { resumeHint = "已定位到上次观看位置 \(Int(resume).durationText)" }

            await relation.refresh()
            if loggedIn {
                isFavoured = (try? await BiliClient.shared.get(.favoured(aid: detail.aid), as: FavouredInfo.self).favoured) ?? false
            }
            onlineText = try? await BiliClient.shared.get(.onlineTotal(bvid: detail.bvid, cid: detail.cid), as: OnlineTotal.self).total
        } catch {
            // 没网但已缓存：直接播本地文件
            if let record = DownloadManager.shared.completed(bvid: card.bvid, cid: card.cid ?? 0)
                ?? DownloadManager.shared.record(bvid: card.bvid).flatMap({ $0.state == .completed ? $0 : nil }) {
                offline = record
                await player.load(bvid: record.bvid, cid: record.cid)
            } else {
                self.error = error.localizedDescription
            }
        }
        related = await relatedTask ?? []
    }

    /// 只在同一分 P、且离开头和结尾都有一段距离时续播
    private func resumePosition(_ detail: VideoDetail) async -> Double? {
        guard let info = try? await BiliClient.shared.get(.playerInfo(bvid: detail.bvid, cid: detail.cid), as: PlayerInfo.self),
              info.lastPlayCid == detail.cid, let ms = info.lastPlayTime else { return nil }
        let seconds = Double(ms) / 1000
        return seconds > 5 && seconds < Double(detail.duration) - 10 ? seconds : nil
    }

    func setFavoured(_ value: Bool) {
        isFavoured = value
    }

    /// 上报播放进度，让历史记录和其它设备的续播保持同步（离开页面、进入后台时调用）
    func reportProgress() async {
        guard let detail, let csrf = BiliClient.csrfToken, player.currentTime > 0 else { return }
        let finished = player.duration > 0 && player.currentTime >= player.duration - 5
        try? await BiliClient.shared.post(.historyReport, form: [
            "aid": "\(detail.aid)", "cid": "\(detail.cid)",
            "progress": finished ? "-1" : "\(Int(player.currentTime))", "csrf": csrf,
        ])
    }
}

/// 「视频详情」画板：顶部播放器 + 简介/评论 Tab + UP 主、三连、相关推荐。
/// 全屏不另开页面：同一个播放器视图原地放大到整屏（AVPlayerLayer、弹幕图层都不重建），界面转为横屏。
struct VideoDetailView: View {
    let card: VideoCard
    @State private var model: VideoDetailModel?
    @State private var tab = 0
    @State private var isFullscreen = false
    @State private var locked = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
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
                return
            }
            // 延迟创建：避免视图重建时重复创建 AVPlayer
            let created = VideoDetailModel(card: card)
            model = created
            await created.load()
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        // 返回时若正在播放就缩成迷你播放条；进入相关推荐等其它页面时暂停。
        // 都不是时模型随页面释放，PlayerController 在 deinit 中清理
        .onDisappear {
            if let model { NowPlaying.shared.detailDisappeared(model) }
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if isFullscreen { Orientation.lock(.portrait) }
        }
        .toast(Binding(get: { model?.resumeHint }, set: { model?.resumeHint = $0 }), bottomPadding: 40)
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
        .background(Color.black.ignoresSafeArea(edges: isFullscreen ? .all : .top))
    }

    private func setFullscreen(_ on: Bool, preferred: UIInterfaceOrientationMask = .landscapeRight) {
        if !on { locked = false }
        isFullscreen = on
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
    @State private var liked = false
    @State private var toast: String?
    @State private var showFavorite = false
    @State private var showCache = false
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
                    CacheSheet(detail: detail, qualities: model.player.qualities, current: model.player.quality)
                }
            }
    }

    /// 缓存按钮：未缓存 / 缓存中 xx% / 已缓存
    private var cacheAction: some View {
        let record = model.detail.flatMap { DownloadManager.shared.record(bvid: $0.bvid, cid: $0.cid) }
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
            action(liked ? "hand.thumbsup.fill" : "hand.thumbsup", ((stat.like ?? 0) + (liked ? 1 : 0)).biliCount, on: liked) {
                withAnimation(Motion.component) { liked.toggle() }
            }
            action("bitcoinsign.circle", (stat.coin ?? 0).biliCount)
            action(model.isFavoured ? "star.fill" : "star", (stat.favorite ?? 0).biliCount, on: model.isFavoured) {
                if session.isLoggedIn { showFavorite = true } else { toast = "登录后才能收藏" }
            }
            cacheAction
            action("arrowshape.turn.up.right", (stat.share ?? 0).biliCount)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
    }

    private func action(_ icon: String, _ title: String, on: Bool = false, perform: @escaping () -> Void = {}) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .symbolEffect(.bounce, value: on)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(PressableStyle())
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
