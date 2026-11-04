import SwiftUI

enum Route: Hashable {
    case settings
    case search
    /// UP 主空间
    case space(mid: Int)
    case history
    case watchLater
    case downloads
    case favorites
    case favoriteFolder(id: Int, title: String)
    /// 只知道 BV 号的视频（评论 / 动态里的链接）
    case video(bvid: String)
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
    @Environment(SessionStore.self) private var session
    @Namespace private var searchTransition
    /// 视频卡片 ⇄ 视频页 ⇄ 迷你胶囊 的缩放转场
    @Namespace private var zoom
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                ZStack {
                    ForEach(AppTab.allCases) { item in
                        page(item)
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
            // 迷你胶囊位（底栏上方，和迷你条同一位置）：正在播放的视频返回时收缩到这里
            .miniSlot(bottom: 72)
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
            .navigationDestination(for: VideoCard.self) { VideoDestination(card: $0) }
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case .settings: SettingsView()
                    case .search:
                        // 从搜索按钮放大展开，返回时缩回按钮
                        SearchView().navigationTransition(.zoom(sourceID: "search", in: searchTransition))
                    case .space(let mid):
                        SpaceView(mid: mid)
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
                    case .video(let bvid):
                        VideoDestination(card: VideoCard(id: 0, bvid: bvid, cid: nil, title: "", pic: "", duration: 0, owner: nil, stat: nil))
                    case .messages:
                        MessageCenterView()
                    case .notices(let kind):
                        NoticeListView(kind: kind)
                    case .chat(let peer):
                        ChatView(peer: peer)
                    }
                }
                .miniPlayerInset()
                .modifier(RouteMiniSlot(route: route))
            }
        }
        .environment(\.zoomNamespace, zoom)
        // 迷你播放条：根页面浮在底栏上方，二级页面贴底；视频页收缩到胶囊位后在原地淡入，
        // 点它时视频页从胶囊位展开（缩放转场），它自己淡出
        .overlay(alignment: .bottom) {
            if let mini = NowPlaying.shared.minimized {
                MiniPlayerBar(model: mini) { path.append(mini.card) }
                    .padding(.bottom, path.isEmpty ? 72 : 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .animation(Motion.component, value: path.isEmpty)
            }
        }
        .onChange(of: path.count) { old, new in NowPlaying.shared.pathChanged(from: old, to: new) }
        // 正文里的 newbi:// 链接：@ 进空间、BV 号开视频；其它网址交给系统（Safari）
        .environment(\.openURL, OpenURLAction { url in
            switch AppLink.parse(url) {
            case .space(let mid):
                path.append(Route.space(mid: mid))
                return .handled
            case .video(let bvid):
                path.append(Route.video(bvid: bvid))
                return .handled
            case .seek:
                return .discarded // 只在视频页里有意义，由视频页自己处理
            case .external:
                return .systemAction
            }
        })
        .sensoryFeedback(.selection, trigger: tab)
        .toast(
            Binding(get: { ToastCenter.shared.message }, set: { ToastCenter.shared.message = $0 }),
            bottomPadding: NowPlaying.shared.minimized == nil ? 110 : 176
        )
        // 回到前台查一次有没有新动态（一次轻量请求，不轮询）
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await DynamicBadge.shared.check() } }
            if phase == .background { NowPlaying.shared.enteredBackground() }
        }
        .task { await DynamicBadge.shared.check() }
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
        withAnimation(Motion.tab) { tab = item }
    }
}

/// 二级页面的迷你胶囊位（贴底）。视频页不放：返回时视频页会配到自己身上的胶囊位、缩没了
private struct RouteMiniSlot: ViewModifier {
    let route: Route

    func body(content: Content) -> some View {
        if case .video = route {
            content
        } else {
            content.miniSlot(bottom: 8)
        }
    }
}
