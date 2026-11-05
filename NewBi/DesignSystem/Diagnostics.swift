import Foundation

/// 临时的性能诊断开关（只在测试分支上，定位完低电量模式切到「我的」卡顿后删除）。
/// 上一轮：「我的」换成空白页就不卡，所以这一轮把「我的」拆开逐块去掉。每次只开一个，默认全关
enum Diagnostics {
    /// 不显示头部（头像、昵称、等级、硬币）
    static let mineNoHeader = "diag.mineNoHeader"
    /// 不显示数据、入口卡片和「设置」行
    static let mineNoCards = "diag.mineNoCards"
    /// 不用 ScrollView，内容直接排在页面上
    static let mineNoScroll = "diag.mineNoScroll"
    /// 不显示右上角工具条（整个去掉，不只是玻璃）
    static let mineNoToolbar = "diag.mineNoToolbar"
}
