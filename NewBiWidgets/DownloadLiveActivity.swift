import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NewBiWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

private let pink = Color(red: 0xFB / 255, green: 0x72 / 255, blue: 0x99 / 255)

/// 离线缓存进度：锁屏横幅 + 灵动岛（紧凑 / 最小 / 展开）
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(pink)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.finished ? "完成" : "\(Int(state.progress * 100))%")
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        ProgressView(value: state.progress).tint(pink)
                        Text(state.finished ? "全部缓存完成" : "还有 \(state.remaining) 个视频")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(pink)
            } compactTrailing: {
                Text(state.finished ? "完成" : "\(Int(state.progress * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(pink)
            } minimal: {
                Gauge(value: state.progress) {
                    Image(systemName: "arrow.down")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(pink)
            }
            .keylineTint(pink)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(pink)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                }
                ProgressView(value: state.progress).tint(pink)
                Text(state.finished ? "全部缓存完成，没网也能看" : "离线缓存中 · 还有 \(state.remaining) 个")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
