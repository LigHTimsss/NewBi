import SwiftUI

/// 临时的性能诊断开关（只在测试分支上，定位完低电量模式切到「我的」卡顿后删除）。
/// 第二轮：去掉卡片或去掉滚动视图都不卡 → 问题是「卡片放在滚动视图里」。这一轮再拆卡片，并试一个候选修复。
/// 每次只开一个，默认全关
enum Diagnostics {
    /// 不显示动态 / 关注 / 粉丝三项数据（数字滚动效果）
    static let mineNoStats = "diag.mineNoStats"
    /// 不显示四个入口（离线缓存、历史…）
    static let mineNoShortcuts = "diag.mineNoShortcuts"
    /// 不显示下面的「设置」行
    static let mineNoSettingsRow = "diag.mineNoSettingsRow"
    /// 「我的」里的按钮去掉按压缩放 / 提亮效果
    static let minePlainButtons = "diag.minePlainButtons"
    /// 候选修复：内容放得下一屏时不用滚动视图
    static let mineFitNoScroll = "diag.mineFitNoScroll"
}

extension View {
    /// 诊断：按开关用普通按钮样式代替按压效果
    @ViewBuilder
    func diagnosticPressable(plain: Bool) -> some View {
        if plain {
            buttonStyle(.plain)
        } else {
            buttonStyle(PressableStyle())
        }
    }
}
