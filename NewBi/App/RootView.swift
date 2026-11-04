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
}

/// 根视图：三个 Tab 横向平移切换（Flow 画板），底部为自定义玻璃导航。
/// 单一 NavigationStack 包住整个 Tab 容器，进入详情页时导航栏自然被覆盖。
struct RootView: View {
    @State private var tab: AppTab = .home
    @State private var path = NavigationPath()
    /// 递增即让动态页刷新：有红点时切过去、或在动态页再点一次「动态」
    @State private var dynamicRefresh = 0
    @Namespace private var searchTransition
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
            .navigationDestination(for: VideoCard.self) { VideoDetailView(card: $0) }
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
                    }
                }
                .miniPlayerInset()
            }
        }
        // 迷你播放条：根页面浮在底栏上方，二级页面贴底；从下方滑入、横滑或点 × 关闭
        .overlay(alignment: .bottom) {
            if let mini = NowPlaying.shared.minimized {
                MiniPlayerBar(model: mini) { path.append(mini.card) }
                    .padding(.bottom, path.isEmpty ? 72 : 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    .animation(Motion.component, value: path.isEmpty)
            }
        }
        .onChange(of: path.count) { old, new in NowPlaying.shared.pathChanged(from: old, to: new) }
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
    }

    @ViewBuilder
    private func page(_ item: AppTab) -> some View {
        switch item {
        case .home: HomeView(onAvatar: { select(.mine) })
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
