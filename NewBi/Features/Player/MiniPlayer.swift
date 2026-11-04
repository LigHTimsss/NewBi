import SwiftUI

/// 全局「正在播放」：从视频页返回时，播放不中断，缩成底栏上方的迷你播放条；
/// 点迷你条回到视频页时复用同一个播放器（不重新取流、不黑屏、进度不丢）
@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    /// 缩小中的视频；nil 表示没有迷你条
    private(set) var minimized: VideoDetailModel?
    /// 最近一次导航是不是出栈：视频页消失时据此区分「返回」（缩小）和「又打开了别的页」（暂停）
    @ObservationIgnored private var lastWasPop = false

    /// RootView 在导航路径深度变化时调用
    func pathChanged(from old: Int, to new: Int) {
        lastWasPop = new < old
    }

    /// 视频页消失时调用。onDisappear 与路径 onChange 的先后不固定，让出一拍再判断
    func detailDisappeared(_ model: VideoDetailModel) {
        Task { @MainActor in
            await Task.yield()
            let enabled = UserDefaults.standard.object(forKey: "miniPlayer") as? Bool ?? true
            guard lastWasPop, enabled, model.player.isPlaying else {
                model.player.pause()
                await model.reportProgress()
                return
            }
            if let current = minimized, current !== model { close() }
            model.player.isMinimized = true
            withAnimation(Motion.component) { minimized = model }
        }
    }

    /// 进入后台：上报进度；关闭了后台播放时暂停（画中画中除外）
    func enteredBackground() {
        guard let model = minimized else { return }
        Task { await model.reportProgress() }
        let backgroundPlay = UserDefaults.standard.object(forKey: "backgroundPlay") as? Bool ?? true
        if !backgroundPlay, !model.player.isPictureInPictureActive { model.player.pause() }
    }

    /// 视频页出现：同一个视频就把迷你条里的播放器拿回去；换了视频则关掉迷你条
    func claim(for card: VideoCard) -> VideoDetailModel? {
        guard let model = minimized else { return nil }
        if model.card.bvid == card.bvid {
            model.player.isMinimized = false
            withAnimation(Motion.component) { minimized = nil }
            return model
        }
        close()
        return nil
    }

    func close() {
        guard let model = minimized else { return }
        model.player.pause()
        Task { await model.reportProgress() }
        withAnimation(Motion.component) { minimized = nil } // 释放后播放器在 deinit 中清理
    }
}

/// 迷你播放条：实时小画面 + 标题 / 进度 + 播放暂停、快进 10 秒、关闭；底部一条强调色进度线
struct MiniPlayerBar: View {
    let model: VideoDetailModel
    var onOpen: () -> Void
    @State private var dragX: CGFloat = 0
    @Environment(\.accent) private var accent

    private var player: PlayerController { model.player }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    // 直接显示正在播放的画面（同一个播放器图层，不额外解码）
                    PlayerSurface(controller: player, showsDanmaku: false)
                        .frame(width: 64, height: 36)
                        .clipShape(.rect(cornerRadius: 8))
                        .allowsHitTesting(false)
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
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button { player.seek(seconds: player.currentTime + 10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("前进 10 秒")

            Button { NowPlaying.shared.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 44)
            }
            .accessibilityLabel("关闭小窗")
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 56)
        .overlay(alignment: .bottom) { MiniProgress(player: player, color: accent) }
        .glassEffect(.regular.interactive(), in: .capsule)
        .offset(x: dragX)
        .opacity(1 - min(abs(dragX) / 240, 0.6))
        // 左右滑动关闭
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 120 {
                        NowPlaying.shared.close()
                    }
                    withAnimation(Motion.component) { dragX = 0 }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .padding(.horizontal, 18)
        .accessibilityAction(named: "关闭小窗") { NowPlaying.shared.close() }
    }
}

extension View {
    /// 有迷你播放条时，页面底部让出它的高度（滚动内容不会被挡住）
    func miniPlayerInset(_ height: CGFloat = 68) -> some View {
        safeAreaPadding(.bottom, NowPlaying.shared.minimized == nil ? 0 : height)
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
            let fraction = player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0
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
