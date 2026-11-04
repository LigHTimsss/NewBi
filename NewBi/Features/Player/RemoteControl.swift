import AVFoundation
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
    private var audioObservers: [NSObjectProtocol] = []
    /// 被来电 / 闹钟 / 其他 App 打断时正在播放：打断结束且系统允许续播时自动接着播
    private var resumeAfterInterruption = false

    private init() {
        observeAudioSession()
    }

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
        resumeAfterInterruption = false
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

    // MARK: 音频会话：打断与线路变化

    /// 系统引擎遇到打断 / 拔耳机会自己停，FFmpeg 引擎不会；两种都在这里统一暂停，
    /// 让界面、弹幕和锁屏状态跟着同步
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        audioObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let info = note.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    self?.interrupted(type, shouldResume: options.contains(.shouldResume))
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated {
                    // 拔耳机 / 断开蓝牙：不能改成外放继续出声
                    guard reason == .oldDeviceUnavailable, let self, let controller = self.controller else { return }
                    self.resumeAfterInterruption = false
                    controller.pause()
                    self.refresh(controller)
                }
            },
        ]
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard let controller else { return }
        switch type {
        case .began:
            resumeAfterInterruption = controller.isPlaying
            controller.pause()
        case .ended:
            if resumeAfterInterruption, shouldResume { controller.play() }
            resumeAfterInterruption = false
        default:
            return
        }
        refresh(controller)
    }

    // MARK: 远程命令

    /// 处理闭包标成 @Sendable：不继承主线程隔离，系统在哪个线程回调都不会触发隔离断言；
    /// 进了 perform 再按所在线程决定同步执行还是跳回主线程
    private func registerCommandsIfNeeded() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { @Sendable _ in Self.perform { $0.play() } }
        commands.pauseCommand.addTarget { @Sendable _ in Self.perform { $0.pause() } }
        commands.togglePlayPauseCommand.addTarget { @Sendable _ in Self.perform { $0.togglePlay() } }

        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { @Sendable _ in Self.perform { $0.seek(seconds: $0.currentTime + 10) } }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { @Sendable _ in Self.perform { $0.seek(seconds: $0.currentTime - 10) } }

        commands.changePlaybackPositionCommand.addTarget { @Sendable event in
            // 先取出数值，不把非 Sendable 的 event 带进主线程闭包
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return Self.perform { $0.seek(seconds: position) }
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        commands.changePlaybackRateCommand.addTarget { @Sendable event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            return Self.perform { $0.setRate(rate) }
        }

        // 多 P：上一首 / 下一首切分 P
        commands.nextTrackCommand.addTarget { @Sendable _ in Self.perform { $0.requestPart(offset: 1) } }
        commands.previousTrackCommand.addTarget { @Sendable _ in Self.perform { $0.requestPart(offset: -1) } }
    }

    /// 实际上系统在主线程回调，此时同步执行并如实返回状态；万一不在主线程，跳回主线程执行（不断言、不崩溃）
    private nonisolated static func perform(_ action: @escaping @MainActor @Sendable (PlayerController) -> Void) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            Task { @MainActor in _ = run(action) }
            return .success
        }
        return MainActor.assumeIsolated { run(action) }
    }

    private static func run(_ action: @MainActor (PlayerController) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let controller = shared.controller else { return .noActionableNowPlayingItem }
        action(controller)
        shared.refresh(controller)
        return .success
    }
}
