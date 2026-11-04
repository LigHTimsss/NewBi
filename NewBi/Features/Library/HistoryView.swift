import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    struct Section: Identifiable {
        let title: String
        let items: [HistoryItem]
        var id: String { title }
    }

    private(set) var items: [HistoryItem] = []
    private(set) var isLoading = false
    private(set) var isEnd = false
    private(set) var error: String?

    @ObservationIgnored private var cursor = (max: 0, viewAt: 0, business: "")

    /// 按观看时间分组：今天 / 昨天 / 近一周 / 更早
    var sections: [Section] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        var groups: [(String, [HistoryItem])] = [("今天", []), ("昨天", []), ("近一周", []), ("更早", [])]
        for item in items {
            let date = Date(timeIntervalSince1970: TimeInterval(item.viewAt))
            let index = calendar.isDateInToday(date) ? 0 : calendar.isDateInYesterday(date) ? 1 : date > weekAgo ? 2 : 3
            groups[index].1.append(item)
        }
        return groups.filter { !$0.1.isEmpty }.map { Section(title: $0.0, items: $0.1) }
    }

    func refresh() async {
        cursor = (0, 0, "")
        isEnd = false
        await load(reset: true)
    }

    func loadMore(after item: HistoryItem) async {
        guard item.id == items.last?.id else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading, reset || !isEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await BiliClient.shared.get(.history(max: cursor.max, viewAt: cursor.viewAt, business: cursor.business), as: HistoryPage.self)
            let list = page.list ?? []
            let known = reset ? [] : Set(items.map(\.id))
            let fresh = list.filter { !known.contains($0.id) }
            items = reset ? fresh : items + fresh
            if let next = page.cursor { cursor = (next.max, next.viewAt, next.business) }
            isEnd = list.isEmpty || page.cursor == nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 先从列表移除，失败放回
    func delete(_ item: HistoryItem) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        do {
            try await BiliClient.shared.post(.historyDelete, form: ["kid": item.id, "csrf": csrf])
        } catch {
            items.insert(item, at: min(index, items.count))
            throw error
        }
    }

    func clear() async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        try await BiliClient.shared.post(.historyClear, form: ["csrf": csrf])
        items = []
        isEnd = true
    }
}

/// 历史记录：按日期分组，封面上显示观看进度，左滑删除，可一键清空
struct HistoryView: View {
    @Environment(SessionStore.self) private var session
    @State private var model = HistoryModel()
    @State private var confirmClear = false
    @State private var toast: String?

    var body: some View {
        Group {
            if session.isLoggedIn {
                list
            } else {
                LoginPrompt(message: "登录后查看在各设备上的观看记录")
            }
        }
        .background(Theme.background)
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if session.isLoggedIn, !model.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    do { try await model.clear() } catch { toast = error.localizedDescription }
                }
            }
        } message: {
            Text("所有设备上的观看记录都会被删除")
        }
        .toast($toast)
        .task(id: session.isLoggedIn) {
            if session.isLoggedIn, model.items.isEmpty { await model.refresh() }
        }
    }

    private var list: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        HistoryRow(item: item)
                            .listRowBackground(Theme.background)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        do { try await model.delete(item) } catch { toast = error.localizedDescription }
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .onAppear { Task { await model.loadMore(after: item) } }
                    }
                } header: {
                    Text(section.title)
                        .font(.serif(15))
                        .tracking(1.2)
                        .foregroundStyle(.primary)
                }
            }
            footer
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
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
            ContentUnavailableView("还没有观看记录", systemImage: "clock")
        } else if model.isEnd {
            Text("没有更多了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    @Environment(\.accent) private var accent

    var body: some View {
        VideoLink(card: item.card) {
            HStack(spacing: 12) {
                RemoteImage(url: item.cover, size: CGSize(width: 150, height: 84))
                    .frame(width: 150, height: 84)
                    .overlay(alignment: .bottomTrailing) {
                        Text(item.isFinished ? "已看完" : "\(item.progress.durationText) / \(item.duration.durationText)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                    }
                    .overlay(alignment: .bottom) {
                        // 观看进度条
                        GeometryReader { geo in
                            Capsule().fill(accent).frame(width: geo.size.width * item.progressRatio, height: 2)
                        }
                        .frame(height: 2)
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .videoCover(cornerRadius: 10)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let author = item.authorName, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: item.deviceIcon).imageScale(.small)
                        Text(Date(timeIntervalSince1970: TimeInterval(item.viewAt)), format: .dateTime.hour().minute())
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 84)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }
}

/// 未登录时的占位：说明 + 扫码登录
struct LoginPrompt: View {
    let message: String
    @State private var showLogin = false

    var body: some View {
        ContentUnavailableView {
            Label("尚未登录", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("扫码登录") { showLogin = true }.buttonStyle(.glass)
        }
        .sheet(isPresented: $showLogin) { LoginView() }
    }
}
