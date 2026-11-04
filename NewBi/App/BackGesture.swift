import SwiftUI
import UIKit

/// 侧滑返回。各页面都隐藏了系统导航栏（自绘玻璃顶栏），系统随之关掉了左边缘的返回手势；
/// 这里接管它的 delegate 重新打开，iOS 26 的全屏内容滑动返回也一并打开（从页面任意位置向右划）。
/// 横屏全屏播放时关掉：那里左右滑是拖进度。
@MainActor
final class BackGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = BackGesture()

    private weak var navigation: UINavigationController?
    /// iOS 26 的全屏内容返回手势；沿用系统自己的 delegate（它会处理和横向列表的冲突），这里只开关
    private weak var contentPop: UIGestureRecognizer?

    /// 横屏全屏播放器打开时为 true
    var isBlocked = false {
        didSet {
            navigation?.interactivePopGestureRecognizer?.isEnabled = !isBlocked
            contentPop?.isEnabled = !isBlocked
        }
    }

    func attach(to navigation: UINavigationController) {
        guard self.navigation !== navigation else { return }
        self.navigation = navigation
        navigation.interactivePopGestureRecognizer?.delegate = self
        navigation.interactivePopGestureRecognizer?.isEnabled = !isBlocked
        // 用 KVC 取，避免依赖具体 SDK 版本的属性名；没有这个手势的系统上直接跳过
        let key = "interactiveContentPopGestureRecognizer"
        if navigation.responds(to: NSSelectorFromString(key)),
           let gesture = navigation.value(forKey: key) as? UIGestureRecognizer {
            contentPop = gesture
            gesture.isEnabled = !isBlocked
        }
    }

    // 根页面（首页 / 动态 / 我的）没有可返回的页面
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !isBlocked && (navigation?.viewControllers.count ?? 0) > 1
    }

    // 边缘返回优先于页面里的其它手势（横向列表、拖动等）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

/// 放进 NavigationStack 根页面的背景里：找到承载它的 UINavigationController 并接上返回手势
struct BackGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            connect()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            connect()
        }

        private func connect() {
            if let navigation = navigationController { BackGesture.shared.attach(to: navigation) }
        }
    }
}
