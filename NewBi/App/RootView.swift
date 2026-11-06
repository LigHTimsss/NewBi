import SwiftUI

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
}

/// 根视图：三个 Tab 横向平移切换（Flow 画板），底部为自定义玻璃导航。
/// 单一 NavigationStack 包住整个 Tab 容器，进入详情页时导航栏自然被覆盖。
struct RootView: View {
    @State private var tab: AppTab = .home
    @State private var path = NavigationPath()
    /// 递增即让动态页刷新：有红点时切过去、或在动态页再点一次「动态」
    @State private var dynamicRefresh = 0
    /// 正在滑出的页（可能连点了好几次），这一串切换的动画全部结束后清空
    @State private var leaving: Set<AppTab> = []
    @State private var switchID = 0
    @Environment(SessionStore.self) private var session
    @Namespace private var searchTransition
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                ZStack {
                    ForEach(AppTab.allCases) { item in
                        page(item)
                            // 当前页和正在滑出的页照常；其余页停掉呼吸光轨（停的时候都在屏幕外，看不出来）
                            .environment(\.pageActive, item == tab || leaving.contains(item))
                            // 卡片位置按页面记：切页平移时不必每帧重算每张卡片
                            .coverSpace()
                            .miniPlayerInset(66)
                            .frame(width: geo.size.width)
                            .offset(x: CGFloat(item.rawValue - tab.rawValue) * geo.size.width)
                            .allowsHitTesting(item == tab)
                            .accessibilityHidden(item != tab)
                    }
                }
            }
            .background(Theme.background)
            // 重新打开被隐藏导航栏关掉的侧滑返回
            .background { BackGestureEnabler().frame(width: 0, height: 0) }
            .overlay(alignment: .bottom) {
                GlassTabBar(
                    selection: tab,
                    searchTransition: searchTransition,
                    badges: DynamicBadge.shared.hasNew && tab != .dynamic ? [.dynamic] : [],
                    onSelect: select
                ) {
                    path.append(Route.search)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
                    }
                }
                .miniPlayerInset()
            }
        }
        // 视频页在导航栈外：一层全屏舞台。卡片封面放大成视频页，返回时收成胶囊或缩回卡片，全程同一个画面
        .accessibilityHidden(VideoStage.shared.coversApp)
        .overlay {
            StageView(capsuleLift: path.isEmpty ? 72 : 8)
                .animation(Motion.component, value: path.isEmpty)
                .environment(\.openRoute, { route in
                    VideoStage.shared.makeRoom()
                    path.append(route)
                })
        }
        // 自绘分享框：在视频舞台之上，哪里点分享都从这里弹出
        .overlay { SharePanelLayer() }
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
        .sensoryFeedback(.selection, trigger: tab)
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

    @ViewBuilder
    private func page(_ item: AppTab) -> some View {
        switch item {
        case .home: HomeView(onAvatar: { select(.mine) }, onMessages: { path.append(Route.messages) })
        case .dynamic: DynamicView(refreshToken: dynamicRefresh)
        case .mine: MineView()
        }
    }

    private func select(_ item: AppTab) {
        if item == .dynamic, tab == .dynamic || DynamicBadge.shared.hasNew {
            dynamicRefresh += 1
        }
        guard item != tab else { return }
        leaving.insert(tab)
        switchID += 1
        let id = switchID
        withAnimation(Motion.tab, completionCriteria: .logicallyComplete) {
            tab = item
        } completion: {
            // 旧的完成回调不能清掉新一次切换还在滑出的页
            if switchID == id { leaving = [] }
        }
    }
}
