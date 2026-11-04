import MediaPlayer
import UIKit

/// 锁屏 / 控制中心 / 灵动岛的「正在播放」与远程控制（耳机线控、AirPods 双击、车机等）。
/// 只服务最近一个开始播放的播放器；系统按 elapsed + rate 自己推算进度，所以只在
/// 播放 / 暂停 / 拖动 / 倍速 / 时长变化时更新，不跟 4 Hz 时钟走。
@MainActor
final class RemoteControl {
    static let shared = RemoteControl()

    struct Metadata {
        var title: String
        var artist: String
        /// 封面原始地址（B 站图床），取图时按 600 宽服务端缩放
        var cover: String
    }

    private weak var controller: PlayerController?
    /// deinit 时弱引用已经是 nil，靠 id 判断是不是当前服务的播放器
    private var controllerID: ObjectIdentifier?
    private var metadata: Metadata?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var commandsRegistered = false

    /// 播放器拿到详情后调用；之后由它在状态变化时调 `refresh`
    func activate(_ controller: PlayerController, metadata: Metadata) {
        if self.controller !== controller || self.metadata?.cover != metadata.cover {
            artwork = nil
            loadArtwork(metadata.cover)
        }
        self.controller = controller
        controllerID = ObjectIdentifier(controller)
        self.metadata = metadata
        registerCommandsIfNeeded()
        refresh(controller)
    }

    func refresh(_ controller: PlayerController) {
        guard controller === self.controller, let metadata else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: metadata.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: controller.isPlaying ? Double(controller.effectiveRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if controller.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = controller.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = controller.isPlaying ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = controller.hasNextPart
        commands.previousTrackCommand.isEnabled = controller.hasPreviousPart
    }

    /// 播放器释放时调用；只有当前服务的那个才会清空
    func deactivate(_ id: ObjectIdentifier) {
        guard controllerID == id else { return }
        clear()
    }

    private func clear() {
        controller = nil
        controllerID = nil
        metadata = nil
        artwork = nil
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(_ cover: String) {
        artworkTask?.cancel()
        guard let url = cover.biliResized(width: 600) else { return }
        artworkTask = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, maxPixel: 600), !Task.isCancelled else { return }
            guard let self else { return }
            artwork = Self.makeArtwork(image)
            if let controller { refresh(controller) }
        }
    }

    /// 系统会在任意线程回调 requestHandler，闭包不能带主线程隔离，所以放在 nonisolated 里创建
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: 远程命令（系统在主线程回调）

    private func registerCommandsIfNeeded() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { _ in Self.perform { $0.play() } }
        commands.pauseCommand.addTarget { _ in Self.perform { $0.pause() } }
        commands.togglePlayPauseCommand.addTarget { _ in Self.perform { $0.togglePlay() } }

        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { _ in Self.perform { $0.seek(seconds: $0.currentTime + 10) } }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { _ in Self.perform { $0.seek(seconds: $0.currentTime - 10) } }

        commands.changePlaybackPositionCommand.addTarget { event in
            // 先取出数值，不把非 Sendable 的 event 带进主线程闭包
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return Self.perform { $0.seek(seconds: position) }
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        commands.changePlaybackRateCommand.addTarget { event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            return Self.perform { $0.setRate(rate) }
        }

        // 多 P：上一首 / 下一首切分 P
        commands.nextTrackCommand.addTarget { _ in Self.perform { $0.requestPart(offset: 1) } }
        commands.previousTrackCommand.addTarget { _ in Self.perform { $0.requestPart(offset: -1) } }
    }

    private nonisolated static func perform(_ action: @MainActor (PlayerController) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let controller = RemoteControl.shared.controller else { return .noActionableNowPlayingItem }
            action(controller)
            RemoteControl.shared.refresh(controller)
            return .success
        }
    }
}
