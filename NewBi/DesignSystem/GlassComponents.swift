import SwiftUI

// MARK: - 按压回弹：scale .95 + 提亮（动效规范「按压缩放」）

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(Motion.micro, value: configuration.isPressed)
    }
}

// MARK: - 选中光轨：胶囊 + 底部发光线（动效规范「选中光轨」）

struct GlowLine: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var pageActive

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 16, height: 2)
            .shadow(color: color, radius: 3)
            .shadow(color: color.opacity(0.6), radius: 7)
            // 呼吸 2.8s。循环动画会让主线程每帧都有活：所在的根 Tab 页不在用时停在常亮
            .phaseAnimator(reduceMotion || !pageActive ? [1.0] : [1.0, 0.55]) { line, opacity in
                line.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.4) }
    }
}

// MARK: - 液态选择器：底部 Tab 栏、各处分段控件共用
//
// 整条只有一个指示器（胶囊 + 发光线是同一个视图），位置由选中项直接算出来，
// 切换时胶囊和线一起走同一条弹簧曲线，不会一前一后。
// 按住后指示器浮起成玻璃透镜、跟手滑动，经过的项高亮并轻触反馈，松手即切到手指下那一项（系统 Tab 栏同款）；
// 轻点也走同一个手势：透镜跳到手指处再落回该项。

struct LiquidSelector<Item: View>: View {
    let count: Int
    let selected: Int
    var height: CGFloat
    /// 放在可滚动页面里时为 true：不独占触摸（页面照常上下滚动），竖向滑动不会误切
    var allowsScrolling = false
    /// 底栏按透镜实际覆盖范围着色；普通分段控件仍按整项高亮。
    var continuousHighlight = false
    var onSelect: (Int) -> Void
    @ViewBuilder var item: (_ index: Int, _ highlighted: Bool) -> Item

    /// 按住时手指的位置；用 GestureState，手势被页面滚动抢走时也会自动复位
    private struct Touch {
        var x: CGFloat?
        /// 已判定为竖向滚动：本次触摸不再浮起、松手不切换
        var cancelled = false
    }

    @GestureState private var touch = Touch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fingerX: CGFloat? { touch.cancelled ? nil : touch.x }
    private var pressing: Bool { fingerX != nil }

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(count, 1))
            let hover = fingerX.map { index(at: $0, slot: slot) } ?? selected
            // 按住时跟手（限制在两端之内），松开后回到选中项中心
            let center = fingerX.map { min(max($0, slot / 2), geo.size.width - slot / 2) } ?? (CGFloat(selected) + 0.5) * slot

            let lens = SelectorLensMotion(
                slot: slot, height: geo.size.height, center: center,
                pressing: pressing, lifted: pressing && !reduceMotion
            )

            ZStack(alignment: .topLeading) {
                SelectorIndicator(lifted: pressing && !reduceMotion)
                    .modifier(lens)

                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        item(index, continuousHighlight ? false : index == hover)
                            .frame(width: slot, height: geo.size.height)
                            .contentShape(.rect)
                            .animation(continuousHighlight ? nil : Motion.micro, value: hover)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { onSelect(index) }
                    }
                }

                if continuousHighlight {
                    // 同样的图标与文字叠一层强调色；只显露透镜覆盖的部分。
                    // 遮罩与玻璃共用位置、缩放和弹簧，拖动、点击、松手回弹都同步。
                    HStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { index in
                            item(index, true)
                                .frame(width: slot, height: geo.size.height)
                        }
                    }
                    .mask(alignment: .topLeading) {
                        Capsule().modifier(lens)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .modifier(SelectorGesture(allowsScrolling: allowsScrolling, gesture: drag(slot: slot)))
            .sensoryFeedback(.selection, trigger: hover) { _, _ in pressing }
        }
        .frame(height: height)
    }

    private func index(at x: CGFloat, slot: CGFloat) -> Int {
        min(max(Int(x / slot), 0), count - 1)
    }

    private func drag(slot: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touch) { value, state, _ in
                guard !state.cancelled else { return }
                if allowsScrolling, Self.isVerticalScroll(value) {
                    state.cancelled = true
                } else {
                    state.x = value.location.x
                }
            }
            .onEnded { value in
                // 松手时再按整段位移判断一次：竖向滚动过的不算点选
                guard !(allowsScrolling && Self.isVerticalScroll(value)) else { return }
                onSelect(index(at: value.location.x, slot: slot))
            }
    }

    /// 可滚动页面里明显的竖向滑动（交给页面滚动）
    private static func isVerticalScroll(_ value: DragGesture.Value) -> Bool {
        let dx = abs(value.translation.width), dy = abs(value.translation.height)
        return dy > 12 && dy > dx * 1.5
    }
}

/// 玻璃和着色遮罩使用同一套几何与动画参数，避免颜色领先或落后于透镜。
private struct SelectorLensMotion: ViewModifier {
    let slot: CGFloat
    let height: CGFloat
    let center: CGFloat
    let pressing: Bool
    let lifted: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: slot, height: height)
            .scaleEffect(x: lifted ? 1.08 : 1, y: lifted ? 1.16 : 1)
            .position(x: center, y: height / 2)
            .animation(pressing ? .interactiveSpring(response: 0.22, dampingFraction: 0.82) : Motion.component, value: center)
            .animation(Motion.component, value: pressing)
    }
}

/// 独占（Tab 栏）还是与页面滚动并存（分段控件）
private struct SelectorGesture<G: Gesture>: ViewModifier {
    let allowsScrolling: Bool
    let gesture: G

    func body(content: Content) -> some View {
        if allowsScrolling {
            content.simultaneousGesture(gesture)
        } else {
            content.gesture(gesture)
        }
    }
}

/// 指示器：平时是浅色胶囊 + 底部呼吸发光线；按住时浮起成放大的玻璃透镜
private struct SelectorIndicator: View {
    var lifted: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        Capsule()
            .fill(Theme.selection.opacity(lifted ? 0.4 : 1))
            .overlay(alignment: .bottom) { GlowLine(color: accent).padding(.bottom, 3) }
            .glassEffect(lifted ? .clear.interactive() : .identity, in: .capsule)
            .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - 底部主导航：玻璃胶囊（首页/动态/我的）+ 独立圆形搜索按钮

enum AppTab: Int, CaseIterable, Identifiable {
    case home, dynamic, mine
    var id: Self { self }

    var title: String {
        switch self {
        case .home: "首页"
        case .dynamic: "动态"
        case .mine: "我的"
        }
    }

    func icon(selected: Bool) -> String {
        switch self {
        case .home: selected ? "house.fill" : "house"
        case .dynamic: selected ? "safari.fill" : "safari"
        case .mine: selected ? "person.fill" : "person"
        }
    }
}

struct GlassTabBar: View {
    var selection: AppTab
    /// 搜索页从按钮放大展开（zoom 转场）
    /// 显示红点的 Tab（动态有更新）
    var badges: Set<AppTab> = []
    var onSelect: (AppTab) -> Void
    var onSearch: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                // 按住可左右滑动切换；高亮跟着手指走，松手才真正切页
                LiquidSelector(count: AppTab.allCases.count, selected: selection.rawValue, height: 52, continuousHighlight: true) { index in
                    if let tab = AppTab(rawValue: index) { onSelect(tab) }
                } item: { index, highlighted in
                    let tab = AppTab(rawValue: index) ?? .home
                    VStack(spacing: 2) {
                        // 两层轮廓一致，滑动时只改变覆盖处的颜色；松手选中后再切换填充图标。
                        Image(systemName: tab.icon(selected: tab == selection))
                            .font(.system(size: 20))
                            .frame(height: 24)
                            .contentTransition(.symbolEffect(.replace))
                            .overlay(alignment: .topTrailing) {
                                if badges.contains(tab) {
                                    Circle()
                                        .fill(accent)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 5, y: -1)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .animation(Motion.component, value: badges)
                        Text(tab.title)
                            .font(.system(size: 10, weight: tab == selection ? .semibold : .medium))
                    }
                    .foregroundStyle(highlighted ? accent.accentText(scheme) : .primary)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(badges.contains(tab) ? "有更新" : "")
                }
                .padding(5)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 62, height: 62)
                        .contentShape(.circle)
                }
                .buttonStyle(PressableStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("搜索")
            }
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - 玻璃分段控件（首页频道条、搜索结果分类）

struct GlassSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 分段控件多半在可滚动页面里：不独占触摸，竖向滑动照常滚动页面
        LiquidSelector(count: options.count, selected: options.firstIndex(of: selection) ?? 0, height: 34, allowsScrolling: true) { index in
            withAnimation(Motion.tab) { selection = options[index] }
        } item: { index, highlighted in
            Text(title(options[index]))
                .font(.system(size: 14, weight: highlighted ? .bold : .medium))
                .foregroundStyle(highlighted ? accent.accentText(scheme) : Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(height: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - 等级角标

struct LevelBadge: View {
    let level: Int
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 6 级用强调色，其余灰色，与 B 站习惯一致
        let color = level >= 6 ? accent.accentText(scheme) : Theme.secondaryText
        Text("LV\(level)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1) }
    }
}

// MARK: - 流式布局（搜索历史标签）

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, maxX, y + rowHeight)
    }
}

// MARK: - 提示条

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, bottomPadding)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Motion.component, value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                message = nil
            }
    }
}

extension View {
    func toast(_ message: Binding<String?>, bottomPadding: CGFloat = 90) -> some View {
        modifier(ToastModifier(message: message, bottomPadding: bottomPadding))
    }
}

/// 全局提示：卡片长按菜单这类没有自己页面的地方用它（RootView 负责显示）
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()
    var message: String?

    func show(_ text: String) {
        message = text
    }
}

extension View {
    /// 长按菜单「稍后再看」：首页、搜索、相关推荐、UP 主空间的视频卡片共用
    func watchLaterMenu(_ card: VideoCard) -> some View {
        modifier(OwnedVideoActions(card: card) {
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
                // clock.badge.plus 在当前系统上画不出来，菜单里只能放单个符号，用时钟
                Label("稍后再看", systemImage: "clock")
            }
            if !card.bvid.isEmpty {
                Button {
                    ShareCenter.shared.video(bvid: card.bvid, title: card.title)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
        })
    }
}

// MARK: - 圆形玻璃按钮（个人中心、消息、返回…）

struct GlassCircleButton: View {
    var systemImage: String
    var label: String
    var size: CGFloat = 40
    /// 视频上方用 .clear，更通透
    var glass: Glass = .regular
    /// 必填：不出现看得见却点了没反应的按钮
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .glassEffect(glass.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// 圆形玻璃头像按钮：登录后显示自己的头像（玻璃圈里嵌一张圆头像），未登录显示人形图标。
/// 头像加载完成时从图标交叉淡入，不闪白
struct GlassAvatarButton: View {
    var url: String?
    var label: String
    var size: CGFloat = 40
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack {
                if let url, !url.isEmpty {
                    RemoteImage(url: url, size: CGSize(width: size, height: size), background: .clear)
                        .clipShape(.circle)
                        .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                        .padding(3)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Image(systemName: "person")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            .contentShape(.circle)
            .animation(Motion.component, value: url)
        }
        .buttonStyle(PressableStyle())
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// 红色未读数气泡（0 不显示，超过 99 显示 99+）
struct UnreadBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 4 : 0)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.red, in: .capsule)
                .overlay { Capsule().strokeBorder(Theme.background, lineWidth: 1.5) }
                .contentTransition(.numericText())
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 入场：模糊 + 上移（动效规范「模糊入场」）

private struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(enabled: Bool, delay: Double) {
        self.delay = delay
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            // 只用透明度 + 位移（不用模糊：每张卡片一次离屏模糊，首屏 8 张同时做会掉帧）
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.entrance.delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// 只给首屏前 8 个元素做模糊入场：blur 是 GPU 大户，滚动加载的内容直接显示
    func riseIn(index: Int) -> some View {
        modifier(RiseIn(enabled: index < 8, delay: Double(index) * Motion.stagger))
    }
}
