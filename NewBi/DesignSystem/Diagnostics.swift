import SwiftUI

/// 临时的性能诊断开关（只在测试分支上，定位完低电量模式切到「我的」卡顿后删除）。
/// 每次只开一个，对比切页是否还卡；默认全关，不影响外观
enum Diagnostics {
    /// 「我的」右上角工具条不用玻璃
    static let mineNoGlass = "diag.mineNoGlass"
    /// 「我的」换成空白页
    static let mineBlank = "diag.mineBlank"
    /// 底栏（Tab 胶囊 + 搜索按钮）不用玻璃
    static let tabBarNoGlass = "diag.tabBarNoGlass"
    /// 动态页不是当前页时不画（含切页途中滑过 / 滑出）
    static let hideDynamic = "diag.hideDynamic"
}

/// 玻璃或普通半透明底：诊断开关打开时用后者，便于对比玻璃的渲染开销
struct DiagnosticGlass<S: Shape>: ViewModifier {
    let shape: S
    @AppStorage private var plain: Bool

    init(_ key: String, shape: S) {
        self.shape = shape
        _plain = AppStorage(wrappedValue: false, key)
    }

    func body(content: Content) -> some View {
        if plain {
            content.background(Theme.selection, in: shape)
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

extension View {
    func diagnosticGlass(_ key: String, in shape: some Shape) -> some View {
        modifier(DiagnosticGlass(key, shape: shape))
    }
}

/// 「我的」空白页：只留一个关掉它的按钮（否则进不了设置）
struct DiagnosticBlankPage: View {
    @AppStorage(Diagnostics.mineBlank) private var blank = false

    var body: some View {
        Button("关闭诊断空白页") { blank = false }
            .font(.system(size: 15))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
