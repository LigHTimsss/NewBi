#if canImport(KSPlayer)
import KSPlayer
import UIKit

/// FFmpeg 兜底引擎（KSPlayer 的 KSMEPlayer）。
/// - 解码仍优先走 VideoToolbox 硬解，FFmpeg 负责封装解析，所以 hev1 标记、少见封装、FLAC 等都能播
/// - 和系统引擎吃同一个本地 HLS 地址（http://127.0.0.1/...），选流、代理、Referer 逻辑完全复用
/// - 暂不支持系统画中画；AirPlay 仅音频
///
/// 注：固定 KSPlayer 2.3.4（最后的开源版）。5.x 起闭源且不含 iOS 真机切片，不要升级。
@MainActor
final class FFmpegEngine: NSObject, PlaybackEngine {
    let kind: EngineKind = .ffmpeg
    var onEvent: ((EngineEvent) -> Void)?

    private let container = UIView()
    private var player: KSMEPlayer?
    private var rate: Float = 1
    private var fill = false

    override init() {
        super.init()
        container.backgroundColor = .black
    }

    var view: UIView { container }
    var currentTime: Double { player?.currentPlaybackTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }
    var bufferedTime: Double { player?.playableTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    var volume: Float {
        get { player?.playbackVolume ?? 1 }
        set { player?.playbackVolume = newValue }
    }

    func load(url: URL, headers: [String: String]?, startAt: Double?) {
        teardown()
        let options = KSOptions()
        if let headers { options.appendHeader(headers) }
        options.hardwareDecode = true // VideoToolbox 硬解
        options.startPlayTime = startAt ?? 0
        let player = KSMEPlayer(url: url, options: options)
        player.delegate = self
        player.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        if let video = player.view {
            video.frame = container.bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(video)
        }
        self.player = player
        player.prepareToPlay()
    }

    func play() {
        player?.play()
        player?.playbackRate = rate
    }

    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        player?.seek(time: seconds) { _ in }
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player?.playbackRate = rate
    }

    func setFill(_ fill: Bool) {
        self.fill = fill
        player?.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
    }

    func teardown() {
        player?.shutdown()
        player?.view?.removeFromSuperview()
        player = nil
    }
}

// KSPlayer 2.3.4 的 MediaPlayerDelegate（@MainActor）
extension FFmpegEngine: MediaPlayerDelegate {
    func readyToPlay(player: some MediaPlayerProtocol) {
        onEvent?(.ready)
    }

    func changeLoadState(player: some MediaPlayerProtocol) {}

    /// 缓冲进度 0–100；进度条由 PlayerController 的 4 Hz 时钟读取，这里不用
    func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

    func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

    func finish(player: some MediaPlayerProtocol, error: Error?) {
        onEvent?(error == nil ? .ended : .failed(error))
    }
}
#endif
