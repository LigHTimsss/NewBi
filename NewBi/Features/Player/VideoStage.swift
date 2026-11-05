import SwiftUI
import UIKit

/// 视频舞台：视频页不进导航栈，而是一层铺在整个 App 上的「舞台」，每一帧的形状、位置都由我们算。
///
/// 为什么不用系统的缩放转场：它的来源 id 在推入时就定死、找不到来源时直接退化成淡出，
/// 「返回时收进迷你胶囊」「从胶囊展开」都没法保证连贯（之前就是视频直接消失、胶囊再冒出来）。
/// 现在只有一个容器在卡片封面 ⇄ 整页 ⇄ 迷你胶囊之间插值：
/// - `progress` 1 = 铺满的视频页，0 = 收在锚点（卡片封面 / 胶囊）；
/// - 容器的矩形、圆角、背景（页面底色 ⇄ 玻璃）、页面内容和胶囊内容的透明度都是它的函数；
/// - 画面是同一个播放器视图，从页面顶部的播放区连续移动到胶囊左边的小画面，不重建、不黑屏；
/// - 侧滑 / 下拉时页面跟手缩小，松手后从手指的位置接着收进胶囊或卡片。
@MainActor
@Observable
final class VideoStage {
    static let shared = VideoStage()

    /// 收起时落到哪里
    enum Anchor: Equatable {
        /// 打开它的那张卡片的封面（暂停时返回）
        case card
        /// 迷你胶囊（正在播放时返回、或从视频页进了别的页面）
        case capsule
        /// 找不到卡片（已滑出屏幕、换过视频）：原地缩小淡出
        case none
    }

    /// 跟手拖动时页面的缩放和位移
    struct Drag: Equatable {
        var scale: CGFloat = 1
        var offset: CGSize = .zero
        static let zero = Drag()
    }

    enum DragKind { case edge, down }

    private(set) var model: VideoDetailModel?
    private(set) var progress: CGFloat = 0
    private(set) var anchor: Anchor = .none
    private(set) var drag = Drag.zero
    /// 收起 / 展开的动画进行中（期间页面不接收触摸）
    private(set) var isAnimating = false
    /// 停在迷你胶囊
    private(set) var isMinimized = false
    /// 卡片封面在屏幕上的位置和圆角（打开 / 收回时读一次）
    private(set) var cardFrame: CGRect = .zero
    private(set) var cardRadius: CGFloat = 12
    /// 胶囊左右滑动关闭时的位移
    private(set) var miniShift: CGFloat = 0
    /// 关闭胶囊时整体淡出
    private(set) var fade: CGFloat = 1
    /// 被舞台盖住的卡片封面（展开中、收回卡片的途中隐藏，就像被「拿起来」了）
    private(set) var hiddenSource: VideoSource?
    /// 视频页横屏全屏时不能收起
    var isFullscreen = false

    @ObservationIgnored private var source: VideoSource?
    /// 在视频页里点相关推荐：原地换视频，返回键先回到上一个
    @ObservationIgnored private var history: [VideoCard] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var dragKind: DragKind?
    @ObservationIgnored private var miniAxis: Axis?
    /// 舞台的尺寸（整屏），StageView 布局时写入
    @ObservationIgnored var canvasSize = CGSize(width: 393, height: 852)

    /// 页面底部要给迷你胶囊让位
    var showsMini: Bool { model != nil && anchor == .capsule }
    /// 视频页铺满、可以操作
    var pageInteractive: Bool { model != nil && !isMinimized && !isAnimating }
    /// 视频页盖住了下面的 App（无障碍、返回手势据此避让）
    var coversApp: Bool { model != nil && !isMinimized }

    private var miniEnabled: Bool { UserDefaults.standard.object(forKey: "miniPlayer") as? Bool ?? true }

    // MARK: 打开

    /// 点视频卡片：从卡片封面展开成视频页。已经在视频页里（相关推荐）就原地换；点的是胶囊里的视频就展开胶囊
    /// - Parameter pinsPart: 卡片上的 cid 是要播的那一 P（离线缓存列表）；否则 cid 只是默认分 P，续播记录优先
    func open(_ card: VideoCard, from source: VideoSource?, pinsPart: Bool = false) {
        PlayQueue.shared.claimOpen()
        let pinned = pinsPart ? card.cid : nil
        if let model, !isMinimized {
            if model.card.bvid != card.bvid || !model.show(part: pinned) {
                swap(to: card, pinnedCid: pinned, remember: true)
            }
            return
        }
        // 胶囊里就是这个视频（指定的分 P 正在播，或能原地切过去）：展开胶囊
        if let model, model.card.bvid == card.bvid, model.show(part: pinned) {
            expand()
            return
        }
        if model != nil { tearDown() }

        let created = VideoDetailModel(card: card, pinnedCid: pinned)
        // 展开途中画面归舞台（跟着容器走），铺满后交给视频页
        created.player.isMinimized = true
        Task { await created.loadIfNeeded() }

        if let source, source.isVisible, onScreen(source.rect) {
            self.source = source
            cardFrame = source.rect
            cardRadius = source.radius
            anchor = .card
            hiddenSource = source
        } else {
            self.source = nil
            anchor = .none
            hiddenSource = nil
        }
        history = []
        drag = .zero
        fade = 1
        miniShift = 0
        isMinimized = false
        model = created
        BackGesture.shared.isBlocked = true
        // 隐藏时 progress 一直是 0，所以这里同一帧里改成 1 也会从 0 动画过去
        animate(Motion.stageOpen) { progress = 1 } done: { [weak self] in self?.settleExpanded() }
    }

    /// 从胶囊展开（点胶囊、上滑胶囊）
    func expand() {
        guard let model, anchor == .capsule else { return }
        isMinimized = false
        model.player.isMinimized = true
        BackGesture.shared.isBlocked = true
        animate(Motion.stageExpand) { progress = 1 } done: { [weak self] in self?.settleExpanded() }
    }

    private func settleExpanded() {
        drag = .zero
        model?.player.isMinimized = false
    }

    // MARK: 收起

    /// 视频页左上角返回：先回到上一个视频，否则收起
    func back() {
        if let previous = history.popLast() {
            swap(to: previous, remember: false)
        } else {
            collapse()
        }
    }

    /// 收起视频页：正在播放 → 迷你胶囊；暂停 / 播完 → 打开它的卡片；卡片不在屏幕上 → 缩小淡出
    func collapse(toCapsule force: Bool = false) {
        guard let model, !isMinimized, !isFullscreen else { return }
        let mini = force || (miniEnabled && model.player.isPlaying)
        if mini {
            withAnimation(Motion.component) { anchor = .capsule }
            hiddenSource = nil
        } else if let source, source.isVisible, onScreen(source.rect) {
            cardFrame = source.rect
            cardRadius = source.radius
            anchor = .card
            hiddenSource = source
        } else {
            anchor = .none
            hiddenSource = nil
        }
        dragKind = nil
        model.player.isMinimized = true
        animate(Motion.stageClose) { progress = 0 } done: { [weak self] in
            guard let self else { return }
            drag = .zero
            if mini {
                isMinimized = true
                BackGesture.shared.isBlocked = false
            } else {
                tearDown()
            }
        }
    }

    /// 视频页里点了 UP 主、评论头像等要进别的页面：先收进胶囊（不管在不在播），回来点胶囊就行
    func makeRoom() {
        guard model != nil, !isMinimized else { return }
        isFullscreen = false
        collapse(toCapsule: true)
    }

    /// 关掉胶囊：淡出后释放播放器
    func close(towards direction: CGFloat = 0) {
        guard model != nil else { return }
        animate(Motion.component) {
            fade = 0
            if direction != 0 { miniShift = direction * canvasSize.width * 0.6 }
        } done: { [weak self] in self?.tearDown() }
    }

    private func tearDown() {
        guard let model else { return }
        model.player.pause()
        // 先同步取好进度快照再收尾：停播、释放引擎 / 代理、交出锁屏
        model.flushProgress()
        model.close()
        generation += 1
        isAnimating = false
        self.model = nil
        source = nil
        hiddenSource = nil
        history = []
        isMinimized = false
        anchor = .none
        progress = 0
        drag = .zero
        fade = 1
        miniShift = 0
        isFullscreen = false
        dragKind = nil
        miniAxis = nil
        BackGesture.shared.isBlocked = false
    }

    // MARK: 换视频

    /// 连播：播完换到下一个（不记进返回历史）
    func advance(to card: VideoCard) {
        swap(to: card, remember: false)
    }

    private func swap(to card: VideoCard, pinnedCid: Int? = nil, remember: Bool) {
        guard let current = model else { return }
        if remember { history.append(current.card) }
        current.player.pause()
        current.flushProgress()
        // 画面归谁沿用旧播放器的状态：停在胶囊 / 展开途中由舞台显示，铺满时由视频页显示
        // （胶囊里连播换到下一个时，新播放器默认交给隐藏着的页面，胶囊会只剩封面）
        let minimized = current.player.isMinimized
        // 立即收尾：旧视频还在路上的取流回来也不会再自动播放；淡出途中旧页面盖回封面，不闪黑
        current.close()
        let next = VideoDetailModel(card: card, pinnedCid: pinnedCid)
        next.player.isMinimized = minimized
        Task { await next.loadIfNeeded() }
        // 换过视频就不再落回最初那张卡片
        source = nil
        hiddenSource = nil
        withAnimation(Motion.component) { model = next }
    }

    // MARK: 跟手

    var canDragPage: Bool { model != nil && !isMinimized && !isAnimating && !isFullscreen }

    /// 左边缘右滑 / 在画面上下拉：页面跟手缩小
    func pageDragChanged(_ translation: CGSize, kind: DragKind) {
        guard canDragPage || dragKind != nil, model != nil else { return }
        if let dragKind, dragKind != kind { return }
        if dragKind == nil {
            dragKind = kind
            generation += 1 // 打断还在回弹的上一次
            isAnimating = false
            // 拖动中画面留在页面里、跟着页面一起缩放（这时换走手指下的画面视图，UIKit 会取消这次触摸）；
            // 松手收起时才交给舞台
        }
        let size = canvasSize
        switch kind {
        case .edge:
            let f = min(max(translation.width / size.width, 0), 1)
            drag = Drag(scale: 1 - 0.3 * f, offset: CGSize(width: max(translation.width, 0) * 0.55, height: translation.height * 0.25))
        case .down:
            let f = min(max(translation.height / size.height, 0), 1)
            drag = Drag(scale: 1 - 0.45 * f, offset: CGSize(width: translation.width * 0.45, height: max(translation.height, 0) * 0.6))
        }
    }

    func pageDragEnded(_ translation: CGSize, velocity: CGSize, kind: DragKind) {
        guard dragKind == kind else { return }
        dragKind = nil
        let commit = switch kind {
        case .edge: (translation.width > canvasSize.width * 0.2 || velocity.width > 600) && velocity.width > -200
        case .down: (translation.height > 100 || velocity.height > 700) && velocity.height > -200
        }
        if commit {
            collapse()
        } else {
            bounceBack()
        }
    }

    /// 没拖到收起的距离：弹回铺满。和收起 / 展开不同，弹回途中页面照常接收触摸、可以被下一次拖动直接接住
    /// （不置 isAnimating；新的拖动开始时世代加一，这次的完成回调就不再收尾）
    private func bounceBack() {
        generation += 1
        let token = generation
        withAnimation(Motion.component, completionCriteria: .logicallyComplete) {
            drag = .zero
        } completion: { [weak self] in
            guard let self, generation == token else { return }
            settleExpanded()
        }
    }

    /// 胶囊：上滑跟手展开，左右滑关闭
    func miniDragChanged(_ translation: CGSize) {
        guard isMinimized, !isAnimating else { return }
        if miniAxis == nil {
            guard max(abs(translation.width), abs(translation.height)) > 10 else { return }
            miniAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
        }
        if miniAxis == .horizontal {
            miniShift = translation.width
        } else {
            progress = min(max(-translation.height / (canvasSize.height * 0.6), 0), 1)
        }
    }

    func miniDragEnded(_ translation: CGSize, velocity: CGSize) {
        guard let axis = miniAxis else { return }
        miniAxis = nil
        if axis == .horizontal {
            if abs(miniShift) > 110 || abs(velocity.width) > 800 {
                close(towards: miniShift >= 0 ? 1 : -1)
            } else {
                animate(Motion.component) { miniShift = 0 } done: {}
            }
        } else if progress > 0.2 || velocity.height < -500 {
            expand()
        } else {
            animate(Motion.component) { progress = 0 } done: {}
        }
    }

    // MARK: 其它

    private func onScreen(_ rect: CGRect) -> Bool {
        rect.width > 1 && rect.height > 1 && rect.intersects(CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0, dy: 30))
    }

    /// 同一时间只认最后一次动画的完成回调（被新的手势 / 动画打断的那次不再收尾）
    private func animate(_ animation: Animation, _ changes: () -> Void, done: @escaping () -> Void) {
        generation += 1
        let token = generation
        isAnimating = true
        withAnimation(animation, completionCriteria: .logicallyComplete, changes) { [weak self] in
            guard let self, generation == token else { return }
            isAnimating = false
            done()
        }
    }
}

// MARK: - 几何

/// 舞台每一帧的几何：全部由 progress 和拖动量插值出来。
/// 各图层各自做成 Animatable，SwiftUI 每帧只重算这几个小修饰器，不重算视频页本身
struct StageMetrics {
    var progress: CGFloat
    var scale: CGFloat
    var dx: CGFloat
    var dy: CGFloat
    /// 胶囊底边离屏幕底边的距离（含安全区）
    var capsuleBottom: CGFloat
    var size: CGSize
    var insets: EdgeInsets
    var anchor: VideoStage.Anchor
    var card: CGRect
    var cardRadius: CGFloat

    static let capsuleHeight: CGFloat = 56
    /// iPhone 15 Pro 起的屏幕圆角：收起途中页面四角和屏幕圆角对齐
    static let screenRadius: CGFloat = 55

    typealias AnimatableData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>>

    var animatableData: AnimatableData {
        get { AnimatablePair(AnimatablePair(progress, scale), AnimatablePair(AnimatablePair(dx, dy), capsuleBottom)) }
        set {
            progress = newValue.first.first
            scale = newValue.first.second
            dx = newValue.second.first.first
            dy = newValue.second.first.second
            capsuleBottom = newValue.second.second
        }
    }

    /// 铺满（带拖动缩放 / 位移）时页面的矩形
    var pageRect: CGRect {
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (size.width - w) / 2 + dx, y: (size.height - h) / 2 + dy, width: w, height: h)
    }

    var capsule: CGRect {
        CGRect(x: 18, y: size.height - capsuleBottom - Self.capsuleHeight, width: size.width - 36, height: Self.capsuleHeight)
    }

    /// 胶囊左边的小画面（和 MiniControls 里留的位置一致）
    var thumb: CGRect {
        let c = capsule
        return CGRect(x: c.minX + 8, y: c.midY - 18, width: 64, height: 36)
    }

    var anchorRect: CGRect {
        switch anchor {
        case .card: card
        case .capsule: capsule
        case .none: pageRect.insetBy(dx: pageRect.width * 0.06, dy: pageRect.height * 0.06)
        }
    }

    var anchorRadius: CGFloat {
        switch anchor {
        case .card: cardRadius
        case .capsule: Self.capsuleHeight / 2
        case .none: Self.screenRadius
        }
    }

    /// 容器（页面 / 胶囊的外形）
    var rect: CGRect { lerp(anchorRect, pageRect, progress) }

    var settled: Bool { progress >= 0.999 && abs(scale - 1) < 0.001 && abs(dx) < 0.5 && abs(dy) < 0.5 }

    var radius: CGFloat {
        settled ? 0 : max(0, anchorRadius + (Self.screenRadius - anchorRadius) * progress)
    }

    /// 页面内容按容器宽度等比缩放
    var pageScale: CGFloat { max(rect.width / max(size.width, 1), 0.01) }

    /// 视频页里播放区的位置（页面坐标，与 VideoDetailView 竖屏布局一致：安全区顶部、整宽 16:9）
    var pageVideo: CGRect { CGRect(x: 0, y: insets.top, width: size.width, height: size.width * 9 / 16) }

    private func placed(_ r: CGRect, in container: CGRect) -> CGRect {
        let s = container.width / max(size.width, 1)
        return CGRect(x: container.minX + r.minX * s, y: container.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    /// 画面：锚点处（卡片封面 / 胶囊小画面）⇄ 页面顶部播放区
    var video: CGRect {
        let from: CGRect = switch anchor {
        case .card: card
        case .capsule: thumb
        case .none: placed(pageVideo, in: anchorRect)
        }
        return lerp(from, placed(pageVideo, in: pageRect), progress)
    }

    var videoRadius: CGFloat {
        let from: CGFloat = switch anchor {
        case .card: cardRadius
        case .capsule: 8
        case .none: 0
        }
        return max(0, from * (1 - progress))
    }

    // 各层的权重：胶囊内容先退场，页面底色接上，页面内容最后出现（收起时反过来）
    var pageWeight: Double { anchor == .capsule ? ramp(progress, 0.45, 0.95) : ramp(progress, 0.3, 0.9) }
    var backgroundWeight: Double { anchor == .capsule ? ramp(progress, 0.1, 0.6) : ramp(progress, 0, 0.45) }
    var glassWeight: Double { anchor == .capsule ? 1 - ramp(progress, 0.15, 0.6) : 0 }
    var miniWeight: Double { anchor == .capsule ? 1 - ramp(progress, 0, 0.3) : 0 }
    var scrimWeight: Double { ramp(progress, 0, 1) * (anchor == .capsule ? 0.6 : 1) }
    /// 没有落点时整体淡出
    var presence: Double { anchor == .none ? ramp(progress, 0, 0.5) : 1 }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: max(a.width + (b.width - a.width) * t, 1),
            height: max(a.height + (b.height - a.height) * t, 1)
        )
    }

    private func ramp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return Double(t * t * (3 - 2 * t))
    }
}

/// 圆角矩形裁切，位置和圆角每帧都在变
private struct StageClip: Shape {
    var rect: CGRect
    var radius: CGFloat

    func path(in _: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

/// 舞台的各个图层：只有这几个小修饰器每帧重算
private struct StageLayer: ViewModifier, Animatable {
    enum Role { case page, video, mini, clip }

    let role: Role
    var m: StageMetrics

    nonisolated var animatableData: StageMetrics.AnimatableData {
        get { m.animatableData }
        set { m.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        switch role {
        case .page:
            let r = m.rect
            content
                .frame(width: m.size.width, height: m.size.height)
                .scaleEffect(m.pageScale, anchor: .topLeading)
                .offset(x: r.minX, y: r.minY)
                .opacity(m.pageWeight)
        case .video:
            let v = m.video
            content
                .frame(width: v.width, height: v.height)
                .clipShape(.rect(cornerRadius: m.videoRadius))
                .offset(x: v.minX, y: v.minY)
        case .mini:
            let r = m.rect
            content
                .frame(width: m.capsule.width, height: StageMetrics.capsuleHeight)
                .offset(x: r.minX, y: r.minY)
                .opacity(m.miniWeight)
        case .clip:
            content
                .clipShape(StageClip(rect: m.rect, radius: m.radius))
                .opacity(m.presence)
        }
    }
}

/// 收起 / 展开途中压暗下面的 App（铺满和停在胶囊时不画）
private struct StageScrim: View, Animatable {
    var m: StageMetrics

    nonisolated var animatableData: StageMetrics.AnimatableData {
        get { m.animatableData }
        set { m.animatableData = newValue }
    }

    var body: some View {
        if m.scrimWeight > 0.001, !m.settled {
            Color.black.opacity(0.28 * m.scrimWeight)
                .frame(width: m.size.width, height: m.size.height)
        }
    }
}

/// 容器的底：胶囊的玻璃 ⇄ 页面底色
private struct StageBackdrop: View, Animatable {
    var m: StageMetrics

    nonisolated var animatableData: StageMetrics.AnimatableData {
        get { m.animatableData }
        set { m.animatableData = newValue }
    }

    var body: some View {
        let r = m.rect
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            if m.glassWeight > 0.001 {
                Color.clear
                    .frame(width: r.width, height: r.height)
                    .glassEffect(.regular, in: shape)
                    .opacity(m.glassWeight)
                    .offset(x: r.minX, y: r.minY)
            }
            if m.backgroundWeight > 0.001 {
                shape.fill(Theme.background)
                    .frame(width: r.width, height: r.height)
                    .opacity(m.backgroundWeight)
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
    }
}

// MARK: - 视图

/// 放在 RootView 最上层。`capsuleLift`：胶囊离底部安全区的高度（根页面在底栏上方，二级页面贴底）
struct StageView: View {
    var capsuleLift: CGFloat

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let size = CGSize(
                width: geo.size.width + insets.leading + insets.trailing,
                height: geo.size.height + insets.top + insets.bottom
            )
            StageCanvas(size: size, insets: insets, capsuleBottom: insets.bottom + capsuleLift)
                .ignoresSafeArea()
        }
    }
}

private struct StageCanvas: View {
    let size: CGSize
    let insets: EdgeInsets
    let capsuleBottom: CGFloat

    var body: some View {
        let stage = VideoStage.shared
        let m = StageMetrics(
            progress: stage.progress,
            scale: stage.drag.scale,
            dx: stage.drag.offset.width,
            dy: stage.drag.offset.height,
            capsuleBottom: capsuleBottom,
            size: size,
            insets: insets,
            anchor: stage.anchor,
            card: stage.cardFrame,
            cardRadius: stage.cardRadius
        )
        // 各层的外壳（ZStack）一直在，只有里面的内容随 model 出现 / 消失：
        // 修饰器不随内容重建，打开时 progress 才能从 0 动画到 1
        ZStack(alignment: .topLeading) {
            StageScrim(m: m)
                .allowsHitTesting(false)
            stageBody(m)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: size, initial: true) { _, value in stage.canvasSize = value }
    }

    private func stageBody(_ m: StageMetrics) -> some View {
        let stage = VideoStage.shared
        // 关闭胶囊时以胶囊为中心缩小
        let capsuleCenter = UnitPoint(x: 0.5, y: (size.height - capsuleBottom - StageMetrics.capsuleHeight / 2) / max(size.height, 1))
        return ZStack(alignment: .topLeading) {
            StageBackdrop(m: m)
                .allowsHitTesting(false)

            ZStack(alignment: .topLeading) {
                if let model = stage.model {
                    StagePage(model: model, insets: insets)
                        .id(model.card.bvid)
                        .transition(.opacity)
                }
            }
            .modifier(StageLayer(role: .page, m: m))
            .allowsHitTesting(stage.pageInteractive)
            .accessibilityHidden(!stage.coversApp)
            .gesture(StageEdgePan())

            ZStack {
                if let model = stage.model {
                    StageVideo(model: model)
                }
            }
            .modifier(StageLayer(role: .video, m: m))
            .allowsHitTesting(false)

            ZStack {
                if let model = stage.model, stage.anchor == .capsule {
                    MiniControls(model: model)
                        .transition(.identity)
                }
            }
            .modifier(StageLayer(role: .mini, m: m))
            .allowsHitTesting(stage.isMinimized)
        }
        .modifier(StageLayer(role: .clip, m: m))
        .offset(x: stage.miniShift)
        .opacity(Double(stage.fade) * (1 - Double(min(abs(stage.miniShift) / CGFloat(300), CGFloat(0.6)))))
        .scaleEffect(CGFloat(0.94) + CGFloat(0.06) * stage.fade, anchor: capsuleCenter)
    }
}

/// 视频页本体。输入只有 model 和安全区，舞台每帧重算时它不跟着重算
private struct StagePage: View {
    let model: VideoDetailModel
    let insets: EdgeInsets

    var body: some View {
        VideoDetailView(model: model, onAdvance: { VideoStage.shared.advance(to: $0) })
            .safeAreaPadding(insets)
            .environment(\.inStage, true)
    }
}

/// 舞台上的画面：收起 / 展开途中和停在胶囊时由它显示（同一个播放器视图），铺满后交给视频页。
/// 还没出第一帧时盖一张封面（和卡片同一张图，内存缓存里直接拿），落回卡片时也就看不出接缝
private struct StageVideo: View {
    let model: VideoDetailModel

    var body: some View {
        let player = model.player
        ZStack {
            if player.isMinimized {
                PlayerSurface(controller: player, showsDanmaku: false, interactive: false, isMini: true)
                VideoPoster(card: model.card)
                    .opacity(player.hasFrame ? 0 : 1)
                    .animation(Motion.micro, value: player.hasFrame)
            }
        }
    }
}

/// 视频封面占位：舞台和视频页的播放区用同一个尺寸，命中同一份缓存
struct VideoPoster: View {
    let card: VideoCard
    static let size = CGSize(width: 430, height: 242)

    var body: some View {
        RemoteImage(url: card.pic, size: Self.size, background: .black)
    }
}

/// 视频页左边缘右滑：页面跟手缩小，松手收进胶囊 / 卡片。
/// 用 UIKit 的边缘手势：只认从屏幕左边缘开始的拖动，页面里的横向分页（简介 / 评论）要等它失败才动
private struct StageEdgePan: UIGestureRecognizerRepresentable {
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let pan = UIScreenEdgePanGestureRecognizer()
        pan.edges = .left
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        let stage = VideoStage.shared
        let t = recognizer.translation(in: nil)
        let translation = CGSize(width: t.x, height: t.y)
        switch recognizer.state {
        case .began, .changed:
            stage.pageDragChanged(translation, kind: .edge)
        case .ended:
            let v = recognizer.velocity(in: nil)
            stage.pageDragEnded(translation, velocity: CGSize(width: v.x, height: v.y), kind: .edge)
        case .cancelled, .failed:
            stage.pageDragEnded(.zero, velocity: .zero, kind: .edge)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            VideoStage.shared.canDragPage
        }

        // 边缘返回优先：页面里的横向滚动等它失败再开始
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

// MARK: - 卡片入口

/// 卡片封面在屏幕上的位置：VideoLink 持有，封面（videoCover）随布局写入，舞台打开 / 收回时读取
@MainActor
final class VideoSource {
    /// 在屏幕上的位置：记的是相对所在根页面的位置，读的时候再加上页面此刻的屏幕位置
    var rect: CGRect {
        guard let space else { return local }
        return local.offsetBy(dx: space.origin.x, dy: space.origin.y)
    }
    var radius: CGFloat = 12
    var isVisible = false
    /// 卡片里标了封面：从封面展开（否则用整张卡片）
    var hasCover = false

    private var local: CGRect = .zero
    private weak var space: CoverSpace?

    func place(_ frame: CGRect, in space: CoverSpace?) {
        local = frame
        self.space = space
    }
}

/// 卡片位置的参照系：根 Tab 页各一个。
/// 切 Tab 时整页平移，卡片相对页面不动，不必每帧给每张卡片重算屏幕位置；只有页面自己每帧更新一次原点
@MainActor
final class CoverSpace {
    let name = UUID()
    fileprivate(set) var origin: CGPoint = .zero
}

private struct CoverSpaceHost: ViewModifier {
    @State private var space = CoverSpace()

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(space.name))
            .environment(\.coverSpace, space)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                space.origin = origin
            }
    }
}

extension View {
    /// 标记一个会整体平移的页面（根 Tab 页）：里面的视频卡片按页面记位置
    func coverSpace() -> some View {
        modifier(CoverSpaceHost())
    }
}

extension EnvironmentValues {
    @Entry var coverSpace: CoverSpace? = nil
    /// 所在的根 Tab 页当前是否在用（选中，或正在滑出）。不在用时停掉呼吸光轨这类循环动画
    @Entry var pageActive = true
    /// 视频页里（舞台上）：点相关推荐原地换视频，不再从卡片展开
    @Entry var inStage = false
    @Entry var videoSource: VideoSource? = nil
    /// 舞台上的页面没有导航栈：要进别的页面时交给 RootView（先收进胶囊再推入）
    @Entry var openRoute: (@MainActor (Route) -> Void)? = nil
}

/// 打开视频：替代 NavigationLink(value: card)。封面从卡片里「浮起来」展开成视频页
struct VideoLink<Label: View>: View {
    let card: VideoCard
    /// false：不从这个按钮展开（比如「开始播放」小按钮），视频页原地淡入
    var morphs = true
    /// true：卡片的 cid 就是要播的那一 P（离线缓存列表），不被续播记录带去别的分 P
    var pinsPart = false
    var beforeOpen: (() -> Void)? = nil
    @ViewBuilder var label: Label
    @State private var source = VideoSource()
    @Environment(\.inStage) private var inStage
    @Environment(\.coverSpace) private var space

    var body: some View {
        let tracks = morphs && !inStage
        Button {
            beforeOpen?()
            VideoStage.shared.open(card, from: tracks ? source : nil, pinsPart: pinsPart)
        } label: {
            label
                .environment(\.videoSource, tracks ? source : nil)
                .opacity(tracks && !source.hasCover && VideoStage.shared.hiddenSource === source ? 0 : 1)
        }
        .onGeometryChange(for: CGRect.self) { [name = space?.name] proxy in
            name.map { proxy.frame(in: .named($0)) } ?? proxy.frame(in: .global)
        } action: { frame in
            if tracks, !source.hasCover { source.place(frame, in: space) }
        }
        .onAppear { source.isVisible = true }
        .onDisappear { source.isVisible = false }
    }
}

extension View {
    /// 标记卡片里的封面：视频页从这里展开、暂停时收回这里
    func videoCover(cornerRadius: CGFloat = 12) -> some View {
        modifier(VideoCover(radius: cornerRadius))
    }
}

private struct VideoCover: ViewModifier {
    let radius: CGFloat
    @Environment(\.videoSource) private var source
    @Environment(\.coverSpace) private var space

    func body(content: Content) -> some View {
        if let source {
            content
                .opacity(VideoStage.shared.hiddenSource === source ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { [name = space?.name] proxy in
                    name.map { proxy.frame(in: .named($0)) } ?? proxy.frame(in: .global)
                } action: { frame in
                    source.hasCover = true
                    source.place(frame, in: space)
                    source.radius = radius
                }
        } else {
            content
        }
    }
}

/// 进别的页面：导航栈里就是 NavigationLink；在舞台上（视频页里）交给 RootView
struct RouteLink<Label: View>: View {
    let route: Route
    @ViewBuilder var label: Label
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if let openRoute {
            Button { openRoute(route) } label: { label }
        } else {
            NavigationLink(value: route) { label }
        }
    }
}
