import SwiftUI

@MainActor
@Observable
final class WatchLaterModel {
    private(set) var items: [WatchLaterItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    var finishedCount: Int { items.filter(\.isFinished).count }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await BiliClient.shared.get(.watchLater, as: WatchLaterPage.self).list ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 先移除，失败放回
    func delete(_ item: WatchLaterItem) async throws {
        let csrf = try Self.csrf()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        do {
            try await BiliClient.shared.post(.watchLaterDelete, form: ["aid": "\(item.aid)", "csrf": csrf])
        } catch {
            items.insert(item, at: min(index, items.count))
            throw error
        }
    }

    func removeFinished() async throws {
        let csrf = try Self.csrf()
        try await BiliClient.shared.post(.watchLaterDelete, form: ["viewed": "true", "csrf": csrf])
        items.removeAll(where: \.isFinished)
    }

    func clear() async throws {
        let csrf = try Self.csrf()
        try await BiliClient.shared.post(.watchLaterClear, form: ["csrf": csrf])
        items = []
    }

    private static func csrf() throws -> String {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        return csrf
    }
}

/// 稍后再看：进度条与历史记录一致，左滑删除，右上角菜单可「移除已看完」「清空」
struct WatchLaterView: View {
    @Environment(SessionStore.self) private var session
    @State private var model = WatchLaterModel()
    @State private var confirmClear = false
    @State private var toast: String?
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if session.isLoggedIn {
                list
            } else {
                LoginPrompt(message: "登录后把想看的视频先存起来，有空再看")
            }
        }
        .background(Theme.background)
        .navigationTitle("稍后再看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if session.isLoggedIn, !model.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            run { try await model.removeFinished() }
                        } label: {
                            Label("移除已看完（\(model.finishedCount)）", systemImage: "checkmark.circle")
                        }
                        .disabled(model.finishedCount == 0)
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("清空", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .confirmationDialog("清空稍后再看？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { run { try await model.clear() } }
        }
        .toast($toast)
        .task(id: session.isLoggedIn) {
            if session.isLoggedIn, model.items.isEmpty { await model.refresh() }
        }
    }

    private var list: some View {
        List {
            if let first = model.items.first {
                // 从第一个开始看
                HStack {
                    Text("共 \(model.items.count) 个")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                    Spacer()
                    VideoLink(card: first.card, morphs: false, beforeOpen: { armQueue() }) {
                        Label("开始播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(accent.accentFill, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                    .fixedSize()
                }
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
            }

            ForEach(model.items) { item in
                WatchLaterRow(item: item) { armQueue(from: item) }  // 从这里进入的视频播完后按列表顺序连播（已看完的跳过）
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            run { try await model.delete(item) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }

            footer
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Motion.component, value: model.items.map(\.id))
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading, model.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let error = model.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
            }
        } else if model.items.isEmpty {
            ContentUnavailableView("稍后再看是空的", systemImage: "clock", description: Text("长按视频卡片，或在视频页「更多」里添加"))
        }
    }

    /// 连播队列：跳过已看完的，但点进去的那一个总在队列里
    private func armQueue(from item: WatchLaterItem? = nil) {
        let start = item ?? model.items.first
        PlayQueue.shared.start(model.items.filter { !$0.isFinished || $0.id == start?.id }.map(\.card), title: "稍后再看")
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { toast = error.localizedDescription }
        }
    }
}

private struct WatchLaterRow: View {
    let item: WatchLaterItem
    var onOpen: () -> Void = {}
    @Environment(\.accent) private var accent

    var body: some View {
        VideoLink(card: item.card, beforeOpen: onOpen) {
            HStack(spacing: 12) {
                RemoteImage(url: item.pic, size: CGSize(width: 150, height: 84))
                    .frame(width: 150, height: 84)
                    .overlay(alignment: .bottomTrailing) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                    }
                    .overlay(alignment: .bottom) {
                        if item.progressRatio > 0 {
                            GeometryReader { geo in
                                Capsule().fill(accent).frame(width: geo.size.width * item.progressRatio, height: 2)
                            }
                            .frame(height: 2)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .videoCover(cornerRadius: 10)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let owner = item.owner {
                        Text(owner.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    if let addAt = item.addAt {
                        Text("\((item.stat?.view ?? 0).biliCount)播放 · \(Date(timeIntervalSince1970: TimeInterval(addAt)).formatted(.relative(presentation: .named)))添加")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 84)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if item.isFinished { return "已看完" }
        if let progress = item.progress, progress > 0 { return "\(progress.durationText) / \(item.duration.durationText)" }
        return item.duration.durationText
    }
}
