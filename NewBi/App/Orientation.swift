import UIKit
import OSLog

/// App 默认只允许竖屏；进入全屏播放时临时放开横屏
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.allowed
    }

    /// 离线缓存在后台下完后系统唤醒 App：交给下载管理器处理完事件再回调
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletion = completionHandler
    }
}

@MainActor
enum Orientation {
    private(set) static var allowed: UIInterfaceOrientationMask = .portrait
    private static var target: UIInterfaceOrientationMask = .portrait
    private static var revision = 0
    private static let logger = Logger(subsystem: "NewBi", category: "Orientation")

    /// - Parameters:
    ///   - mask: 允许的方向
    ///   - preferred: 立即转到的方向（默认同 mask）
    static func lock(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientationMask? = nil) {
        allowed = mask
        target = preferred ?? mask
        revision += 1
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        request(in: scene, mask: target, retry: true)
    }

    static func restore(in scene: UIWindowScene) {
        guard scene.activationState == .foregroundActive else { return }
        // 允许两个横向时，保留已经生效的横向一侧。
        let current = scene.effectiveGeometry.interfaceOrientation
        let mask: UIInterfaceOrientationMask = current == .landscapeLeft ? .landscapeLeft : .landscapeRight
        let desired = allowed == .landscape && current.isLandscape ? mask : target
        request(in: scene, mask: desired, retry: true)
    }

    private static func request(in scene: UIWindowScene, mask: UIInterfaceOrientationMask, retry: Bool) {
        revision += 1
        let version = revision
        for window in scene.windows where window.windowLevel == .normal {
            var controller = window.rootViewController
            while let visible = controller {
                visible.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = visible.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak scene] error in
            let reason = error.localizedDescription
            Task { @MainActor in
                guard revision == version else { return }
                logger.debug("Orientation request declined: \(reason, privacy: .public)")
                guard retry else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard revision == version, let scene, scene.activationState == .foregroundActive else { return }
                request(in: scene, mask: mask, retry: false)
            }
        }
    }

    /// 设备方向 → 界面方向（两者左右相反）
    static func interfaceMask(for device: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
        switch device {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}

/// 全屏左侧上下滑调亮度
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var current: CGFloat { screen?.brightness ?? 0.5 }

    static func set(_ value: CGFloat) {
        screen?.brightness = value
    }
}
