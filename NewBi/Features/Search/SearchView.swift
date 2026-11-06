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
    /// 视频 / UP 主两份结果各自保留：来回切换不重新加载，只在新搜索、改排序或下拉刷新时重来
    var kind: Kind = .video {
        didSet { if kind != oldValue, !started.contains(kind) { startLoad(kind, reset: true) } }
    }
    var order: Order = .totalrank {
        didSet { if order != oldValue { startLoad(.video, reset: true) } }
    }

    private(set) var submitted: String?
    private(set) var suggestions: [String] = []
    private(set) var hot: [HotWord] = []
    private(set) var history: [String]
    private(set) var videos: [SearchVideo] = []
    private(set) var users: [SearchUser] = []
    private var loading: Set<Kind> = []
    private var errors: [Kind: String] = [:]

    func isLoading(_ kind: Kind) -> Bool { loading.contains(kind) }
    func error(for kind: Kind) -> String? { errors[kind] }

    var phase: Phase {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .idle }
        return trimmed == submitted ? .results : .suggesting
    }

    func hasMore(_ kind: Kind) -> Bool { (pages[kind]?.next ?? 1) <= (pages[kind]?.total ?? 1) }

    /// 每种结果各自的分页：下一页页码、总页数
    @ObservationIgnored private var pages: [Kind: (next: Int, total: Int)] = [:]
    /// 这次搜索已经开始加载过的分类
    @ObservationIgnored private var started: Set<Kind> = []
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var loadTasks: [Kind: Task<Void, Never>] = [:]
    private static let historyKey = "searchHistory"
    private static var hotCache: (words: [HotWord], fetchedAt: Date)?
    private static var hotRefresh: Task<[HotWord]?, Never>?

    init() {
        history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
        hot = Self.hotCache?.words ?? []
    }

    func loadHot() async {
        if let cache = Self.hotCache, Date.now.timeIntervalSince(cache.fetchedAt) < 300 {
            hot = cache.words
            return
        }
        // 快速退出再进入时共用请求；页面退出后，成功的响应仍可供下一次使用。
        let refresh = Self.hotRefresh ?? Task { @MainActor () -> [HotWord]? in
            defer { Self.hotRefresh = nil }
            guard let response = try? await BiliClient.shared.get(.searchSquare, as: SearchSquare.self),
                  let words = response.trending?.list else { return nil }
            Self.hotCache = (words, .now)
            return words
        }
        Self.hotRefresh = refresh
        if let words = await refresh.value, !Task.isCancelled { hot = words }
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
        // 新关键词：两份结果都作废，先加载当前分类，另一份切过去时再加载
        started = []
        for kind in Kind.allCases where kind != self.kind { reset(kind) }
        startLoad(kind, reset: true)
    }

    func loadMore(after id: Int, in kind: Kind) {
        guard self.kind == kind else { return }
        let lastID = kind == .video ? videos.last?.id : users.last?.id
        guard id == lastID else { return }
        startLoad(kind, reset: false)
    }

    func isEmpty(_ kind: Kind) -> Bool { kind == .video ? videos.isEmpty : users.isEmpty }

    func retry(_ kind: Kind) {
        startLoad(kind, reset: true)
    }

    /// 下拉刷新当前分类
    func refresh(_ kind: Kind) async {
        startLoad(kind, reset: true)
        await loadTasks[kind]?.value
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

    private func reset(_ kind: Kind) {
        loadTasks[kind]?.cancel()
        loadTasks[kind] = nil
        pages[kind] = nil
        errors[kind] = nil
        loading.remove(kind)
        switch kind {
        case .video: videos = []
        case .user: users = []
        }
    }

    /// 同一分类重新加载会取消它上一次的请求（避免旧结果覆盖新结果）；两个分类互不影响
    private func startLoad(_ kind: Kind, reset: Bool) {
        if reset { self.reset(kind) }
        started.insert(kind)
        let page = pages[kind]?.next ?? 1, total = pages[kind]?.total ?? 1
        guard let keyword = submitted, !loading.contains(kind), page <= total else { return }
        loading.insert(kind)
        let order = order
        loadTasks[kind] = Task {
            do {
                let total: Int
                switch kind {
                case .video:
                    let result = try await BiliClient.shared.get(
                        .search(keyword: keyword, type: "video", page: page, order: order.rawValue),
                        as: SearchResult<SearchVideo>.self
                    )
                    guard !Task.isCancelled else { return }
                    let known = Set(videos.map(\.id))
                    videos += (result.result ?? []).filter { !known.contains($0.id) && !$0.bvid.isEmpty }
                    total = result.numPages ?? 1
                case .user:
                    let result = try await BiliClient.shared.get(
                        .search(keyword: keyword, type: "bili_user", page: page, order: nil),
                        as: SearchResult<SearchUser>.self
                    )
                    guard !Task.isCancelled else { return }
                    let known = Set(users.map(\.id))
                    users += (result.result ?? []).filter { !known.contains($0.id) }
                    total = result.numPages ?? 1
                }
                pages[kind] = (page + 1, total)
                errors[kind] = nil
            } catch {
                guard !Task.isCancelled else { return }
                errors[kind] = error.localizedDescription
            }
            loading.remove(kind)
        }
    }
}

/// 搜索页：从底部搜索按钮进入
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
        .onAppear {
            if model.submitted == nil { focused = true }
        }
        .task { await model.loadHot() }
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
        @Bindable var search = model
        VStack(spacing: 0) {
            header(search: model)
                .padding(.horizontal, 16)
            TabView(selection: $search.kind) {
                ForEach(SearchModel.Kind.allCases, id: \.self) { kind in
                    page(kind).tag(kind)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .transition(.opacity)
    }

    private func page(_ kind: SearchModel.Kind) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                switch kind {
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
                        .onAppear { model.loadMore(after: video.id, in: .video) }
                    }
                case .user:
                    ForEach(Array(model.users.enumerated()), id: \.element.id) { index, user in
                        NavigationLink(value: Route.space(mid: user.mid)) { UserRow(user: user) }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.primary)
                            .onAppear { model.loadMore(after: user.id, in: .user) }
                    }
                }
                footer(for: kind)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        // 下拉只刷新结果（不再触发返回）
        .refreshable { await model.refresh(kind) }
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
    private func footer(for kind: SearchModel.Kind) -> some View {
        let isEmpty = model.isEmpty(kind)
        if model.isLoading(kind) {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let error = model.error(for: kind) {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { model.retry(kind) }.buttonStyle(.glass)
            }
        } else if isEmpty {
            ContentUnavailableView.search(text: model.submitted ?? "")
        } else if !model.hasMore(kind) {
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
