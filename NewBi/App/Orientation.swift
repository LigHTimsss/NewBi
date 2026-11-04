import UIKit

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

    /// - Parameters:
    ///   - mask: 允许的方向
    ///   - preferred: 立即转到的方向（默认同 mask）
    static func lock(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientationMask? = nil) {
        allowed = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred ?? mask)) { _ in }
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
