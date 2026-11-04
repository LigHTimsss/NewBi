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

    init(channel: Channel) {
        self.channel = channel
    }

    func refresh() async {
        page = 1
        reachedEnd = false
        await load(reset: true)
    }

    func loadMoreIfNeeded(after card: VideoCard) async {
        guard card.id == items.last?.id else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next: [VideoCard]
            switch channel {
            case .recommend:
                next = try await BiliClient.shared.get(.recommend(page: page), as: RecommendFeed.self).item
                    .filter { !$0.bvid.isEmpty } // 过滤广告/直播卡
            case .hot:
                let feed = try await BiliClient.shared.get(.popular(page: page), as: PopularFeed.self)
                reachedEnd = feed.noMore
                next = feed.list
            }
            let known = reset ? [] : Set(items.map(\.id))
            let fresh = next.filter { !known.contains($0.id) }
            items = reset ? fresh : items + fresh
            page += 1
            error = nil
        } catch {
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
                    GlassSegmented(options: Channel.allCases, selection: $channel, title: \.rawValue)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let first = model.items.first {
                    NavigationLink(value: first) { FeaturedBanner(card: first) }
                        .buttonStyle(PressableStyle())
                        .zoomSource(first, cornerRadius: 18)
                        .watchLaterMenu(first)
                        .riseIn(index: 0)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(Array(model.items.dropFirst().enumerated()), id: \.element.id) { index, card in
                        NavigationLink(value: card) { VideoCardView(card: card) }
                            .buttonStyle(PressableStyle())
                            .zoomSource(card)
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
        .contentMargins(.bottom, 96, for: .scrollContent) // 底部玻璃导航
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
        .task { if model.items.isEmpty { await model.refresh() } }
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
    }
}

struct VideoCardView: View {
    let card: VideoCard
    /// 空间页里都是同一个 UP 主，不显示
    var showsOwner = true
    /// 两列：Pro Max 上 (430 - 16*2 - 10) / 2 = 194pt，按最大值请求一次即可复用
    private let coverSize = CGSize(width: 194, height: 118)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: card.pic, size: coverSize)
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
