import SwiftUI

/// 连播队列（目前用于稍后再看）：从列表进入时设好队列，视频页播完后原地换到下一个
@MainActor
@Observable
final class PlayQueue {
    static let shared = PlayQueue()

    private(set) var title = ""
    private var loadedCards: [VideoCard] = []
    var cards: [VideoCard] { loadedCards.filter { !OwnedContentDeletion.shared.videos.contains($0.id) } }
    /// start() 之后、下一次打开视频之前为 true：舞台据此判断这次打开是不是从队列入口进来的
    @ObservationIgnored private var armed = false

    func start(_ cards: [VideoCard], title: String) {
        self.loadedCards = cards
        self.title = title
        armed = true
    }

    func clear() {
        armed = false
        if !loadedCards.isEmpty { loadedCards = [] }
    }

    /// 舞台每次打开视频时调用：不是刚从队列入口进来的（普通卡片、链接）就结束之前的连播，
    /// 免得之后在别处看的视频碰巧也在旧队列里时被自动连下去
    func claimOpen() {
        if armed { armed = false } else { clear() }
    }

    func position(of bvid: String) -> Int? {
        cards.firstIndex { $0.bvid == bvid }
    }

    func next(after bvid: String) -> VideoCard? {
        guard let index = position(of: bvid), index + 1 < cards.count else { return nil }
        return cards[index + 1]
    }
}

/// 视频页简介里的队列位置：「稍后再看 · 连播中 3 / 12 · 下一个 xxx」。点开是整个队列，点哪个看哪个
struct QueueStrip: View {
    let bvid: String
    @State private var showList = false
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let queue = PlayQueue.shared
        if let index = queue.position(of: bvid) {
            Button { showList = true } label: { strip(queue, index: index) }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.primary)
                .accessibilityHint("查看并选择连播列表里的视频")
                .sheet(isPresented: $showList) {
                    QueueList(current: bvid) { card in
                        showList = false
                        VideoStage.shared.advance(to: card)
                    }
                }
        }
    }

    private func strip(_ queue: PlayQueue, index: Int) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.below.rectangle")
                    .foregroundStyle(accent.accentText(scheme))
                Text("\(queue.title) · 连播 \(index + 1) / \(queue.cards.count)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                if let next = queue.next(after: bvid) {
                    Text("下一个：\(next.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("已是最后一个").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.separator.opacity(0.5), in: .capsule)
            .contentShape(.capsule)
    }
}

/// 连播列表面板：当前这个高亮并自动滚到可见处，点其它的就在视频页里原地换过去
private struct QueueList: View {
    let current: String
    var onSelect: (VideoCard) -> Void
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let queue = PlayQueue.shared
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(queue.cards.enumerated()), id: \.element.bvid) { index, card in
                            let playing = card.bvid == current
                            Button { if !playing { onSelect(card) } } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(playing ? accent.accentText(scheme) : Theme.secondaryText)
                                        .frame(width: 24)
                                        .padding(.top, 6)
                                    VideoRow(card: card, subtitle: playing ? "正在播放" : nil)
                                }
                                .padding(8)
                                .background(playing ? accent.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 14))
                                .contentShape(.rect)
                            }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.primary)
                            .id(card.bvid)
                            .accessibilityAddTraits(playing ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("\(queue.title) · \(queue.cards.count) 个")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// 播完后的「即将播放」卡片：3 秒倒计时环，可取消或立即播放
struct UpNextCard: View {
    let next: VideoCard
    let queueTitle: String
    var onPlay: () -> Void
    var onCancel: () -> Void
    @State private var running = false
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: next.pic, size: CGSize(width: 96, height: 54))
                .frame(width: 96, height: 54)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(queueTitle) · 即将播放")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(next.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onPlay) {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: running ? 1 : 0)
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 3), value: running)
                    Image(systemName: "play.fill").font(.system(size: 13))
                }
                .frame(width: 38, height: 38)
            }
            .accessibilityLabel("立即播放下一个")
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 38)
            }
            .accessibilityLabel("取消连播")
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(12)
        .onAppear { running = true }
        .task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { onPlay() }
        }
    }
}
