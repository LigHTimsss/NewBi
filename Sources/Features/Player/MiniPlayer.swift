import SwiftUI

/// 迷你胶囊里的内容：标题 / 进度 + 播放暂停、快进 10 秒、关闭；底部一条强调色进度线。
/// 外形（玻璃）、小画面都由舞台画（VideoStage）：展开时胶囊本身变成视频页，画面从左边的小窗移到页面顶部。
/// 这里只留出小画面的位置。点它展开；上滑跟手展开，左右滑关闭
struct MiniControls: View {
    let model: VideoDetailModel
    @Environment(\.accent) private var accent

    private var player: PlayerController { model.player }

    var body: some View {
        HStack(spacing: 10) {
            Button { VideoStage.shared.expand() } label: {
                HStack(spacing: 10) {
                    // 小画面由舞台画在这里（同一个播放器视图）
                    Color.clear.frame(width: 64, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.detail?.title ?? model.offline?.title ?? model.card.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        MiniTime(player: player)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到视频：\(model.card.title)")

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button { player.seek(seconds: player.currentTime + 10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("前进 10 秒")

            Button { VideoStage.shared.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("关闭小窗")
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { MiniProgress(player: player, color: accent) }
        .contentShape(.capsule)
        // 与按钮并存：上滑展开（跟手），左右滑关闭
        .simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { VideoStage.shared.miniDragChanged($0.translation) }
                .onEnded { VideoStage.shared.miniDragEnded($0.translation, velocity: $0.velocity) }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "关闭小窗") { VideoStage.shared.close() }
        .accessibilityAction(named: "展开") { VideoStage.shared.expand() }
    }
}

extension View {
    /// 有迷你胶囊时，页面底部让出它的高度（滚动内容不会被挡住）
    func miniPlayerInset(_ height: CGFloat = 68) -> some View {
        safeAreaPadding(.bottom, VideoStage.shared.showsMini ? height : 0)
    }
}

/// 单独的子视图读取进度，4 Hz 刷新不带动整条重算
private struct MiniTime: View {
    let player: PlayerController

    var body: some View {
        Text("\(Int(player.currentTime).durationText) / \(Int(player.duration).durationText)")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
            .contentTransition(.numericText())
    }
}

private struct MiniProgress: View {
    let player: PlayerController
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let fraction: CGFloat = player.duration > 0 ? CGFloat(min(player.currentTime / player.duration, 1)) : 0
            Capsule()
                .fill(color)
                .frame(width: geo.size.width * fraction, height: 2)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
        .frame(height: 2)
        .padding(.horizontal, 22)
        .allowsHitTesting(false)
    }
}
