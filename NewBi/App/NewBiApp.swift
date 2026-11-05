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
        // 尽早开始监听网络类型：第一次播放前就要知道是不是移动网络
        _ = NetworkStatus.shared
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
    /// 当前账号（未登录为 nil）。按账号归属的数据（动态列表、点赞覆盖、动态红点基线）以它判断是否换了人
    var mid: Int? { isLoggedIn ? user?.mid : nil }
    /// 上一次查登录态因网络失败没有结果：回到前台 / 网络恢复时再查
    @ObservationIgnored private(set) var needsRetry = false
    /// 登录、退出各加一：在途的查询回来时世代已变就丢弃，旧响应不会把已退出的账号写回来
    @ObservationIgnored private var generation = 0

    func bootstrap() async {
        await BiliClient.shared.ensureBuvid()
        await refresh()
        // 服务器要求时用 refresh_token 换新 Cookie，换了就重新查一次
        if isLoggedIn, await CookieRefresher.shared.refreshIfNeeded() {
            await refresh()
        }
    }

    /// 只有服务器明确回答了才更新登录态；超时、断网时保留最后确认的状态（Cookie 多半仍有效），不把用户「踢成」游客
    func refresh() async {
        let token = generation
        let nav: NavInfo
        do {
            nav = try await BiliClient.shared.nav()
        } catch {
            guard token == generation else { return }
            needsRetry = true
            return
        }
        guard token == generation else { return }
        needsRetry = false
        user = nav
        guard nav.isLogin else {
            stat = nil
            return
        }
        if let fresh = try? await BiliClient.shared.get(.navStat, as: NavStat.self), token == generation {
            stat = fresh
        }
    }

    /// 登录成功（扫码 / 密码 / 验证码）：作废登录前还在途的查询（它们可能带回「未登录」）
    func didLogin() async {
        generation += 1
        await refresh()
    }

    func logout() {
        generation += 1
        needsRetry = false
        Credentials.clear()
        user = nil
        stat = nil
    }
}
