import ActivityKit
import Foundation

/// 离线缓存的实况活动（灵动岛 / 锁屏）。App 与小组件扩展共用此文件
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 活动结束时的结果。只有 completed 才显示「完成」
        enum Outcome: String, Codable, Hashable {
            case completed, paused, failed, cancelled
        }

        /// 当前正在缓存的视频标题
        var title: String
        /// 全部任务的总进度 0...1
        var progress: Double
        /// 还剩几个没完成（结束时为暂停 / 失败的个数）
        var remaining: Int
        var finished: Bool
        /// nil 表示还在下载
        var outcome: Outcome? = nil
    }
}

extension DownloadActivityAttributes.ContentState {
    var icon: String {
        switch outcome {
        case nil: "arrow.down.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    /// 灵动岛右侧的短文字
    var badge: String {
        switch outcome {
        case nil: "\(Int(progress * 100))%"
        case .completed: "完成"
        case .paused: "已暂停"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    /// 进度条下方的说明
    var caption: String {
        switch outcome {
        case nil: "还有 \(remaining) 个视频"
        case .completed: "全部缓存完成，没网也能看"
        case .paused: "\(remaining) 个视频已暂停"
        case .failed: "\(remaining) 个视频缓存失败，打开 App 重试"
        case .cancelled: "缓存已取消"
        }
    }
}
