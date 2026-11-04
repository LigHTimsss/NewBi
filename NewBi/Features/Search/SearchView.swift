import SwiftUI

@MainActor
@Observable
final class SearchModel {
    enum Phase {
        case idle, suggesting, results
    }

    enum Kind: String, CaseIterable {
        case video = "视频", user = "UP主"
    }

    enum Order: String, CaseIterable {
        case totalrank, click, pubdate, dm

        var title: String {
            switch self {
            case .totalrank: "综合"
            case .click: "最多播放"
            case .pubdate: "最新发布"
            case .dm: "最多弹幕"
            }
        }
    }

    var query = ""
    var kind: Kind = .video {
        didSet { if kind != oldValue { startLoad(reset: true) } }
    }
    var order: Order = .totalrank {
        didSet { if order != oldValue { startLoad(reset: true) } }
    }

    private(set) var submitted: String?
    private(set) var suggestions: [String] = []
    private(set) var hot: [HotWord] = []
    private(set) var history: [String]
    private(set) var videos: [SearchVideo] = []
    private(set) var users: [SearchUser] = []
    private(set) var isLoading = false
    private(set) var error: String?

    var phase: Phase {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .idle }
        return trimmed == submitted ? .results : .suggesting
    }

    var hasMore: Bool { page <= pages }

    @ObservationIgnored private var page = 1
    @ObservationIgnored private var pages = 1
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private static let historyKey = "searchHistory"

    init() {
        history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    func loadHot() async {
        guard hot.isEmpty else { return }
        hot = (try? await BiliClient.shared.get(.searchSquare, as: SearchSquare.self).trending?.list) ?? []
    }

    /// 输入变化：200ms 防抖后请求联想词
    func queryChanged() {
        suggestTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard phase == .suggesting else {
            suggestions = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled,
                  let data = try? await BiliClient.shared.data(.searchSuggest(term)),
                  let response = try? JSONDecoder().decode(SuggestResponse.self, from: data),
                  !Task.isCancelled else { return }
            suggestions = response.result?.tag?.map(\.value) ?? []
        }
    }

    func search(_ keyword: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        suggestTask?.cancel()
        query = keyword
        submitted = keyword
        suggestions = []
        remember(keyword)
        startLoad(reset: true)
    }

    func loadMore(after id: Int) {
        let lastID = kind == .video ? videos.last?.id : users.last?.id
        guard id == lastID else { return }
        startLoad(reset: false)
    }

    var isEmpty: Bool { kind == .video ? videos.isEmpty : users.isEmpty }

    func retry() {
        startLoad(reset: true)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    private func remember(_ keyword: String) {
        history.removeAll { $0 == keyword }
        history.insert(keyword, at: 0)
        history = Array(history.prefix(20))
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    /// 切换分类 / 排序会取消上一次请求，避免旧结果覆盖新结果
    private func startLoad(reset: Bool) {
        if reset {
            loadTask?.cancel()
            page = 1
            pages = 1
            videos = []
            users = []
            error = nil
            isLoading = false
        }
        guard let keyword = submitted, !isLoading, page <= pages else { return }
        isLoading = true
        let kind = kind, order = order, page = page
        loadTask = Task {
            do {
                switch kind {
                case .video:
                    let result = try await BiliClient.shared.get(
                        .search(keyword: keyword, type: "video", page: page, order: order.rawValue),
                        as: SearchResult<SearchVideo>.self
                    )
                    guard !Task.isCancelled else { return }
                    let known = Set(videos.map(\.id))
                    videos += (result.result ?? []).filter { !known.contains($0.id) && !$0.bvid.isEmpty }
                    pages = result.numPages ?? 1
                case .user:
                    let result = try await BiliClient.shared.get(
                        .search(keyword: keyword, type: "bili_user", page: page, order: nil),
                        as: SearchResult<SearchUser>.self
                    )
                    guard !Task.isCancelled else { return }
                    let known = Set(users.map(\.id))
                    users += (result.result ?? []).filter { !known.contains($0.id) }
                    pages = result.numPages ?? 1
                }
                self.page = page + 1
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// 搜索页：从底部搜索按钮 zoom 展开
struct SearchView: View {
    @State private var model = SearchModel()
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            switch model.phase {
            case .idle: IdleContent(model: model)
            case .suggesting: suggestionList
            case .results: SearchResults(model: model)
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .animation(Motion.component, value: model.phase)
        .onChange(of: model.query) { model.queryChanged() }
        .task {
            // 等 zoom 转场结束再弹键盘，避免两段动画打架
            try? await Task.sleep(for: .milliseconds(350))
            if model.submitted == nil { focused = true }
            await model.loadHot()
        }
    }

    private var searchBar: some View {
        @Bindable var search = model
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("搜索视频、UP 主", text: $search.query)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { model.search(model.query) }
                    .autocorrectionDisabled()
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityLabel("清除")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(Motion.micro, value: model.query.isEmpty)

            Button("取消") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.suggestions, id: \.self) { word in
                    HStack(spacing: 12) {
                        Button { model.search(word) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.secondaryText)
                                Text(word).font(.system(size: 15)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .foregroundStyle(.primary)
                        // 填入输入框继续编辑
                        Button { model.query = word } label: {
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("填入 \(word)")
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 8)
                    .frame(height: 46)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .transition(.opacity)
    }
}

// MARK: - 搜索前：历史 + 热搜

private struct IdleContent: View {
    let model: SearchModel
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("搜索历史").font(.serif(17)).tracking(1.4)
                            Spacer()
                            Button {
                                withAnimation(Motion.component) { model.clearHistory() }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
                            }
                            .accessibilityLabel("清空搜索历史")
                        }
                        FlowLayout(spacing: 8) {
                            ForEach(model.history, id: \.self) { word in
                                Button { model.search(word) } label: {
                                    Text(word)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .frame(maxWidth: 160)
                                        .padding(.horizontal, 12)
                                        .frame(height: 32)
                                        .background(Theme.card, in: .capsule)
                                }
                                .buttonStyle(PressableStyle())
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                    .transition(.opacity)
                }

                if !model.hot.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("热搜").font(.serif(17)).tracking(1.4)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 4) {
                            ForEach(Array(model.hot.enumerated()), id: \.element) { index, word in
                                Button { model.search(word.keyword) } label: {
                                    HStack(spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 15, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(index < 3 ? accent.accentText(scheme) : Theme.secondaryText)
                                            .frame(width: 18)
                                        Text(word.showName ?? word.keyword)
                                            .font(.system(size: 15))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(height: 40)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(PressableStyle())
                                .foregroundStyle(.primary)
                                .riseIn(index: index)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .transition(.opacity)
    }
}

// MARK: - 结果

private struct SearchResults: View {
    let model: SearchModel
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                Section {
                    switch model.kind {
                    case .video:
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoLink(card: video.card) {
                                VideoRow(
                                    card: video.card,
                                    attributedTitle: BiliHTML.highlighted(video.titleHTML, color: accent.accentText(scheme)),
                                    subtitle: "\(video.author) · \(video.play.biliCount)播放"
                                )
                            }
                            .buttonStyle(PressableStyle())
                            .watchLaterMenu(video.card)
                            .riseIn(index: index)
                            .onAppear { model.loadMore(after: video.id) }
                        }
                    case .user:
                        ForEach(Array(model.users.enumerated()), id: \.element.id) { index, user in
                            NavigationLink(value: Route.space(mid: user.mid)) { UserRow(user: user) }
                                .buttonStyle(PressableStyle())
                                .foregroundStyle(.primary)
                                .riseIn(index: index)
                                .onAppear { model.loadMore(after: user.id) }
                        }
                    }
                    footer
                } header: {
                    header(search: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .transition(.opacity)
    }

    private func header(search: SearchModel) -> some View {
        @Bindable var search = search
        return VStack(spacing: 10) {
            GlassSegmented(options: SearchModel.Kind.allCases, selection: $search.kind, title: \.rawValue)
                .frame(maxWidth: 220)
            if model.kind == .video {
                HStack(spacing: 4) {
                    ForEach(SearchModel.Order.allCases, id: \.self) { order in
                        let on = order == model.order
                        Button {
                            withAnimation(Motion.component) { search.order = order }
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
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder
    private var footer: some View {
        let isEmpty = model.isEmpty
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let error = model.error {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { model.retry() }.buttonStyle(.glass)
            }
        } else if isEmpty {
            ContentUnavailableView.search(text: model.submitted ?? "")
        } else if !model.hasMore {
            Text("没有更多了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}

private struct UserRow: View {
    let user: SearchUser

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: user.upic, size: CGSize(width: 48, height: 48))
                .frame(width: 48, height: 48)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.uname).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    LevelBadge(level: user.level)
                }
                Text("\(user.fans.biliCount)粉丝 · \(user.videos)个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                if !user.usign.isEmpty {
                    Text(user.usign)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
