import SwiftUI

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
    private(set) var topVideo: VideoCard?
    private(set) var masterpieces: [VideoCard] = []
    /// 主页「最近投稿」：首次按最新发布加载的前 6 个
    private(set) var recent: [SpaceVideo] = []
    private(set) var videos: [SpaceVideo] = []
    private(set) var videoCount: Int?
    private(set) var isLoadingVideos = false
    private(set) var videosError: String?
    private(set) var error: String?
    var order: Order = .pubdate {
        didSet { if order != oldValue { loadVideos(reset: true) } }
    }

    var hasMoreVideos: Bool { videoCount.map { videos.count < $0 } ?? true }
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

    func load() async {
        guard profile == nil else { return }
        loadVideos(reset: true)
        async let top = try? BiliClient.shared.get(.spaceTop(mid: mid), as: VideoCard.self)
        async let master = try? BiliClient.shared.get(.masterpiece(mid: mid), as: [VideoCard].self)
        do {
            let card = try await BiliClient.shared.get(.spaceCard(mid: mid), as: SpaceCard.self)
            profile = card
            relation.seed(card.following)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        topVideo = await top
        masterpieces = (await master ?? []).filter { !$0.bvid.isEmpty && $0.bvid != topVideo?.bvid }
    }

    func retry() async {
        profile = nil
        await load()
    }

    func loadMore(after video: SpaceVideo) {
        guard video.id == videos.last?.id else { return }
        loadVideos(reset: false)
    }

    func loadVideos(reset: Bool) {
        if reset {
            loadTask?.cancel()
            page = 1
            videos = []
            videoCount = nil
            videosError = nil
            isLoadingVideos = false
        }
        guard !isLoadingVideos, hasMoreVideos else { return }
        isLoadingVideos = true
        let page = page, order = order
        loadTask = Task {
            do {
                let result = try await BiliClient.shared.get(.spaceVideos(mid: mid, page: page, order: order.rawValue), as: SpaceArcSearch.self)
                guard !Task.isCancelled else { return }
                let known = Set(videos.map(\.id))
                videos += (result.list.vlist ?? []).filter { !known.contains($0.id) }
                videoCount = result.page.count
                if order == .pubdate, recent.isEmpty { recent = Array(videos.prefix(6)) }
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
    @State private var model: SpaceModel
    @State private var tab: SpaceModel.Tab = .home
    @State private var signExpanded = false
    @State private var collapsed = false
    @State private var tabBarMinY: CGFloat = .infinity
    @State private var topInset: CGFloat = 0
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss

    init(mid: Int) {
        _model = State(initialValue: SpaceModel(mid: mid))
    }

    /// 顶栏底边（全局坐标）：Tab 栏滚到这里就吸顶
    private var topBarBottom: CGFloat { topInset + 52 }
    private var tabPinned: Bool { tabBarMinY <= topBarBottom }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SpaceBanner(url: model.profile?.space?.lImg)
                    profile
                    tabBar
                        .opacity(tabPinned ? 0 : 1)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { tabBarMinY = $0 }
                        .padding(.vertical, 12)
                    tabContent
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 150 } action: { _, value in
                withAnimation(Motion.micro) { collapsed = value }
            }

            VStack(spacing: 8) {
                topBar
                if tabPinned {
                    tabBar.transition(.opacity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .toast($toast)
        .task { await model.load() }
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
                ShareLink(item: URL(string: "https://space.bilibili.com/\(model.mid)")!) {
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
                    RemoteImage(url: card.face, size: CGSize(width: 84, height: 84))
                        .frame(width: 84, height: 84)
                        .clipShape(.circle)
                        .padding(3)
                        .background(Theme.background, in: .circle)
                    VStack(spacing: 10) {
                        HStack {
                            stat(model.followerCount, "粉丝")
                            stat(card.attention, "关注")
                            stat(profile.likeNum ?? 0, "获赞")
                        }
                        FollowButton(relation: model.relation) { toast = $0 }
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
                }

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

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .home: SpaceHome(model: model, showAll: { withAnimation(Motion.tab) { tab = .videos } })
        case .dynamic: SpaceDynamics(model: model.dynamics)
        case .videos: SpaceVideos(model: model)
        case .seasons: SpaceSeasons(model: model)
        case .favorites: SpaceFavorites(model: model)
        }
    }
}

// MARK: - 头图：下拉放大、上滑视差

private struct SpaceBanner: View {
    let url: String?
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
        // 只做渲染变换，不触发布局，滚动时开销很小
        .visualEffect { content, proxy in
            let minY = proxy.frame(in: .scrollView).minY
            return content
                .scaleEffect(minY > 0 ? 1 + minY / 200 : 1, anchor: .bottom)
                .offset(y: minY < 0 ? -minY * 0.4 : 0)
        }
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
                    NavigationLink(value: top) { FeaturedVideo(card: top) }
                        .buttonStyle(PressableStyle())
                }
            }

            if !model.masterpieces.isEmpty {
                section("代表作") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(model.masterpieces) { card in
                                NavigationLink(value: card) { VideoCardView(card: card, showsOwner: false) }
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
                            NavigationLink(value: video.card) { VideoCardView(card: video.card, showsOwner: false) }
                                .buttonStyle(PressableStyle())
                                .watchLaterMenu(video.card)
                                .riseIn(index: index)
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
                NavigationLink(value: video.card) { VideoRow(card: video.card, subtitle: video.subtitle) }
                    .buttonStyle(PressableStyle())
                    .watchLaterMenu(video.card)
                    .riseIn(index: index)
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
