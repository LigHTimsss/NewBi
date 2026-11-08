import SwiftUI
import UIKit

@MainActor
@Observable
final class SpaceModel {
    enum Tab: String, CaseIterable {
        case home = "主页", dynamic = "动态", videos = "投稿", seasons = "合集", favorites = "收藏"
    }

    enum Order: String, CaseIterable {
        case pubdate, click, stow

        var title: String {
            switch self {
            case .pubdate: "最新发布"
            case .click: "最多播放"
            case .stow: "最多收藏"
            }
        }
    }

    let mid: Int
    let relation: RelationModel
    private(set) var profile: SpaceCard?
    /// 粉丝勋章、成就勋章（拿不到时不显示，不影响页面）
    private(set) var accInfo: SpaceAccInfo?
    private(set) var location: String?
    @ObservationIgnored private var locationLoaded = false
    /// 投稿里搜索的关键词（空为不搜）
    private(set) var keyword = ""
    private var loadedTopVideo: VideoCard?
    var topVideo: VideoCard? {
        loadedTopVideo.flatMap { OwnedContentDeletion.shared.videos.contains($0.id) ? nil : $0 }
    }
    private var loadedMasterpieces: [VideoCard] = []
    var masterpieces: [VideoCard] { loadedMasterpieces.filter { !OwnedContentDeletion.shared.videos.contains($0.id) } }
    /// 主页「最近投稿」：首次按最新发布加载的前 6 个
    private var loadedRecent: [SpaceVideo] = []
    private var loadedVideos: [SpaceVideo] = []
    private var loadedVideoCount: Int?
    var recent: [SpaceVideo] { loadedRecent.filter { !OwnedContentDeletion.shared.videos.contains($0.id) } }
    var videos: [SpaceVideo] { loadedVideos.filter { !OwnedContentDeletion.shared.videos.contains($0.id) } }
    var videoCount: Int? {
        loadedVideoCount.map { max(0, $0 - (loadedVideos.count - videos.count)) }
    }
    private(set) var isLoadingVideos = false
    private(set) var videosError: String?
    private(set) var error: String?
    var order: Order = .pubdate {
        didSet { if order != oldValue { loadVideos(reset: true) } }
    }

    var hasMoreVideos: Bool { loadedVideoCount.map { loadedVideos.count < $0 } ?? true }
    var followerCount: Int { (profile?.card.fans ?? 0) + relation.followerDelta }

    @ObservationIgnored private var page = 1
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// 「动态」Tab：切走再切回不重新加载
    let dynamics: DynamicModel
    /// 「合集」Tab：合集 + 系列
    private(set) var seasons: [SpaceSeason]?
    private(set) var seasonsError: String?
    /// 「收藏」Tab：对方公开的收藏夹
    private(set) var favorites: [FavFolder]?
    private(set) var favoritesError: String?

    init(mid: Int) {
        self.mid = mid
        relation = RelationModel(mid: mid)
        dynamics = DynamicModel(hostMid: mid)
    }

    func loadSeasons(force: Bool = false) async {
        guard force || seasons == nil else { return }
        do {
            seasons = try await BiliClient.shared.get(.spaceSeasons(mid: mid, page: 1), as: SpaceSeasonsList.self).all
            seasonsError = nil
        } catch {
            seasonsError = error.localizedDescription
        }
    }

    func loadFavorites(force: Bool = false) async {
        guard force || favorites == nil else { return }
        do {
            favorites = try await BiliClient.shared.get(.favFolders(mid: mid, page: 1), as: FavFolderPage.self).list ?? []
            favoritesError = nil
        } catch {
            favoritesError = error.localizedDescription
        }
    }

    func loadLocation() async {
        guard !locationLoaded else { return }
        if let tags = try? await BiliClient.shared.get(.spaceTags(mid: mid), as: SpaceTagResponse.self),
           !Task.isCancelled {
            location = tags.location
            locationLoaded = true
        }
    }

    func load() async {
        guard profile == nil else { return }
        loadVideos(reset: true)
        async let top = try? BiliClient.shared.get(.spaceTop(mid: mid), as: VideoCard.self)
        async let master = try? BiliClient.shared.get(.masterpiece(mid: mid), as: [VideoCard].self)
        async let acc = try? BiliClient.shared.get(.spaceAccInfo(mid: mid), as: SpaceAccInfo.self)
        do {
            let card = try await BiliClient.shared.get(.spaceCard(mid: mid), as: SpaceCard.self)
            profile = card
            relation.seed(card.following)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loadedTopVideo = await top
        loadedMasterpieces = (await master ?? []).filter { !$0.bvid.isEmpty && $0.bvid != topVideo?.bvid }
        accInfo = await acc
    }

    /// 搜这个 UP 主的投稿；空字符串回到全部
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != keyword else { return }
        keyword = trimmed
        loadVideos(reset: true)
    }

    func retry() async {
        profile = nil
        await load()
    }

    /// 下拉刷新：资料（不清空，新数据回来直接替换）+ 当前 Tab 的内容
    func refresh(_ tab: Tab) async {
        if let card = try? await BiliClient.shared.get(.spaceCard(mid: mid), as: SpaceCard.self) {
            profile = card
            relation.seed(card.following)
        }
        if let acc = try? await BiliClient.shared.get(.spaceAccInfo(mid: mid), as: SpaceAccInfo.self) { accInfo = acc }
        switch tab {
        case .home, .videos:
            if keyword.isEmpty { loadedRecent = [] }
            loadVideos(reset: true)
            await loadTask?.value
        case .dynamic:
            await dynamics.refresh()
        case .seasons:
            await loadSeasons(force: true)
        case .favorites:
            await loadFavorites(force: true)
        }
    }

    func loadMore(after video: SpaceVideo) {
        guard video.id == videos.last?.id else { return }
        loadVideos(reset: false)
    }

    func loadVideos(reset: Bool) {
        if reset {
            loadTask?.cancel()
            page = 1
            loadedVideos = []
            loadedVideoCount = nil
            videosError = nil
            isLoadingVideos = false
        }
        guard !isLoadingVideos, hasMoreVideos else { return }
        isLoadingVideos = true
        let page = page, order = order, keyword = keyword
        loadTask = Task {
            do {
                let result = try await BiliClient.shared.get(.spaceVideos(mid: mid, page: page, order: order.rawValue, keyword: keyword), as: SpaceArcSearch.self)
                guard !Task.isCancelled else { return }
                let known = Set(loadedVideos.map(\.id))
                loadedVideos += (result.list.vlist ?? []).filter { !known.contains($0.id) }
                loadedVideoCount = result.page.count
                if order == .pubdate, keyword.isEmpty, recent.isEmpty { loadedRecent = Array(videos.prefix(6)) }
                self.page = page + 1
                videosError = nil
            } catch {
                guard !Task.isCancelled else { return }
                videosError = error.localizedDescription
            }
            isLoadingVideos = false
        }
    }
}

/// UP 主空间：头图 + 资料 + 主页 / 投稿。结构参考 B 站空间页，视觉沿用本 App 的玻璃风格
struct SpaceView: View {
    private let initialTab: SpaceModel.Tab
    @State private var model: SpaceModel
    @State private var tab: SpaceModel.Tab = .home
    @State private var headerHeight: CGFloat = 0
    @State private var scroll: SpaceScrollCoordinator
    @State private var visited: Set<SpaceModel.Tab> = []
    @State private var signExpanded = false
    private var collapsed: Bool { scroll.compact }
    private var tabPinned: Bool { scroll.pinned }
    @State private var topInset: CGFloat = 0
    @State private var toast: String?
    /// 搜 TA 的投稿
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    /// - Parameter initialTab: 一进来就停在哪个 Tab：默认「投稿」（和官方客户端一样）；我的页点「动态」时直接看动态
    init(mid: Int, initialTab: SpaceModel.Tab = .videos) {
        self.initialTab = initialTab
        _model = State(initialValue: SpaceModel(mid: mid))
        _tab = State(initialValue: initialTab)
        _visited = State(initialValue: [initialTab])
        _scroll = State(initialValue: SpaceScrollCoordinator(initialPage: initialTab))
    }

    /// 顶栏底边（全局坐标）：Tab 栏滚到这里就吸顶
    private var topBarBottom: CGFloat { topInset + 52 }
    private var pinOffset: CGFloat { max(0, headerHeight + 12 - topBarBottom) }

    // 五个等宽页面，初始偏移量为入口页序号 × 视口宽度。
    private var initialPageAnchor: UnitPoint {
        let pages = SpaceModel.Tab.allCases
        let index = pages.firstIndex(of: initialTab) ?? 0
        return UnitPoint(x: CGFloat(index) / CGFloat(max(1, pages.count - 1)), y: 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            tabPager
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                topBar
                if tabPinned {
                    tabBar.transition(.opacity)
                }
            }
            .padding(.bottom, tabPinned ? 8 : 0)
            .frame(maxWidth: .infinity)
            .background {
                // 与头像姓名胶囊同步淡入实色底，覆盖状态栏、顶栏和吸顶标签栏。
                // 只改变颜色透明度，不增加实时模糊或逐帧滚动状态更新。
                Theme.background
                    .opacity(collapsed || tabPinned ? 1 : 0)
                    .animation(Motion.micro, value: collapsed || tabPinned)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .onChange(of: pinOffset, initial: true) { _, value in scroll.setCollapseLimit(value) }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .toast($toast)
        .task { await model.load() }
        .task(id: model.mid) { await model.loadLocation() }
    }

    // MARK: 顶栏：返回 / 收起后的名字 / 分享

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                GlassCircleButton(systemImage: "chevron.left", label: "返回") { dismiss() }
                Spacer(minLength: 0)
                if collapsed, let card = model.profile?.card {
                    HStack(spacing: 8) {
                        RemoteImage(url: card.face, size: CGSize(width: 26, height: 26))
                            .frame(width: 26, height: 26)
                            .clipShape(.circle)
                        Text(card.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 14)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 0)
                // 搜 TA 的投稿：切到「投稿」、弹出搜索框
                GlassCircleButton(systemImage: "magnifyingglass", label: "搜索 TA 的视频或动态") {
                    withAnimation(Motion.component) {
                        // 在「动态」上就搜动态，其它 Tab 切到「投稿」搜视频
                        if tab != .dynamic { tab = .videos }
                        searching = true
                    }
                    searchFocused = true
                }
                Button {
                    if let url = URL(string: "https://space.bilibili.com/\(model.mid)") {
                        let name = model.profile?.card.name ?? ""
                        ShareCenter.shared.share(title: name.isEmpty ? "UP 主空间" : "\(name)的个人空间", url: url)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(PressableStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("分享")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: 资料

    @ViewBuilder
    private var profile: some View {
        if let profile = model.profile {
            let card = profile.card
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 16) {
                    LiveAvatar(mid: model.mid, url: card.face, size: 84)
                        .padding(3)
                        .background(Theme.background, in: .circle)
                    VStack(spacing: 10) {
                        HStack {
                            NavigationLink(value: Route.relations(mid: model.mid, kind: .followers)) {
                                stat(model.followerCount, "粉丝").contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            NavigationLink(value: Route.relations(mid: model.mid, kind: .followings)) {
                                stat(card.attention, "关注").contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            stat(profile.likeNum ?? 0, "获赞")
                        }
                        HStack(spacing: 8) {
                            FollowButton(relation: model.relation) { toast = $0 }
                            // 登录后、不是自己时可以私信
                            if session.isLoggedIn, session.mid != model.mid {
                                NavigationLink(value: Route.chat(ChatPeer(id: model.mid, name: card.name, face: card.face))) {
                                    Text("私信")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .frame(width: 64, height: 32)
                                        .background(Theme.selection, in: .capsule)
                                        .contentShape(.capsule)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .padding(.top, -44) // 头像压在头图上

                HStack(spacing: 6) {
                    Text(card.name).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    if let level = card.levelInfo?.currentLevel { LevelBadge(level: level) }
                    if card.vip?.vipStatus == 1, let label = card.vip?.label?.text, !label.isEmpty {
                        VipBadge(text: label)
                    }
                    // 佩戴的粉丝勋章、成就勋章
                    if let medal = model.accInfo?.wornMedal { FansMedalChip(medal: medal) }
                    if let plate = model.accInfo?.nameplate, let url = plate.imageSmall ?? plate.image, !url.isEmpty {
                        RemoteImage(url: url, size: CGSize(width: 22, height: 22), fill: false, background: .clear)
                            .frame(width: 22, height: 22)
                            .accessibilityLabel(plate.name ?? "勋章")
                    }
                }

                // 服务端提供属地标签时展示在 UID 旁。
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = "\(model.mid)"
                        toast = "UID 已复制"
                    } label: {
                        Text("UID:\(String(model.mid))")
                    }
                    .buttonStyle(.plain)
                    if let location = model.location { Text(location) }
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, -6)

                if let official = card.officialVerify, official.type >= 0, !official.desc.isEmpty {
                    Label(official.desc, systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        // 个人认证黄色、机构认证蓝色
                        .symbolRenderingMode(.palette)
                        .labelStyle(OfficialLabelStyle(color: official.type == 0 ? .orange : .blue))
                }

                if !card.sign.isEmpty {
                    Text(card.sign)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(signExpanded ? nil : 2)
                        .onTapGesture { withAnimation(Motion.component) { signExpanded.toggle() } }
                }
            }
            .padding(.horizontal, 16)
            .background(Theme.background)
            .transition(.opacity)
        } else if let error = model.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.retry() } }.buttonStyle(.glass)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        }
    }

    private func stat(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value.biliCount)
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.component, value: value)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 搜索投稿 / 动态

    /// 在「动态」上搜动态，其余搜投稿
    private func submitSearch(_ text: String) {
        if tab == .dynamic {
            model.dynamics.search(text)
        } else {
            model.search(text)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField(tab == .dynamic ? "搜索 TA 的动态" : "搜索 TA 的视频", text: $query)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { submitSearch(query) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        submitSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityLabel("清除")
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.selection, in: .capsule)
            Button("取消") {
                query = ""
                searchFocused = false
                model.search("")
                model.dynamics.search("")
                withAnimation(Motion.component) { searching = false }
            }
            .font(.system(size: 15))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Tab

    private var tabBar: some View {
        GlassSegmented(options: SpaceModel.Tab.allCases, selection: $tab) { item in
            if item == .videos, let count = model.videoCount ?? model.profile?.archiveCount {
                return "投稿 \(count.biliCount)"
            }
            return item.rawValue
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var tabPager: some View {
        GeometryReader { viewport in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(SpaceModel.Tab.allCases, id: \.self) { page in
                        SpacePageScroll(page: page, scroll: scroll) {
                            pageHeader
                        } content: {
                            VStack(alignment: .leading, spacing: 0) {
                                if page == tab, page == .videos || page == .dynamic,
                                   searching || !model.keyword.isEmpty || !model.dynamics.keyword.isEmpty {
                                    searchBar
                                }
                                if page == tab || visited.contains(page) {
                                    tabContent(for: page)
                                }
                            }
                            .padding(.bottom, 40)
                            .frame(minHeight: max(0, viewport.size.height - topBarBottom), alignment: .top)
                        }
                        .refreshable { await model.refresh(page) }
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .clipped()
                        .id(page)
                    }
                }
                .scrollTargetLayout()
                .background { SpacePagerPopPriority().allowsHitTesting(false) }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "space-horizontal-pager")
            .scrollTargetBehavior(.paging)
            .defaultScrollAnchor(initialPageAnchor, for: .initialOffset)
            .scrollPosition(id: Binding(
                get: { Optional(tab) },
                set: { page in
                    guard let page, page != tab else { return }
                    searchFocused = false
                    tab = page
                }
            ), anchor: .leading)
            .onChange(of: tab, initial: true) { _, selected in
                scroll.select(selected)
                let tabs = SpaceModel.Tab.allCases
                guard let index = tabs.firstIndex(of: selected) else { return }
                visited.formUnion(tabs[max(0, index - 1)...min(tabs.count - 1, index + 1)])
            }
        }
    }

    @ViewBuilder
    private var pageHeader: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SpaceBanner(url: model.profile?.space?.lImg, scroll: scroll)
                profile
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerHeight = height
            }
            tabBar
                .opacity(tabPinned ? 0 : 1)
                .allowsHitTesting(!tabPinned)
                .accessibilityHidden(tabPinned)
                .padding(.vertical, 12)
        }
        .background(Theme.background)
        // 各页裁剪出同一位置的页头；横向分页只移动正文。
        .visualEffect { header, geometry in
            header.offset(x: -geometry.frame(in: .named("space-horizontal-pager")).minX)
        }
    }

    @ViewBuilder
    private func tabContent(for page: SpaceModel.Tab) -> some View {
        switch page {
        case .home: SpaceHome(model: model, showAll: { withAnimation(Motion.tab) { tab = .videos } })
        case .dynamic: SpaceDynamics(model: model.dynamics)
        case .videos: SpaceVideos(model: model)
        case .seasons: SpaceSeasons(model: model)
        case .favorites: SpaceFavorites(model: model)
        }
    }
}

/// 只让空间分页的 pan 等待导航栈的边缘返回；屏幕中间仍由原生分页处理。
private struct SpacePagerPopPriority: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.connect() }

    final class Probe: UIView {
        private weak var installedPan: UIPanGestureRecognizer?
        private weak var installedPop: UIGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
        }

        func connect() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let pager = ancestor as? UIScrollView else { return }

            var responder: UIResponder? = pager
            while let current = responder {
                if let controller = current as? UIViewController,
                   let navigation = controller.navigationController,
                   let pop = navigation.interactivePopGestureRecognizer {
                    let pan = pager.panGestureRecognizer
                    if installedPan !== pan || installedPop !== pop {
                        BackGesture.shared.attach(to: navigation)
                        pan.require(toFail: pop)
                        installedPan = pan
                        installedPop = pop
                    }
                    return
                }
                responder = current.next
            }
        }
    }
}

/// 逐帧状态只由页头读取；列表只在滚动结束或切换板块时对齐一次。
@MainActor
@Observable
private final class SpaceScrollCoordinator {
    private(set) var headerOffset: CGFloat = 0
    private(set) var pullDown: CGFloat = 0
    private(set) var pinned = false
    private(set) var compact = false
    private(set) var alignmentRevision = 0
    @ObservationIgnored private var state: SpaceScrollState<SpaceModel.Tab>

    init(initialPage: SpaceModel.Tab) { state = SpaceScrollState(activePage: initialPage) }

    func offset(for page: SpaceModel.Tab) -> CGFloat { state.scrollOffset(for: page) }

    func select(_ page: SpaceModel.Tab) {
        state.select(page)
        pullDown = 0
        alignmentRevision += 1
    }

    func setCollapseLimit(_ value: CGFloat) {
        state.setCollapseLimit(value)
        publishHeader()
        alignmentRevision += 1
    }

    func moved(_ page: SpaceModel.Tab, from old: CGFloat, to new: CGFloat) {
        guard page == state.activePage else { return }
        state.scroll(page, from: old, to: new)
        pullDown = state.headerOffset == 0 ? max(0, -new) : 0
        publishHeader()
    }

    func settled(_ page: SpaceModel.Tab) {
        guard page == state.activePage else { return }
        pullDown = 0
        // 连深处的板块也只对齐共享页头部分，正文阅读距离保持不变。
        alignmentRevision += 1
    }

    private func publishHeader() {
        headerOffset = state.headerOffset
        pinned = state.collapseLimit > 0 && headerOffset >= state.collapseLimit - 1
        let nextCompact = headerOffset > 150
        if compact != nextCompact {
            withAnimation(Motion.micro) { compact = nextCompact }
        }
    }
}

private struct SpaceMovingHeader<Content: View>: View {
    let scroll: SpaceScrollCoordinator
    let contentOffset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            // 抵消本页的正文阅读距离，让顶部始终使用共享的收起距离。
            // 留在原生 ScrollView 内，资料区仍可直接拖动和下拉刷新。
            .offset(y: contentOffset + scroll.pullDown - scroll.headerOffset)
            .animation(nil, value: contentOffset)
            .animation(nil, value: scroll.headerOffset)
            .animation(nil, value: scroll.pullDown)
    }
}

/// 各板块常驻；原生滚动偏移 = 共享页头收起距离 + 本板块正文阅读距离。
private struct SpacePageScroll<Header: View, Content: View>: View {
    let page: SpaceModel.Tab
    let scroll: SpaceScrollCoordinator
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition(edge: .top)
    @State private var phase: ScrollPhase = .idle
    @State private var lastOffset: CGFloat = 0
    @State private var visualOffset: CGFloat = 0

    private struct Metrics: Equatable {
        let visual: CGFloat
        let reading: CGFloat
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SpaceMovingHeader(scroll: scroll, contentOffset: visualOffset) { header }
                    .zIndex(1)
                content
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Metrics.self) { metrics($0) } action: { _, value in
            recordOffset(value)
        }
        .onScrollPhaseChange { _, next, context in
            let wasUserScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
            // 开始拖动时计入首段距离；结束时计入可能晚于 phase 通知的最后一段。
            if next == .interacting { phase = next }
            recordOffset(metrics(context.geometry))
            phase = next
            if next == .idle, wasUserScrolling { scroll.settled(page) }
        }
        .onChange(of: scroll.alignmentRevision, initial: true) { _, _ in
            let target = scroll.offset(for: page)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // 程序对齐不能当作用户滚动再次写回共享页头。
                phase = .idle
                lastOffset = target
                visualOffset = target
                position.scrollTo(y: target)
            }
        }
    }

    private func recordOffset(_ value: Metrics) {
        let old = lastOffset
        lastOffset = value.reading
        visualOffset = value.visual
        guard phase == .interacting || phase == .decelerating else { return }
        scroll.moved(page, from: old, to: value.reading)
    }

    private func metrics(_ geometry: ScrollGeometry) -> Metrics {
        let y = geometry.contentOffset.y + geometry.contentInsets.top
        let bottom = max(0, geometry.contentSize.height + geometry.contentInsets.top
            + geometry.contentInsets.bottom - geometry.containerSize.height)
        // 保留顶部下拉以展示回弹，底部回弹不计入阅读距离。
        return Metrics(visual: y, reading: min(y, bottom))
    }
}

// MARK: - 头图：下拉放大、上滑视差

private struct SpaceBanner: View {
    let url: String?
    let scroll: SpaceScrollCoordinator
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            if let url, !url.isEmpty {
                RemoteImage(url: url, size: CGSize(width: 430, height: 200))
            } else {
                LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Theme.background.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        // 视差使用共享页头距离，不随某个板块的正文阅读深度变化。
        .scaleEffect(1 + scroll.pullDown / 200, anchor: .bottom)
        .offset(y: scroll.headerOffset * 0.4)
        .clipped()
    }
}

private struct VipBadge: View {
    let text: String
    @Environment(\.accent) private var accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(accent.accentFill, in: .capsule)
    }
}

private struct OfficialLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

// MARK: - 主页：置顶 / 代表作 / 最近投稿

private struct SpaceHome: View {
    let model: SpaceModel
    var showAll: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let top = model.topVideo {
                section("置顶视频") {
                    VideoLink(card: top) { FeaturedVideo(card: top) }
                        .buttonStyle(PressableStyle())
                }
            }

            if !model.masterpieces.isEmpty {
                section("代表作") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(model.masterpieces) { card in
                                VideoLink(card: card) { VideoCardView(card: card, showsOwner: false) }
                                    .buttonStyle(PressableStyle())
                                    .frame(width: 194)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .padding(.horizontal, -16)
                }
            }

            if !model.recent.isEmpty {
                section("最近投稿", trailing: "查看全部", action: showAll) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                        ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, video in
                            VideoLink(card: video.card) { VideoCardView(card: video.card, showsOwner: false) }
                                .buttonStyle(PressableStyle())
                                .watchLaterMenu(video.card)
                        }
                    }
                }
            } else if model.isLoadingVideos {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if model.profile != nil, model.topVideo == nil, model.masterpieces.isEmpty {
                ContentUnavailableView("还没有投稿", systemImage: "play.rectangle")
            }
        }
        .padding(.horizontal, 16)
    }

    private func section(
        _ title: String, trailing: String? = nil, action: @escaping () -> Void = {},
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.serif(17)).tracking(1.4)
                Spacer()
                if let trailing {
                    Button(action: action) {
                        HStack(spacing: 2) {
                            Text(trailing)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(accent.accentText(scheme))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            content()
        }
    }
}

/// 置顶视频：整宽大封面
private struct FeaturedVideo: View {
    let card: VideoCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: card.pic, size: CGSize(width: 398, height: 224))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 40)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 10) {
                        if let view = card.stat?.view { Label(view.biliCount, systemImage: "play.rectangle") }
                        if let danmaku = card.stat?.danmaku { Label(danmaku.biliCount, systemImage: "text.bubble") }
                        Spacer(minLength: 0)
                        Text(card.duration.durationText)
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                }
                .clipShape(.rect(cornerRadius: 14))
                .videoCover(cornerRadius: 14)
            Text(card.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - 投稿：排序 + 列表

private struct SpaceVideos: View {
    let model: SpaceModel
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var space = model
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(SpaceModel.Order.allCases, id: \.self) { order in
                    let on = order == model.order
                    Button {
                        withAnimation(Motion.component) { space.order = order }
                    } label: {
                        Text(order.title)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? accent.accentText(scheme) : Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(on ? Theme.selection : .clear, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }

            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                VideoLink(card: video.card) { VideoRow(card: video.card, subtitle: video.subtitle) }
                    .buttonStyle(PressableStyle())
                    .watchLaterMenu(video.card)
                    .onAppear { model.loadMore(after: video) }
            }

            if model.isLoadingVideos {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if let error = model.videosError {
                ContentUnavailableView {
                    Label("投稿加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { model.loadVideos(reset: true) }.buttonStyle(.glass)
                }
            } else if model.videos.isEmpty {
                ContentUnavailableView("还没有投稿", systemImage: "play.rectangle")
            } else if !model.hasMoreVideos {
                Text("没有更多了")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// 佩戴中的粉丝勋章：渐变底的勋章名 + 等级
private struct FansMedalChip: View {
    let medal: SpaceAccInfo.FansMedal.Medal

    private static func color(_ value: Int?, fallback: Int) -> Color {
        let rgb = value ?? fallback
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    var body: some View {
        let start = Self.color(medal.medalColorStart, fallback: 0x5762A8)
        let end = Self.color(medal.medalColorEnd ?? medal.medalColorStart, fallback: 0x5762A8)
        HStack(spacing: 0) {
            Text(medal.medalName ?? "")
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [start, end], startPoint: .leading, endPoint: .trailing))
            if let level = medal.level {
                Text("\(level)")
                    .foregroundStyle(start)
                    .padding(.horizontal, 4)
                    .frame(maxHeight: .infinity)
                    .background(.white)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .frame(height: 16)
        .clipShape(.rect(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(start, lineWidth: 0.5) }
        .accessibilityLabel("粉丝勋章 \(medal.medalName ?? "") \(medal.level ?? 0) 级")
    }
}
