import SwiftUI

/// 全局「正在播放」：从视频页返回时，播放不中断，缩成底栏上方的迷你播放条；
/// 点迷你条回到视频页时复用同一个播放器（不重新取流、不黑屏、进度不丢）
@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    /// 缩小中的视频；nil 表示没有迷你条
    private(set) var minimized: VideoDetailModel?
    /// 最近一次导航路径变化：是出栈（返回）还是入栈（进了别的页面），以及时间
    @ObservationIgnored private var lastPathChange: (popped: Bool, at: Date)?
    /// 刚消失、还没决定是缩小还是暂停的视频页
    @ObservationIgnored private var pending: (model: VideoDetailModel, at: Date)?
    /// 「路径变化」和「视频页消失」相隔多久以内算同一次。两者在真机上的先后和间隔都不固定：
    /// 路径在转场开始时就变，视频页要等转场动画走完才消失，缩放转场（收回卡片 / 收进胶囊）
    /// 比普通推入推出长不少，0.8 秒会配不上、被当成「进了别的页面」而暂停。所以两边谁先到都记下，在这个窗口里配对
    private static let pairWindow: TimeInterval = 1.5

    /// RootView 在导航路径深度变化时调用
    func pathChanged(from old: Int, to new: Int) {
        guard new != old else { return }
        lastPathChange = (new < old, .now)
        // 视频页先消失、路径后变（侧滑返回时可能这样）：在这里补上缩小
        if new < old, let pending, Date.now.timeIntervalSince(pending.at) < Self.pairWindow {
            self.pending = nil
            minimize(pending.model)
        }
    }

    /// 视频页消失时调用：刚出栈就缩小；刚入栈（进了相关推荐、UP 主空间等）就暂停；
    /// 都没有（路径还没变，或连播换了视频）先记下，等出栈来配，配不上再暂停
    func detailDisappeared(_ model: VideoDetailModel) {
        if let change = lastPathChange, Date.now.timeIntervalSince(change.at) < Self.pairWindow {
            lastPathChange = nil
            if change.popped {
                minimize(model)
            } else {
                model.player.pause()
                Task { await model.reportProgress() }
            }
            return
        }
        pending = (model, .now)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.pairWindow))
            // 期间被配上（已缩小）或页面又回来了（pending 被清掉）就什么都不做
            guard let pending, pending.model === model else { return }
            self.pending = nil
            model.player.pause()
            await model.reportProgress()
        }
    }

    /// 视频页又出现了（从上层页面返回）：取消待定的暂停
    func detailAppeared(_ model: VideoDetailModel) {
        if pending?.model === model { pending = nil }
    }

    private func minimize(_ model: VideoDetailModel) {
        let enabled = UserDefaults.standard.object(forKey: "miniPlayer") as? Bool ?? true
        guard enabled, model.player.isPlaying else {
            model.player.pause()
            Task { await model.reportProgress() }
            return
        }
        if let current = minimized, current !== model { close() }
        model.player.isMinimized = true
        withAnimation(Motion.component) { minimized = model }
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
                    // 直接显示正在播放的画面（同一个播放器图层，不额外解码）；
                    // 这是 UIKit 视图，必须关掉它的触摸，否则会吞掉「回到视频」按钮的点击
                    PlayerSurface(controller: player, showsDanmaku: false, interactive: false)
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

            Button { NowPlaying.shared.close() } label: {
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
        .frame(height: 56)
        .overlay(alignment: .bottom) { MiniProgress(player: player, color: accent) }
        // 玻璃画在背景里、不做 interactive：整条上的 interactive 玻璃会和里面的按钮抢触摸
        .background { Capsule().fill(.clear).glassEffect(.regular, in: .capsule) }
        .contentShape(.capsule)
        .offset(x: dragX)
        .opacity(1 - min(abs(dragX) / 240, 0.6))
        // 左右滑动关闭：与按钮并存，只认横向
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    if abs(dragX) > 120 {
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
