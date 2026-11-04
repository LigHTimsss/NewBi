import SwiftUI

/// 连播队列（目前用于稍后再看）：从列表进入时设好队列，视频页播完后原地换到下一个
@MainActor
@Observable
final class PlayQueue {
    static let shared = PlayQueue()

    private(set) var title = ""
    private(set) var cards: [VideoCard] = []

    func start(_ cards: [VideoCard], title: String) {
        self.cards = cards
        self.title = title
    }

    func clear() {
        cards = []
    }

    func position(of bvid: String) -> Int? {
        cards.firstIndex { $0.bvid == bvid }
    }

    func next(after bvid: String) -> VideoCard? {
        guard let index = position(of: bvid), index + 1 < cards.count else { return nil }
        return cards[index + 1]
    }
}

/// 导航目的地：视频页外面包一层，连播时只换里面的视频页（不加深导航栈）
struct VideoDestination: View {
    @State private var card: VideoCard

    init(card: VideoCard) {
        _card = State(initialValue: card)
    }

    var body: some View {
        VideoDetailView(card: card) { next in
            withAnimation(Motion.component) { card = next }
        }
        .id(card.bvid)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// 视频页简介里的队列位置：「稍后再看 · 连播中 3 / 12 · 下一个 xxx」
struct QueueStrip: View {
    let bvid: String
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let queue = PlayQueue.shared
        if let index = queue.position(of: bvid) {
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
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.separator.opacity(0.5), in: .capsule)
        }
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
