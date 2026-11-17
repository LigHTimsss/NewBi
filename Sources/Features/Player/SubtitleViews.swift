import SwiftUI

/// 仅观察字幕文字，不订阅播放器的高频进度。
struct SubtitleOverlay: View {
    let store: SubtitleStore
    let bottomInset: CGFloat

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if !store.text.isEmpty {
                Text(store.text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 5))
                    .padding(.horizontal, 28)
            }
        }
        .padding(.bottom, bottomInset)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

struct SubtitlePanel: View {
    let store: SubtitleStore
    var centerFirstIn: CGFloat? = nil
    @Environment(\.accent) private var accent

    var body: some View {
        Group {
            if centerFirstIn != nil {
                // 每条轨道直接成为懒加载列表的一行，屏幕外的按钮无需提前测量。
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                    rows
                }
            } else {
                // 竖屏底部面板保留原来的自适应内容高度。
                VStack(alignment: .leading, spacing: 8) {
                    header
                    rows
                }
            }
        }
        .task(id: store.sourceID) { await store.loadList() }
    }

    private var header: some View {
        SubtitleHeaderLayout(viewportHeight: centerFirstIn) {
            Text("字幕").font(.serif(17)).tracking(1.4)
                .padding(.top, 6).padding(.bottom, 12)
            option("关闭", selected: store.selectedID == nil) { store.select(nil) }
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(store.tracks) { track in
            option(track.title, selected: store.selectedID == track.id) { store.select(track) }
        }
        if store.loading { ProgressView().frame(maxWidth: .infinity) }
        if let error = store.error {
            Text(error).font(.footnote).foregroundStyle(.secondary)
            Button("重新加载列表") { Task { await store.loadList(force: true) } }
        } else if !store.loading && store.tracks.isEmpty {
            Text("暂无可用字幕，登录后可能获取更多字幕")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(accent) }
            }
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? accent : .primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.16 : 0.08), in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 只测量标题和第一项来计算留白；后面的轨道列表不进入这个 Layout。
private struct SubtitleHeaderLayout: Layout {
    var viewportHeight: CGFloat?
    private let spacing: CGFloat = 8

    struct Cache {
        var width: CGFloat?
        var sizes: [CGSize]?
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) -> ([CGSize], CGFloat) {
        if cache.sizes == nil || cache.width != proposal.width {
            cache.width = proposal.width
            cache.sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        }
        let sizes = cache.sizes ?? []
        guard sizes.count >= 2, let viewportHeight else { return (sizes, 0) }
        return (sizes, max(0, viewportHeight / 2 - sizes[0].height - spacing - sizes[1].height / 2))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let (sizes, top) = metrics(proposal, subviews, &cache)
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: top + sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, sizes.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (sizes, top) = metrics(ProposedViewSize(width: bounds.width, height: nil), subviews, &cache)
        var y = bounds.minY + top
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes[index].height))
            y += sizes[index].height + spacing
        }
    }
}
