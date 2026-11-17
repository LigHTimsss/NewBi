import UIKit

/// 双引擎：系统 AVPlayer 为主（硬解、省电、画中画、HDR），FFmpeg 兜底（格式兼容性最好）。
/// 界面、弹幕、手势只依赖 PlayerController，不关心底下是哪个引擎。
enum EngineKind: String, Sendable {
    case system = "AVPlayer"
    case ffmpeg = "FFmpeg"
}

/// 引擎只上报「当前这一项」的事件：被替换掉的旧播放项的回调在引擎里就丢掉
enum EngineEvent {
    /// 媒体可以播放（时长等信息已知）
    case ready
    /// 第一帧画面已经可以显示（系统引擎：AVPlayerLayer.isReadyForDisplay）
    case firstFrame
    case failed(Error?)
    case ended
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    /// 视频画面，由 PlayerHostView 放在弹幕图层下面
    var view: UIView { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var bufferedTime: Double { get }
    var isPlaying: Bool { get }
    var volume: Float { get set }
    var onEvent: ((EngineEvent) -> Void)? { get set }
    var supportsPictureInPicture: Bool { get }
    var isPictureInPictureActive: Bool { get }

    /// - Parameters:
    ///   - headers: 直连 CDN 时需要的 Referer / UA；走本地 HLS 代理时为 nil
    ///   - startAt: 从该位置开始（切画质、切引擎时续播）
    func load(url: URL, headers: [String: String]?, startAt: Double?)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    func setFill(_ fill: Bool)
    func togglePictureInPicture()
    func teardown()
}

extension PlaybackEngine {
    var supportsPictureInPicture: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func togglePictureInPicture() {}
}

@MainActor
enum EngineFactory {
    /// 未集成 KSPlayer 依赖时工程照常编译，只是没有 FFmpeg 兜底
    static var ffmpegAvailable: Bool {
        #if canImport(KSPlayer)
        true
        #else
        false
        #endif
    }

    static func make(_ kind: EngineKind) -> (any PlaybackEngine)? {
        switch kind {
        case .system:
            return AVPlayerEngine()
        case .ffmpeg:
            #if canImport(KSPlayer)
            return FFmpegEngine()
            #else
            return nil
            #endif
        }
    }
}
