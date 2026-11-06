import AVFoundation
import AVKit
import UIKit

/// 系统播放器：VideoToolbox 硬解、系统画中画、AirPlay、HDR / 杜比视界显示
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind: EngineKind = .system
    let player = AVPlayer()
    var onEvent: ((EngineEvent) -> Void)?

    private let videoView = VideoLayerView()
    private var pip: AVPictureInPictureController?
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var fill = false

    /// 设置「退到后台时自动画中画」（默认开）
    nonisolated static let autoPictureInPictureKey = "autoPictureInPicture"

    init() {
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pip?.delegate = videoView
            applyAutoPictureInPicture()
            // 播放中在设置里改了开关：立即生效，不用重开视频
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAutoPictureInPicture() }
            }
        }
        // 第一帧可显示：图层换了播放项后会先变回 false，新一项出帧后再变 true
        // KVO 可能在任意线程回调：回到主线程后按图层「此刻」的状态判断（届时若已换了新一项，它会是 false）
        displayObservation = videoView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil, self.videoView.playerLayer.isReadyForDisplay else { return }
                self.onEvent?(.firstFrame)
            }
        }
    }

    var view: UIView { videoView }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    var bufferedTime: Double {
        let now = currentTime
        return player.currentItem?.loadedTimeRanges.map(\.timeRangeValue)
            .filter { $0.start.seconds <= now + 1 }
            .map(\.end.seconds)
            .max() ?? now
    }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var supportsPictureInPicture: Bool { pip != nil }
    var isPictureInPictureActive: Bool { pip?.isPictureInPictureActive ?? false }

    func load(url: URL, headers: [String: String]?, startAt: Double?) {
        let asset = headers.map { AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": $0]) } ?? AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 20 // 限制预缓冲，控制内存
        removeItemObservers()
        // 回调跳回主线程时可能已经换了播放项：只认仍是当前项的事件（按对象身份比较，不跨线程传递播放项本身）
        let itemID = ObjectIdentifier(item)
        statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in
                guard let self, self.isCurrent(itemID) else { return }
                switch status {
                case .readyToPlay: self.onEvent?(.ready)
                case .failed: self.onEvent?(.failed(error))
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(itemID) else { return }
                    self.onEvent?(.ended)
                }
            },
            // 播放中途失败（网络中断、分段 5xx）有时只发这个通知、status 不变，也要进入恢复链
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(itemID) else { return }
                    self.onEvent?(.failed(error))
                }
            },
        ]
        player.replaceCurrentItem(with: item)
        if let startAt, startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
    }

    func setRate(_ rate: Float) {
        player.defaultRate = rate // play() 之后沿用
        if isPlaying { player.rate = rate }
    }

    func setFill(_ fill: Bool) {
        self.fill = fill
        videoView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func togglePictureInPicture() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    func teardown() {
        pip?.delegate = nil
        removeItemObservers()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// 播放中回到主屏幕时是否自动缩成画中画（关掉后按「后台播放」决定是只出声还是暂停）
    private func applyAutoPictureInPicture() {
        guard let pip else { return }
        let enabled = UserDefaults.standard.object(forKey: Self.autoPictureInPictureKey) as? Bool ?? true
        if pip.canStartPictureInPictureAutomaticallyFromInline != enabled {
            pip.canStartPictureInPictureAutomaticallyFromInline = enabled
        }
    }

    private func isCurrent(_ itemID: ObjectIdentifier) -> Bool {
        player.currentItem.map(ObjectIdentifier.init) == itemID
    }

    private func removeItemObservers() {
        statusObservation = nil
        for observer in itemObservers { NotificationCenter.default.removeObserver(observer) }
        itemObservers = []
    }
}

final class VideoLayerView: UIView, AVPictureInPictureControllerDelegate {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let window = self?.window, let scene = window.windowScene else {
                completionHandler(false)
                return
            }
            // 舞台保留了原来的播放界面；若场景仍在切换，激活时会再次应用方向。
            Orientation.restore(in: scene)
            window.layoutIfNeeded()
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            if let scene = self?.window?.windowScene { Orientation.restore(in: scene) }
        }
    }
}
