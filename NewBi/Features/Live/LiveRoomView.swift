import SwiftUI

/// 直播间数据：房间资料、主播、关注状态，播放交给 App 自己的播放器（PlayerController 的直播模式）
@MainActor
@Observable
final class LiveRoomModel {
    let requestedRoomID: Int
    let player = PlayerController()
    private(set) var info: LiveRoomInfo?
    private(set) var anchor: LiveStatus?
    private(set) var relation: RelationModel?
    /// 房间资料拿不到（房间号不对、网络问题）
    private(set) var error: String?

    init(roomID: Int) {
        requestedRoomID = roomID
    }

    var isLive: Bool { info?.isLive ?? false }

    func load() async {
        do {
            let info = try await LiveAPI.roomInfo(roomID: requestedRoomID)
            self.info = info
            error = nil
            if info.uid > 0 {
                if relation == nil {
                    let relation = RelationModel(mid: info.uid)
                    self.relation = relation
                    Task { await relation.refresh() }
                }
                if let rooms = try? await LiveAPI.status(uids: [info.uid]) { anchor = rooms[info.uid] }
                LiveStatusCenter.shared.refresh(info.uid)
            }
            guard info.isLive else {
                player.pause()
                return
            }
            // 视频页还在胶囊里播的话先停下，免得两路声音
            VideoStage.shared.model?.player.pause()
            if player.liveRoomID != info.roomID {
                await player.loadLive(roomID: info.roomID)
            } else if player.error != nil {
                player.retry()
            }
            player.setNowPlaying(
                title: info.title,
                artist: anchor?.uname ?? "直播",
                cover: info.cover.isEmpty ? info.keyframe : info.cover
            )
        } catch {
            if info == nil { self.error = error.localizedDescription }
            else { ToastCenter.shared.show(error.localizedDescription) }
        }
    }

    /// 离开直播间：停流、交出锁屏控制
    func close() {
        player.shutdown()
    }

    var shareURL: URL? {
        guard let info else { return nil }
        return URL(string: "https://live.bilibili.com/\(info.roomID)")
    }
}

/// 「直播间」：照官方客户端的竖屏直播间排布——顶部画面，下面主播条、房间资料和简介；
/// 不做礼物、购物车、互动（聊天）这些。画面用 App 自己的播放器，全屏和视频页同一套控件（去掉倍速）
struct LiveRoomView: View {
    @State private var model: LiveRoomModel
    @State private var fullscreen = false
    @State private var locked = false
    @State private var lastDeviceOrientation: UIDeviceOrientation = .unknown
    @State private var appeared = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("backgroundPlay") private var backgroundPlay = true

    init(roomID: Int) {
        _model = State(initialValue: LiveRoomModel(roomID: roomID))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                stage
                    .frame(height: fullscreen ? geo.size.height : geo.size.width * 9 / 16)

                // 全屏时不移除，只收起：退出全屏后滚动位置还在
                LiveRoomDetails(model: model) { toast = $0 }
                    .frame(height: fullscreen ? 0 : nil)
                    .clipped()
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
                    .accessibilityHidden(fullscreen)
            }
        }
        .background(fullscreen ? Color.black : Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .toast($toast, bottomPadding: 40)
        .task {
            // 从主播空间返回时也会再走一遍：直播已经在放就只刷新资料
            await model.load()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // 去了别的页面再回来：直播回到最新画面
            if appeared, model.isLive { model.player.retry() }
            appeared = true
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if fullscreen { setFullscreen(false) }
            model.player.pause()
        }
        // 只在这个页面真正被移出导航栈时停流（推入主播空间时视图还在，不收尾）
        .background(DismantleObserver { model.close() })
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            followDeviceOrientation()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lastDeviceOrientation = UIDevice.current.orientation }
            guard phase == .background, !backgroundPlay, !model.player.isPictureInPictureActive else { return }
            model.player.pause()
        }
    }

    // MARK: 画面

    private var stage: some View {
        ZStack {
            if model.isLive {
                PlayerSurface(controller: model.player, showsDanmaku: false)
                    .ignoresSafeArea(edges: fullscreen ? .all : [])
                // 第一帧出来之前盖着直播封面
                cover
                    .opacity(model.player.hasFrame ? 0 : 1)
                    .animation(Motion.micro, value: model.player.hasFrame)
                    .allowsHitTesting(false)
            } else {
                cover
                if let info = model.info, !info.isLive {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 26))
                        Text("主播还没开播").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                } else if model.info == nil, model.error == nil {
                    ProgressView().tint(.white)
                }
            }

            if fullscreen {
                LiveFullscreenOverlay(
                    model: model,
                    locked: $locked,
                    onExit: { setFullscreen(false) },
                    onAnchor: { mid in
                        // 先退出全屏、等转回竖屏，再进空间
                        setFullscreen(false)
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            pushSpace(mid)
                        }
                    }
                )
            } else {
                LiveCompactOverlay(
                    model: model,
                    onBack: { dismiss() },
                    onFullscreen: { setFullscreen(true) }
                )
            }

            LiveStatusView(model: model)
        }
        .background(Color.black.ignoresSafeArea(edges: fullscreen ? .all : .top))
        .clipped()
    }

    @ViewBuilder
    private var cover: some View {
        if let info = model.info {
            RemoteImage(url: info.cover.isEmpty ? info.keyframe : info.cover, size: CGSize(width: 430, height: 242), background: .black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Color.black.opacity(model.isLive ? 0 : 0.45))
                .clipped()
        } else {
            Color.black
        }
    }

    @Environment(\.pushRoute) private var pushRoute

    private func pushSpace(_ mid: Int) {
        pushRoute?(.space(mid: mid))
    }

    // MARK: 全屏

    private var isPortraitStream: Bool {
        model.player.liveVideoIsPortrait ?? model.info?.isPortrait ?? false
    }

    /// 横屏直播转横屏；手机竖屏开播的直播保持竖屏铺满
    private func setFullscreen(_ on: Bool, preferred: UIInterfaceOrientationMask? = nil) {
        lastDeviceOrientation = UIDevice.current.orientation
        if !on { locked = false }
        let portrait = isPortraitStream
        // 和视频页一样不另加动画：画面跟着系统转屏一起放大
        fullscreen = on
        BackGesture.shared.isBlocked = on
        if on, !portrait {
            Orientation.lock(.landscape, preferred: preferred ?? .landscapeRight)
        } else {
            Orientation.lock(.portrait)
        }
    }

    /// 横过手机自动进入全屏，竖回来退出（锁屏、竖屏直播时不跟随）
    private func followDeviceOrientation() {
        guard scenePhase == .active, !locked, model.isLive, !model.player.isPictureInPictureActive,
              !isPortraitStream else { return }
        let device = UIDevice.current.orientation
        guard device == .portrait || device.isLandscape, device != lastDeviceOrientation else { return }
        lastDeviceOrientation = device
        if let mask = Orientation.interfaceMask(for: device), !fullscreen {
            setFullscreen(true, preferred: mask)
        } else if device == .portrait, fullscreen {
            setFullscreen(false)
        }
    }
}

// MARK: - 页面被移出导航栈

/// SwiftUI 没有「页面被 pop 掉」的回调：onDisappear 推入下一页时也会触发。
/// 挂一个空的 UIView，它被拆掉（dismantle）时才是这一页真的没了
private struct DismantleObserver: UIViewRepresentable {
    let onDismantle: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onDismantle = onDismantle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.onDismantle?()
    }

    @MainActor
    final class Coordinator {
        var onDismantle: (@MainActor () -> Void)?
    }
}

// MARK: - 播放区提示

/// 移动网络确认、取流失败、下播：盖在画面中间，带一个能直接解决问题的按钮
private struct LiveStatusView: View {
    let model: LiveRoomModel

    private struct Status: Equatable {
        let text: String
        let action: String
        let kind: Kind
        enum Kind { case cellular, stream, room }
    }

    private var status: Status? {
        if let error = model.error, model.info == nil {
            return Status(text: error, action: "重试", kind: .room)
        }
        guard model.isLive else { return nil }
        let player = model.player
        if player.needsCellularConfirm {
            return Status(text: "正在使用移动网络，观看直播将消耗流量", action: "继续观看", kind: .cellular)
        }
        if let error = player.error {
            return Status(text: error, action: "刷新", kind: .stream)
        }
        return nil
    }

    var body: some View {
        let status = status
        ZStack {
            if let status {
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
        case .stream: Task { await model.load() }
        case .room: Task { await model.load() }
        }
    }
}

// MARK: - 竖屏小窗控件

/// 和视频页小窗同一套：返回、投屏、更多在上，播放 / 刷新 / 画质 / 全屏在下。直播没有进度条
private struct LiveCompactOverlay: View {
    let model: LiveRoomModel
    var onBack: () -> Void
    var onFullscreen: () -> Void
    @State private var showControls = true
    @State private var showMore = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accent) private var accent

    private var player: PlayerController { model.player }

    var body: some View {
        ZStack {
            Color.clear
            if showControls {
                controls.transition(.opacity)
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { if model.isLive { player.togglePlay() } }
        .onTapGesture {
            withAnimation(Motion.micro) { showControls.toggle() }
            scheduleHide()
        }
        .sheet(isPresented: $showMore, onDismiss: scheduleHide) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { MorePanel(controller: player, model: nil) }
                    .padding(22)
            }
            .preferredColorScheme(.dark)
            .foregroundStyle(.white)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onAppear { scheduleHide() }
        .onChange(of: player.isPlaying) { scheduleHide() }
    }

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassCircleButton(systemImage: "chevron.left", label: "返回", size: 36, glass: .clear, action: onBack)
                    Spacer()
                    if let url = model.shareURL {
                        GlassCircleButton(systemImage: "square.and.arrow.up", label: "分享", size: 36, glass: .clear) {
                            ShareCenter.shared.share(title: model.info?.title ?? "直播间", url: url)
                        }
                    }
                    if model.isLive {
                        RoutePicker(activeTint: UIColor(accent))
                            .frame(width: 36, height: 36)
                            .glassEffect(.clear.interactive(), in: .circle)
                            .accessibilityLabel("投屏")
                        GlassCircleButton(systemImage: "ellipsis", label: "更多", size: 36, glass: .clear) { showMore = true }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Spacer()
            if model.isLive {
                bottomBar
            }
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 60)
                .allowsHitTesting(false)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button { player.retry() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .accessibilityLabel("刷新直播")

            if let online = model.info?.online, online > 0 {
                Label(online.biliCount, systemImage: "flame")
                    .labelStyle(CompactLabelStyle())
                    .monospacedDigit()
                    .accessibilityLabel("人气 \(online.biliCount)")
            }

            Spacer()

            if player.qualities.count > 1 {
                Menu {
                    Picker("画质", selection: Binding(
                        get: { player.quality },
                        set: { qn in Task { await player.changeQuality(qn) } }
                    )) {
                        ForEach(player.qualities) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Text(player.qualities.first(where: { $0.id == player.quality })?.shortName ?? "画质")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(height: 28)
                }
            }

            Button(action: onFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28)
            }
            .accessibilityLabel("全屏")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying, !showMore else { return }
            withAnimation(Motion.micro) { showControls = false }
        }
    }
}

// MARK: - 画面下面的资料

private struct LiveRoomDetails: View {
    let model: LiveRoomModel
    var onMessage: (String) -> Void
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        if let info = model.info {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    anchorBar(info)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Divider().opacity(0.6)
                    VStack(alignment: .leading, spacing: 22) {
                        roomCard(info)
                        anchorCard(info)
                        let intro = info.plainDescription
                        if !intro.isEmpty {
                            section("直播间简介") {
                                Text(intro)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.load() }
        } else if model.error == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            Spacer()
        } else {
            Spacer()
        }
    }

    // 画面正下方：头像、名字、人气、关注（官方直播间的主播条）
    private func anchorBar(_ info: LiveRoomInfo) -> some View {
        HStack(spacing: 10) {
            Button { pushRoute?(.space(mid: info.uid)) } label: {
                HStack(spacing: 10) {
                    RemoteImage(url: model.anchor?.face, size: CGSize(width: 40, height: 40))
                        .frame(width: 40, height: 40)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.anchor?.uname ?? " ")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(info.isLive ? "\(info.online.biliCount) 人气 · \(info.attention.biliCount) 粉丝" : "\(info.attention.biliCount) 粉丝")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let relation = model.relation {
                FollowButton(relation: relation, compact: true) { onMessage($0) }
            }
        }
    }

    private func roomCard(_ info: LiveRoomInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.title)
                .font(.serif(19))
                .tracking(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            FlowRow(spacing: 6) {
                if info.isLive { LiveTag(height: 20) }
                let area = [info.parentAreaName, info.areaName].filter { !$0.isEmpty }.joined(separator: " · ")
                if !area.isEmpty { chip(area, systemImage: "square.grid.2x2") }
                if info.isLive, let started = info.startedAt {
                    // 已播时长每分钟走一次，不必每秒重绘
                    TimelineView(.everyMinute) { context in
                        chip(Self.elapsed(since: started, now: context.date), systemImage: "clock")
                    }
                }
                chip("房间号 \(info.roomID)", systemImage: "number")
            }
            if !info.tags.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(info.tags.prefix(8), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private func anchorCard(_ info: LiveRoomInfo) -> some View {
        section("主播") {
            Button { pushRoute?(.space(mid: info.uid)) } label: {
                HStack(spacing: 12) {
                    RemoteImage(url: model.anchor?.face, size: CGSize(width: 48, height: 48))
                        .frame(width: 48, height: 48)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.anchor?.uname ?? "主播")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("\(info.attention.biliCount) 粉丝")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Text("进入主页")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(14)
                .background(Theme.selection, in: .rect(cornerRadius: 18, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.selection, in: .capsule)
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start)) / 60)
        return minutes >= 60 ? "已播 \(minutes / 60) 小时 \(minutes % 60) 分" : "已播 \(minutes) 分钟"
    }
}

/// 自动换行的一排小标签
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
