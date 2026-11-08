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

// MARK: - 原生主题色分段控件

struct NativeSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NativeSegments(options: options, selection: $selection, titles: options.map(title),
            color: UIColor(accent), textColor: UIColor(accent.accentText(scheme)))
            .frame(height: 40)
    }
}

private struct NativeSegments<Value: Hashable>: UIViewRepresentable {
    let options: [Value]
    @Binding var selection: Value
    let titles: [String]
    let color: UIColor
    let textColor: UIColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.numberOfSegments != titles.count {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() { control.insertSegment(withTitle: title, at: index, animated: false) }
        } else {
            for (index, title) in titles.enumerated() where control.titleForSegment(at: index) != title {
                control.setTitle(title, forSegmentAt: index)
            }
        }
        let selected = options.firstIndex(of: selection) ?? UISegmentedControl.noSegment
        if control.selectedSegmentIndex != selected { control.selectedSegmentIndex = selected }
        // 使用系统着色 API，不覆盖控件背景、不绘制额外选择器或遮罩。
        control.selectedSegmentTintColor = color.withAlphaComponent(0.22)
        control.setTitleTextAttributes([.foregroundColor: textColor], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
        control.tintColor = color
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeSegments
        init(_ parent: NativeSegments) { self.parent = parent }
        @objc func changed(_ sender: UISegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegmentIndex) else { return }
            let value = parent.options[sender.selectedSegmentIndex]
            guard value != parent.selection else { return }
            withAnimation(Motion.tab) { parent.selection = value }
        }
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
