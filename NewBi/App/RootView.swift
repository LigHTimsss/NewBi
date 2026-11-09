import SwiftUI
import UIKit
import CryptoKit

enum Route: Hashable {
    case settings
    /// 设置 → 清理存储空间
    case storage
    case search
    /// UP 主空间
    case space(mid: Int)
    /// 空间页直接打开「动态」（我的页 → 动态数）
    case spaceDynamics(mid: Int)
    /// 关注 / 粉丝列表
    case relations(mid: Int, kind: RelationKind)
    case history
    case watchLater
    case downloads
    case favorites
    case favoriteFolder(id: Int, title: String)
    /// UP 主的合集（season）或系列（series）
    case season(mid: Int, id: Int, title: String, isSeries: Bool)
    /// 消息中心
    case messages
    /// 回复我的 / @ 我的 / 收到的赞 / 系统通知
    case notices(NoticeKind)
    /// 私信会话
    case chat(ChatPeer)
    /// 直播间（可以是短号）
    case live(roomID: Int)
}

/// 根视图：系统 TabView 提供原生 Liquid Glass 底栏。
/// 单一 NavigationStack 包住整个 Tab 容器，进入详情页时导航栏自然被覆盖。
struct RootView: View {
    @State private var path = NavigationPath()
    @State private var tab: AppTab = .home
    @AppStorage("clipboardVideoAutoOpen") private var clipboardVideoAutoOpen = false
    @AppStorage("clipboardVideoLastDigest") private var clipboardVideoLastDigest = ""
    @State private var clipboardTask: Task<Void, Never>?
    @State private var clipboardChangeCount: Int?
    @State private var externalLink: ExternalLinkRequest?
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            RootTabs(path: $path, tab: $tab)
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case .settings: SettingsView()
                    case .storage: StorageView()
                    case .search:
                        // 普通推入：zoom 转场自带「下拉返回」，在搜索结果里下拉会直接退回首页；
                        // 现在只认侧滑返回，结果里下拉是刷新
                        SearchView()
                    case .space(let mid):
                        SpaceView(mid: mid)
                    case .spaceDynamics(let mid):
                        SpaceView(mid: mid, initialTab: .dynamic)
                    case .relations(let mid, let kind):
                        RelationListView(mid: mid, kind: kind)
                    case .history:
                        HistoryView()
                    case .watchLater:
                        WatchLaterView()
                    case .downloads:
                        DownloadsView()
                    case .favorites:
                        FavoritesView()
                    case .favoriteFolder(let id, let title):
                        FolderView(id: id, title: title)
                    case .season(let mid, let id, let title, let isSeries):
                        SeasonView(mid: mid, id: id, title: title, isSeries: isSeries)
                    case .messages:
                        MessageCenterView()
                    case .notices(let kind):
                        NoticeListView(kind: kind)
                    case .chat(let peer):
                        ChatView(peer: peer)
                    case .live(let roomID):
                        LiveRoomView(roomID: roomID)
                    }
                }
                .miniPlayerInset()
                .appPageBackground()
            }
        }
        // 视频页在导航栈外：一层全屏舞台。卡片封面放大成视频页，返回时收成胶囊或缩回卡片，全程同一个画面
        .accessibilityHidden(VideoStage.shared.coversApp)
        .overlay {
            StageView(capsuleLift: path.isEmpty ? 72 : 8)
                .animation(VideoStage.shared.showsMini ? Motion.component : nil, value: path.isEmpty)
                .environment(\.openRoute, { route in
                    VideoStage.shared.makeRoom()
                    path.append(route)
                })
        }
        // 自绘分享框：在视频舞台之上，哪里点分享都从这里弹出
        .overlay { SharePanelLayer() }
        // 「直播中」头像这类嵌在别的链接里的入口：不套 NavigationLink，直接推页面（在视频页上先收进胶囊）
        .environment(\.pushRoute, { route in
            VideoStage.shared.makeRoom()
            path.append(route)
        })
        // 正文里的 newbi:// 链接：@ 进空间、BV 号开视频；其它网址交给系统（Safari）
        .environment(\.openURL, OpenURLAction { url in
            switch AppLink.parse(url) {
            case .space(let mid):
                VideoStage.shared.makeRoom()
                path.append(Route.space(mid: mid))
                return .handled
            case .video(let bvid):
                VideoStage.shared.open(VideoCard(id: 0, bvid: bvid, cid: nil, title: "", pic: "", duration: 0, owner: nil, stat: nil), from: nil)
                return .handled
            case .seek:
                return .discarded // 只在视频页里有意义，由视频页自己处理
            case .external:
                return .systemAction
            }
        })
        .onOpenURL { url in
            clipboardTask?.cancel()
            clipboardChangeCount = UIPasteboard.general.changeCount
            externalLink = ExternalLinkRequest(url: url)
        }
        .task { checkClipboardVideo() }
        .onChange(of: clipboardVideoAutoOpen) { _, enabled in
            clipboardTask?.cancel()
            if enabled {
                clipboardChangeCount = nil
                checkClipboardVideo()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clipboardTask?.cancel() }
            if phase == .active { checkClipboardVideo() }
        }
        .onDisappear { clipboardTask?.cancel() }
        .task(id: externalLink?.id) {
            guard let request = externalLink else { return }
            await openExternal(request.url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { note in
            if let scene = note.object as? UIWindowScene { Orientation.restore(in: scene) }
        }
        .toast(
            Binding(get: { ToastCenter.shared.message }, set: { ToastCenter.shared.message = $0 }),
            bottomPadding: VideoStage.shared.showsMini ? 176 : 110
        )
        // 回到前台查一次有没有新动态（一次轻量请求，不轮询）；红点基线按账号分开，换账号时重新查
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await DynamicBadge.shared.check(mid: session.mid) }
            // 上次查登录态时网络不通：回到前台再确认一次
            if session.needsRetry { Task { await session.refresh() } }
        }
        .task(id: session.mid) { await DynamicBadge.shared.check(mid: session.mid) }
        .onChange(of: NetworkStatus.shared.isOnline) { _, online in
            if online, session.needsRetry { Task { await session.refresh() } }
        }
        // 消息未读数：启动、回到前台、登录态变化时各查一次
        .task(id: session.isLoggedIn) { await MessageBadge.shared.check(loggedIn: session.isLoggedIn) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await MessageBadge.shared.check(loggedIn: session.isLoggedIn) } }
        }
    }


    /// 只在启动、回到前台或开启开关时检查；不监听每次剪贴板变化。
    @MainActor
    private func checkClipboardVideo() {
        guard clipboardVideoAutoOpen, scenePhase == .active else { return }
        let pasteboard = UIPasteboard.general
        guard clipboardChangeCount != pasteboard.changeCount else { return }
        // 先记次数，避免系统粘贴授权使场景重新激活时重复读取。
        clipboardChangeCount = pasteboard.changeCount
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return }
        guard let text = pasteboard.string ?? pasteboard.url?.absoluteString,
              let candidate = ClipboardVideoLink.candidate(in: text) else { return }
        let digest = SHA256.hash(data: Data(candidate.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard digest != clipboardVideoLastDigest else { return }
        clipboardTask?.cancel()
        clipboardTask = Task { @MainActor in
            do {
                guard let url = try await ClipboardVideoLink.resolve(candidate) else { return }
                guard !Task.isCancelled, clipboardVideoAutoOpen,
                      scenePhase == .active else { return }
                // 持久化摘要而非剪贴板原文，重启后同一条链接也不反复打开。
                await openExternal(url) { clipboardVideoLastDigest = digest }
            } catch {
                guard !Task.isCancelled else { return }
                ToastCenter.shared.show("剪贴板视频链接解析失败，请重新复制后重试")
            }
        }
    }

    @MainActor
    private func openExternal(_ url: URL, onVideoOpened: () -> Void = {}) async {
        guard !Task.isCancelled else { return }
        guard let target = ExternalAppLink.parse(url) else {
            ToastCenter.shared.show("NewBi 暂不支持此链接")
            return
        }
        switch target {
        case .home:
            VideoStage.shared.makeRoom()
            path = NavigationPath()
            tab = .home
        case .space(let mid):
            VideoStage.shared.makeRoom()
            path.append(Route.space(mid: mid))
        case .live(let roomID):
            VideoStage.shared.makeRoom()
            path.append(Route.live(roomID: roomID))
        case .search:
            VideoStage.shared.makeRoom()
            path.append(Route.search)
        case .video(let id, let requestedCid, let page):
            do {
                let endpoint: Endpoint = switch id {
                case .bv(let bvid): .view(bvid: bvid)
                case .av(let aid): .view(aid: aid)
                }
                let detail = try await BiliClient.shared.get(endpoint, as: VideoDetail.self)
                // 新链接会取消旧 task；迟到的 AV 转 BV / 分 P 查询不能覆盖新目的地。
                guard !Task.isCancelled else { return }
                var cid = requestedCid
                if let page {
                    let pages = detail.pages ?? []
                    guard let part = pages.first(where: { $0.page == page }),
                          requestedCid == nil || requestedCid == part.cid else {
                        ToastCenter.shared.show("链接指定的分 P 不存在或不匹配")
                        return
                    }
                    cid = part.cid
                }
                if let cid, cid != detail.cid && !(detail.pages ?? []).contains(where: { $0.cid == cid }) {
                    ToastCenter.shared.show("链接指定的分 P 不属于此视频")
                    return
                }
                let card = VideoCard(id: detail.aid, bvid: detail.bvid, cid: cid ?? detail.cid,
                    title: detail.title, pic: detail.pic, duration: detail.duration,
                    owner: detail.owner, stat: detail.stat)
                VideoStage.shared.open(card, from: nil, pinsPart: cid != nil)
                onVideoOpened()
            } catch {
                guard !Task.isCancelled else { return }
                ToastCenter.shared.show("打开视频失败：\(error.localizedDescription)")
            }
        }
    }

}

enum AppTab: Hashable {
    case home, dynamic, mine, search
}

/// 固定身份的系统标签页保留各自滚动和加载状态；玻璃、选中透镜和图标由系统绘制。
private struct RootTabs: View {
    @Binding var path: NavigationPath
    @Binding var tab: AppTab
    @State private var dynamicRefresh = 0

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: select)) {
            Tab("首页", systemImage: "house", value: AppTab.home) {
                HomeView(onAvatar: { select(.mine) }, onMessages: { path.append(Route.messages) })
                    .background {
                        CompactDynamicBadgeStyle()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .modifier(RootTabPage(active: tab == .home && path.isEmpty))
            }
            Tab("动态", systemImage: "safari", value: AppTab.dynamic) {
                DynamicView(refreshToken: dynamicRefresh)
                    .background {
                        CompactDynamicBadgeStyle()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .modifier(RootTabPage(active: tab == .dynamic && path.isEmpty))
            }
            .badge(DynamicBadge.shared.hasNew && tab != .dynamic ? Text("●") : nil)
            Tab("我的", systemImage: "person", value: AppTab.mine) {
                MineView()
                    .background {
                        CompactDynamicBadgeStyle()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .modifier(RootTabPage(active: tab == .mine && path.isEmpty))
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: searchTabRole) {
                // iOS 27 显式使用 prominent；iOS 26 使用 search，保持原生独立按钮。
                // selection 的 setter 在选中前转为导航操作，不将它作为第四个内容页。
                Color.clear.accessibilityHidden(true)
            }
        }
        .tabBarMinimizeBehavior(.never)
        .background(Theme.background)
        .background { BackGestureEnabler().frame(width: 0, height: 0) }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var searchTabRole: TabRole {
        // 较旧 Xcode 的 SDK 不包含 prominent，保留 iOS 26 工具链兼容性。
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return .search
    }

    private func select(_ item: AppTab) {
        if item == .search {
            // 保留当前栏目；用原有 NavigationStack 推入，让搜索框随页面滑入。
            // 不先选择占位页再回切，也不挂异步 onAppear 跳转。
            guard path.isEmpty else { return }
            withAnimation { path.append(Route.search) }
            return
        }
        if item == .dynamic, tab == .dynamic || DynamicBadge.shared.hasNew {
            dynamicRefresh += 1
        }
        // 不给 TabView 外挂弹簧或整页平移动画，保留原生选择交互。
        tab = item
    }
}

private struct RootTabPage: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.pageActive, active)
            .coverSpace()
            // TabView 已提供底栏安全区，这里只额外为迷你播放器留空间。
            .miniPlayerInset()
            .appPageBackground()
            .toolbar(.visible, for: .tabBar)
    }
}

/// 保留系统角标的位置与显隐，只将默认红底替换为小红点。
private struct CompactDynamicBadgeStyle: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.applyBadgeStyle()
    }

    final class Controller: UIViewController {
        // 只借助父控制器访问 UITabBarItem，不参与页面绘制或触摸处理。
        override func loadView() {
            let helper = UIView(frame: .zero)
            helper.backgroundColor = .clear
            helper.isOpaque = false
            helper.isUserInteractionEnabled = false
            helper.accessibilityElementsHidden = true
            view = helper
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyBadgeStyle()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyBadgeStyle()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyBadgeStyle()
        }

        private weak var styledItem: UITabBarItem?

        func applyBadgeStyle() {
            // RootTabs 固定顺序：首页、动态、我的、搜索。各页均安装，首次未打开动态也能生效。
            guard let items = tabBarController?.tabBar.items, items.count > 1 else { return }
            let item = items[1]
            guard styledItem !== item else { return }
            item.badgeColor = .clear
            for state: UIControl.State in [.normal, .selected] {
                item.setBadgeTextAttributes([
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.systemRed
                ], for: state)
            }
            styledItem = item
        }
    }
}
