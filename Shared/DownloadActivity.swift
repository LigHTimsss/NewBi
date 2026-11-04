import ActivityKit
import Foundation

/// 离线缓存的实况活动（灵动岛 / 锁屏）。App 与小组件扩展共用此文件
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 当前正在缓存的视频标题
        var title: String
        /// 全部任务的总进度 0...1
        var progress: Double
        /// 还剩几个没完成
        var remaining: Int
        var finished: Bool
    }
}
