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

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 16, height: 2)
            .shadow(color: color, radius: 3)
            .shadow(color: color.opacity(0.6), radius: 7)
            // 呼吸 2.8s；只作用于这一根 2pt 线，开销可忽略
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.55]) { line, opacity in
                line.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.4) }
    }
}

struct SelectionPill: View {
    var id: String
    var namespace: Namespace.ID
    @Environment(\.accent) private var accent

    var body: some View {
        Capsule()
            .fill(Theme.selection)
            .overlay(alignment: .bottom) { GlowLine(color: accent).padding(.bottom, 3) }
            .matchedGeometryEffect(id: id, in: namespace)
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
    var searchTransition: Namespace.ID
    /// 显示红点的 Tab（动态有更新）
    var badges: Set<AppTab> = []
    var onSelect: (AppTab) -> Void
    var onSearch: () -> Void
    @Namespace private var ns
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(AppTab.allCases) { tab in
                        let on = tab == selection
                        Button { onSelect(tab) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: tab.icon(selected: on))
                                    .font(.system(size: 20))
                                    .frame(height: 24)
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
                                    .font(.system(size: 10, weight: on ? .semibold : .medium))
                            }
                            .foregroundStyle(on ? accent.accentText(scheme) : .primary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background { if on { SelectionPill(id: "tab", namespace: ns) } }
                            .contentShape(.capsule)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityValue(badges.contains(tab) ? "有更新" : "")
                    }
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
                .matchedTransitionSource(id: "search", in: searchTransition)
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
    @Namespace private var ns
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { item in
                let on = item == selection
                Button {
                    withAnimation(Motion.tab) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 14, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background { if on { SelectionPill(id: "segment", namespace: ns) } }
                        .contentShape(.capsule)
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
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
        contextMenu {
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
            if !card.bvid.isEmpty, let url = URL(string: "https://www.bilibili.com/video/\(card.bvid)") {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

// MARK: - 圆形玻璃按钮（个人中心、消息、返回…）

struct GlassCircleButton: View {
    var systemImage: String
    var label: String
    var size: CGFloat = 40
    /// 视频上方用 .clear，更通透
    var glass: Glass = .regular
    var action: () -> Void = {}

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
            .offset(y: shown || reduceMotion ? 0 : 14)
            .blur(radius: shown || reduceMotion ? 0 : 8)
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
