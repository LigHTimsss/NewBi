import SwiftUI
import AVFoundation

@main
struct NewBiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()
    @AppStorage("accentIndex") private var accentIndex = 0
    /// 0 跟随系统 · 1 浅色 · 2 深色
    @AppStorage("appearance") private var appearance = 0

    init() {
        // 允许后台播放 / 静音模式下出声
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            let accent = Theme.accents[min(max(accentIndex, 0), Theme.accents.count - 1)]
            RootView()
                .environment(session)
                .environment(\.accent, accent)
                .tint(accent)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                .task { await session.bootstrap() }
        }
    }
}

/// 全局登录态
@MainActor
@Observable
final class SessionStore {
    private(set) var user: NavInfo?
    private(set) var stat: NavStat?
    var isLoggedIn: Bool { user?.isLogin == true }

    func bootstrap() async {
        await BiliClient.shared.ensureBuvid()
        await refresh()
    }

    func refresh() async {
        user = try? await BiliClient.shared.nav()
        stat = isLoggedIn ? try? await BiliClient.shared.get(.navStat, as: NavStat.self) : nil
    }

    func logout() {
        let storage = HTTPCookieStorage.shared
        storage.cookies?
            .filter { $0.domain.hasSuffix("bilibili.com") && !$0.name.hasPrefix("buvid") }
            .forEach(storage.deleteCookie)
        user = nil
        stat = nil
    }
}
