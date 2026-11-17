import SwiftUI
import MediaPlayer
import AVFAudio

/// 全局媒体音量；引擎保持单位增益，不再叠加一层独立音量。
@MainActor @Observable
final class SystemPlaybackVolume {
    static let shared = SystemPlaybackVolume()
    private(set) var value: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored private weak var view: MPVolumeView?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, _ in
            Task { @MainActor in
                // 在主线程重新读取，避免路由变化或连续按键的旧回调覆盖新状态。
                Self.shared.refresh()
            }
        }
    }

    func attach(_ view: MPVolumeView) {
        self.view = view
        refresh()
    }

    func detach(_ view: MPVolumeView) {
        if self.view === view { self.view = nil }
    }

    func refresh() { value = AVAudioSession.sharedInstance().outputVolume }

    func set(_ requested: Float) {
        guard requested.isFinite, let view, view.window != nil,
              let slider = view.subviews.compactMap({ $0 as? UISlider }).first,
              slider.isEnabled else { refresh(); return }
        let target = min(max(requested, 0), 1)
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        // 反馈以系统确认值为准，不把目标值伪装成实际音量。
        refresh()
    }
}

/// 保持系统音量控件在窗口中，供播放器手势驱动；不使用私有音量设置 API。
struct SystemPlaybackVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        view.showsVolumeSlider = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.alpha = 0.01
        SystemPlaybackVolume.shared.attach(view)
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
    static func dismantleUIView(_ view: MPVolumeView, coordinator: ()) {
        SystemPlaybackVolume.shared.detach(view)
    }
}
