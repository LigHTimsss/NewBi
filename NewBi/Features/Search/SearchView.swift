import SwiftUI

@MainActor
@Observable
final class SearchModel {
    enum Phase {
        case idle, suggesting, results
    }

    enum Kind: String, CaseIterable {
        case video = "视频", bangumi = "番剧", live = "直播", user = "UP主"
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
    private(set) var medias: [SearchMedia] = []
    private(set) var lives: [SearchLive] = []
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
        let lastID = switch kind {
        case .video: videos.last?.id
        case .bangumi: medias.last?.id
        case .live: lives.last?.id
        case .user: users.last?.id
        }
        guard id == lastID else { return }
        startLoad(reset: false)
    }

    var isEmpty: Bool {
        switch kind {
        case .video: videos.isEmpty
        case .bangumi: medias.isEmpty
        case .live: lives.isEmpty
        case .user: users.isEmpty
        }
    }

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
            medias = []
            lives = []
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
                case .bangumi:
                    // 番剧和影视分两个接口，第一页一起查、合并展示
                    async let anime = BiliClient.shared.get(
                        .search(keyword: keyword, type: "media_bangumi", page: page, order: nil), as: SearchResult<SearchMedia>.self
                    )
                    async let film = try? BiliClient.shared.get(
                        .search(keyword: keyword, type: "media_ft", page: page, order: nil), as: SearchResult<SearchMedia>.self
                    )
                    let first = try await anime, second = await film
                    guard !Task.isCancelled else { return }
                    let known = Set(medias.map(\.id))
                    medias += ((first.result ?? []) + (second?.result ?? [])).filter { !known.contains($0.id) }
                    pages = max(first.numPages ?? 1, second?.numPages ?? 1)
                case .live:
                    let result = try await BiliClient.shared.get(
                        .search(keyword: keyword, type: "live_room", page: page, order: nil),
                        as: SearchResult<SearchLive>.self
                    )
                    guard !Task.isCancelled else { return }
                    let known = Set(lives.map(\.id))
                    // 正在直播的排前面
                    let fresh = (result.result ?? []).filter { !known.contains($0.id) }
                    lives += fresh.filter(\.isLive) + fresh.filter { !$0.isLive }
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
                            NavigationLink(value: video.card) {
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
                    case .bangumi:
                        ForEach(Array(model.medias.enumerated()), id: \.element.id) { index, media in
                            MediaRow(media: media, title: BiliHTML.highlighted(media.titleHTML, color: accent.accentText(scheme)))
                                .riseIn(index: index)
                                .onAppear { model.loadMore(after: media.id) }
                        }
                    case .live:
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                            ForEach(Array(model.lives.enumerated()), id: \.element.id) { index, live in
                                LiveCell(live: live, title: BiliHTML.highlighted(live.titleHTML, color: accent.accentText(scheme)))
                                    .riseIn(index: index)
                                    .onAppear { model.loadMore(after: live.id) }
                            }
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
                .frame(maxWidth: 320)
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

/// 番剧 / 影视：竖版封面 + 评分 + 类型地区；暂由 B 站页面播放（会唤起官方 App，未安装时打开网页）
private struct MediaRow: View {
    let media: SearchMedia
    let title: AttributedString
    @Environment(\.openURL) private var openURL
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if let url = media.webURL { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: media.cover, size: CGSize(width: 90, height: 120))
                    .frame(width: 90, height: 120)
                    .overlay(alignment: .topLeading) {
                        Text(media.typeName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(accent.accentFill, in: .rect(cornerRadius: 4))
                            .padding(5)
                    }
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text([media.areas, media.styles].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let score = media.score?.score, score > 0 {
                            Text(score.formatted(.number.precision(.fractionLength(1))))
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(accent.accentText(scheme))
                            if let count = media.score?.userCount {
                                Text("\(count.biliCount)人评").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        Label("外部打开", systemImage: "arrow.up.forward.app")
                            .labelStyle(CompactLabelStyle())
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("在 B 站打开")
    }

    private var meta: String {
        let year = media.pubtime > 0 ? Date(timeIntervalSince1970: TimeInterval(media.pubtime)).formatted(.dateTime.year()) : ""
        let eps = media.episodes > 0 ? "全 \(media.episodes) 话" : ""
        return [year, eps].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 直播间：16:9 封面、在线人数、分区；未开播的变灰
private struct LiveCell: View {
    let live: SearchLive
    let title: AttributedString
    @Environment(\.openURL) private var openURL
    @Environment(\.accent) private var accent

    var body: some View {
        Button {
            if let url = live.webURL { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: live.cover, size: CGSize(width: 180, height: 101))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 3) {
                            if live.isLive {
                                Circle().fill(.white).frame(width: 5, height: 5)
                                    .phaseAnimator([1.0, 0.3]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.8) }
                            }
                            Text(live.isLive ? "直播中" : "未开播")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(live.isLive ? AnyShapeStyle(accent.accentFill) : AnyShapeStyle(.black.opacity(0.5)), in: .capsule)
                        .padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if live.isLive {
                            Label(live.online.biliCount, systemImage: "person.fill")
                                .labelStyle(CompactLabelStyle())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .saturation(live.isLive ? 1 : 0.2)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(live.uname)\(live.area.isEmpty ? "" : " · \(live.area)")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("在 B 站打开直播间")
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
