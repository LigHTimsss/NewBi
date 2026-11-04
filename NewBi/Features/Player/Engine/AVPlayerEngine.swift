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
    private var endObserver: NSObjectProtocol?
    private var fill = false

    init() {
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
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
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in
                switch status {
                case .readyToPlay: self?.onEvent?(.ready)
                case .failed: self?.onEvent?(.failed(error))
                default: break
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.ended) }
        }
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
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
