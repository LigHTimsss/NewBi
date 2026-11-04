import SwiftUI

/// 设计令牌，对应设计稿「视频 App · Liquid Glass UI」中的 CSS 变量
enum Theme {
    static let pink = Color(hex: 0xFB7299)
    /// 设计稿提供的四个强调色选项
    static let accents: [Color] = [pink, Color(hex: 0x00AEEC), Color(hex: 0x0A84FF), Color(hex: 0xFF9F0A)]

    static let background = Color.dynamic(light: .white, dark: .black)
    /// --fg2
    static let secondaryText = Color.dynamic(
        light: UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.78),
        dark: UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.62)
    )
    /// --sel：选中胶囊底色
    static let selection = Color.dynamic(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.16))
    /// --sep
    static let separator = Color.dynamic(
        light: UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.14),
        dark: UIColor(white: 1, alpha: 0.12)
    )
    /// --card：分组卡片
    static let card = Color.dynamic(
        light: UIColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1),
        dark: UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    )
}

/// 动效令牌，对应「动效规范」画板
enum Motion {
    /// 微交互 180ms (.2, .8, .2, 1)
    static let micro = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)
    /// 组件切换 spring response .32 · damping .86
    static let component = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Tab / 频道切换：左右平移 420ms (.32, .72, 0, 1)
    static let tab = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
    /// 入场：blur 8 → 0、y 14 → 0，间隔 50ms
    static let entrance = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.56)
    static let stagger = 0.05
    /// 视频页从卡片封面展开
    static let stageOpen = Animation.spring(response: 0.46, dampingFraction: 0.88)
    /// 从迷你胶囊展开（距离更长，稍慢一点）
    static let stageExpand = Animation.spring(response: 0.5, dampingFraction: 0.87)
    /// 收进胶囊 / 收回卡片
    static let stageClose = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

extension EnvironmentValues {
    @Entry var accent: Color = Theme.pink
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// --act：文字用强调色，浅色模式压暗 28% 保证 4.5:1 对比度
    func accentText(_ scheme: ColorScheme) -> Color {
        scheme == .light ? mix(with: .black, by: 0.28) : self
    }

    /// --acf：实心按钮底色（关注、发布、会员角标）
    var accentFill: Color { mix(with: .black, by: 0.28) }
}

extension Font {
    /// 设计稿标题用宋体（Songti SC）。iOS 未预装，见 DESIGN.md §7.3；暂以系统 serif 兜底
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension Int {
    /// 12.6万 / 3.2亿
    var biliCount: String {
        let text: String
        switch self {
        case 100_000_000...: text = String(format: "%.1f亿", Double(self) / 1e8)
        case 10_000...: text = String(format: "%.1f万", Double(self) / 1e4)
        default: return "\(self)"
        }
        return text.replacingOccurrences(of: ".0", with: "")
    }

    /// 秒 → 12:08 / 1:02:33
    var durationText: String {
        let h = self / 3600, m = (self % 3600) / 60, s = self % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
