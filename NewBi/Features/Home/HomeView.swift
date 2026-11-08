import SwiftUI

enum Channel: String, CaseIterable, Identifiable {
    case recommend = "推荐", hot = "热门"
    var id: Self { self }
}

@MainActor
@Observable
final class FeedModel {
    let channel: Channel
    private(set) var items: [VideoCard] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private var page = 1
    private var reachedEnd = false
    private var account: Int?
    private var initialized = false
    private var generation = 0

    func open(account: Int?) async {
        if initialized, self.account == account, !items.isEmpty { return }
        generation += 1
        let version = generation
        self.account = account
        initialized = true
        items = []; page = 1; reachedEnd = false; error = nil; isLoading = true
        let key = "\(account ?? 0)-\(channel == .recommend ? "recommend" : "hot")"
        let automatic = UserDefaults.standard.object(forKey: "homeAutoRefresh") as? Bool ?? true
        let saved = automatic ? nil : await HomeFeedCache.shared.read(key)
        guard generation == version else { return }
        isLoading = false
        if let saved, !saved.items.isEmpty {
            items = saved.items; page = saved.nextPage; reachedEnd = saved.reachedEnd
        } else {
            await refresh()
        }
    }

    init(channel: Channel) {
        self.channel = channel
    }

    func refresh() async {
        guard !isLoading else { return }
        await load(reset: true)
    }

    func loadMoreIfNeeded(after card: VideoCard) async {
        guard card.id == items.last?.id else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        let version = generation
        let requestedPage = reset ? 1 : page
        let key = "\(account ?? 0)-\(channel == .recommend ? "recommend" : "hot")"
        defer { if generation == version { isLoading = false } }
        do {
            let next: [VideoCard]
            var noMore = false
            switch channel {
            case .recommend:
                next = try await BiliClient.shared.get(.recommend(page: requestedPage), as: RecommendFeed.self).item
                    .filter { !$0.bvid.isEmpty } // 过滤广告/直播卡
            case .hot:
                let feed = try await BiliClient.shared.get(.popular(page: requestedPage), as: PopularFeed.self)
                noMore = feed.noMore
                next = feed.list
            }
            guard generation == version, !Task.isCancelled else { return }
            let known = reset ? [] : Set(items.map(\.id))
            let fresh = next.filter { !known.contains($0.id) }
            items = reset ? fresh : items + fresh
            page = requestedPage + 1
            reachedEnd = noMore
            error = nil
            await HomeFeedCache.shared.write(.init(items: items, nextPage: page, reachedEnd: reachedEnd), key: key)
        } catch {
            guard generation == version, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 首页：顶部玻璃频道条 + 横向分页（推荐 / 热门）
struct HomeView: View {
    var onAvatar: () -> Void
    var onMessages: () -> Void
    @Environment(SessionStore.self) private var session
    @State private var channel: Channel = .recommend
    @State private var feeds: [Channel: FeedModel] = Dictionary(
        uniqueKeysWithValues: Channel.allCases.map { ($0, FeedModel(channel: $0)) }
    )

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Channel.allCases) { item in
                    FeedPage(model: feeds[item]!)
                        .containerRelativeFrame(.horizontal)
                        .id(item)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: Binding(
            get: { channel },
            set: { if let value = $0 { withAnimation(Motion.tab) { channel = value } } }
        ))
        .overlay(alignment: .top) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    GlassAvatarButton(url: session.isLoggedIn ? session.user?.face : nil, label: "个人中心", action: onAvatar)
                    NativeSegmented(options: Channel.allCases, selection: $channel, title: \.rawValue)
                    GlassCircleButton(systemImage: "envelope", label: "消息", action: onMessages)
                        .overlay(alignment: .topTrailing) {
                            UnreadBadge(count: MessageBadge.shared.total)
                                .offset(x: 4, y: -2)
                        }
                        .accessibilityValue(MessageBadge.shared.total > 0 ? "\(MessageBadge.shared.total) 条未读" : "")
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct FeedPage: View {
    let model: FeedModel
    @Environment(\.displayScale) private var scale
    @Environment(SessionStore.self) private var session

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let first = model.items.first {
                    VideoLink(card: first) { FeaturedBanner(card: first) }
                        .buttonStyle(PressableStyle())
                        .watchLaterMenu(first)
                        .riseIn(index: 0)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(Array(model.items.dropFirst().enumerated()), id: \.element.id) { index, card in
                        VideoLink(card: card) { VideoCardView(card: card) }
                            .buttonStyle(PressableStyle())
                            .watchLaterMenu(card)
                            .riseIn(index: index + 1)
                            .onAppear { Task { await model.loadMoreIfNeeded(after: card) } }
                    }
                }
                if model.isLoading && !model.items.isEmpty {
                    ProgressView().padding()
                }
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.top, 56, for: .scrollContent)    // 顶部玻璃频道条
        .contentMargins(.bottom, 16, for: .scrollContent) // 原生 TabView 已提供底栏安全区
        // 新一页到了就把封面下载、解码进内存：滑到时直接出图，不再一格格淡入
        .onChange(of: model.items.count, initial: true) { old, new in
            // 第一个是大横幅（尺寸不同，自己加载）；加载更多时只取新的一页，刷新后从头取
            let start = old > 0 && old < new ? old : 1
            guard new > start else { return }
            RemoteImage.prefetch(model.items.dropFirst(start).map(\.pic), size: VideoCardView.coverSize, scale: scale)
        }
        .overlay {
            if model.items.isEmpty {
                if let error = model.error {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
                    }
                } else if model.isLoading {
                    ProgressView()
                }
            }
        }
        .refreshable { await model.refresh() }
        .task(id: session.mid) { await model.open(account: session.mid) }
    }
}

/// 首屏焦点位（设计稿 Banner），取推荐流第一条
private struct FeaturedBanner: View {
    let card: VideoCard

    var body: some View {
        RemoteImage(url: card.pic, size: CGSize(width: 398, height: 196))
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
            }
            .overlay(alignment: .bottomLeading) {
                Text(card.title)
                    .font(.serif(17))
                    .tracking(1.4)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(14)
            }
            .clipShape(.rect(cornerRadius: 18))
            .videoCover(cornerRadius: 18)
    }
}

struct VideoCardView: View {
    let card: VideoCard
    /// 空间页里都是同一个 UP 主，不显示
    var showsOwner = true
    /// 两列：Pro Max 上 (430 - 16*2 - 10) / 2 = 194pt，按最大值请求一次即可复用
    static let coverSize = CGSize(width: 194, height: 118)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: card.pic, size: Self.coverSize)
                .aspectRatio(174.0 / 106.0, contentMode: .fit) // 设计稿 174×106
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 8) {
                        if let view = card.stat?.view {
                            Label(view.biliCount, systemImage: "play.rectangle")
                        }
                        if let danmaku = card.stat?.danmaku {
                            Label(danmaku.biliCount, systemImage: "text.bubble")
                        }
                        Spacer(minLength: 0)
                        Text(card.duration.durationText)
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                }
                .clipShape(.rect(cornerRadius: 12))
                .videoCover(cornerRadius: 12)

            Text(card.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            if showsOwner, let owner = card.owner {
                Label(owner.name, systemImage: "person")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
