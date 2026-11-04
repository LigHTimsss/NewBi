import SwiftUI

@MainActor
@Observable
final class FavoritesModel {
    private(set) var folders: [FavFolder] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    @ObservationIgnored private var page = 1

    func refresh(mid: Int) async {
        page = 1
        hasMore = true
        await load(mid: mid, reset: true)
    }

    func loadMore(mid: Int, after folder: FavFolder) async {
        guard folder.id == folders.last?.id else { return }
        await load(mid: mid, reset: false)
    }

    private func load(mid: Int, reset: Bool) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await BiliClient.shared.get(.favFolders(mid: mid, page: page), as: FavFolderPage.self)
            let list = result.list ?? []
            folders = reset ? list : folders + list.filter { new in !folders.contains { $0.id == new.id } }
            hasMore = result.hasMore ?? false
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 我的收藏：收藏夹两列网格
struct FavoritesView: View {
    @Environment(SessionStore.self) private var session
    @State private var model = FavoritesModel()
    @State private var editing: FolderEditTarget?
    @State private var deleting: FavFolder?
    @State private var toast: String?

    /// 新建（nil）或编辑某个收藏夹
    private struct FolderEditTarget: Identifiable {
        let folder: FavFolder?
        var id: Int { folder?.id ?? 0 }
    }

    var body: some View {
        Group {
            if session.isLoggedIn, let mid = session.user?.mid {
                grid(mid: mid)
            } else {
                LoginPrompt(message: "登录后查看你的收藏夹")
            }
        }
        .background(Theme.background)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if session.isLoggedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = FolderEditTarget(folder: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建收藏夹")
                }
            }
        }
        .sheet(item: $editing) { target in
            FolderEditor(folder: target.folder) { _ in
                toast = target.folder == nil ? "已新建收藏夹" : "已保存"
                reload()
            }
        }
        .confirmationDialog("删除收藏夹「\(deleting?.title ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let folder = deleting else { return }
                Task {
                    do {
                        try await FavFolders.delete(id: folder.id)
                        toast = "已删除"
                        reload()
                    } catch {
                        toast = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("收藏夹里的内容会一起移除，不能恢复")
        }
        .toast($toast)
        .task(id: session.user?.mid) {
            if let mid = session.user?.mid, model.folders.isEmpty { await model.refresh(mid: mid) }
        }
    }

    private func reload() {
        guard let mid = session.user?.mid else { return }
        Task { await model.refresh(mid: mid) }
    }

    private func grid(mid: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                ForEach(Array(model.folders.enumerated()), id: \.element.id) { index, folder in
                    NavigationLink(value: Route.favoriteFolder(id: folder.id, title: folder.title)) {
                        FolderCard(folder: folder)
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        Button { editing = FolderEditTarget(folder: folder) } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        if !folder.isDefault {
                            Button(role: .destructive) { deleting = folder } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .riseIn(index: index)
                    .onAppear { Task { await model.loadMore(mid: mid, after: folder) } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if model.isLoading {
                ProgressView().padding()
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.refresh(mid: mid) } }.buttonStyle(.glass)
                }
            } else if model.folders.isEmpty {
                ContentUnavailableView("还没有收藏夹", systemImage: "star")
            }
        }
        .refreshable { await model.refresh(mid: mid) }
    }
}

struct FolderCard: View {
    let folder: FavFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let cover = folder.cover, !cover.isEmpty {
                    RemoteImage(url: cover, size: CGSize(width: 194, height: 121))
                } else {
                    // 空收藏夹没有封面
                    Theme.card.overlay {
                        Image(systemName: "star").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Label("\(folder.mediaCount)", systemImage: "play.rectangle.on.rectangle")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .glassEffect(.clear, in: .capsule)
                    .padding(6)
            }
            .clipShape(.rect(cornerRadius: 12))

            HStack(spacing: 4) {
                if folder.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("私密")
                }
                Text(folder.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            Text("\(folder.mediaCount) 个内容")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - 收藏夹详情

@MainActor
@Observable
final class FolderModel {
    enum Order: String, CaseIterable {
        case mtime, view, pubtime

        var title: String {
            switch self {
            case .mtime: "最近收藏"
            case .view: "最多播放"
            case .pubtime: "最新投稿"
            }
        }
    }

    let id: Int
    private(set) var medias: [FavMedia] = []
    private(set) var count: Int?
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    var order: Order = .mtime {
        didSet { if order != oldValue { Task { await refresh() } } }
    }
    @ObservationIgnored private var page = 1

    init(id: Int) {
        self.id = id
    }

    func refresh() async {
        page = 1
        hasMore = true
        medias = []
        await load()
    }

    func loadMore(after media: FavMedia) async {
        guard media.id == medias.last?.id else { return }
        await load()
    }

    private func load() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        let order = order
        do {
            let result = try await BiliClient.shared.get(.favResources(mediaID: id, page: page, order: order.rawValue), as: FavResourcePage.self)
            // 请求期间切换了排序：丢弃旧结果，按新排序重新加载
            guard order == self.order else {
                Task { await self.load() }
                return
            }
            let known = Set(medias.map(\.id))
            medias += (result.medias ?? []).filter { !known.contains($0.id) }
            count = result.info?.mediaCount ?? count
            hasMore = result.hasMore
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 取消收藏：先移除，失败放回
    func remove(_ media: FavMedia) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        guard let index = medias.firstIndex(where: { $0.id == media.id }) else { return }
        medias.remove(at: index)
        count = count.map { $0 - 1 }
        do {
            try await BiliClient.shared.post(.favDeal, form: [
                "rid": "\(media.id)", "type": "2", "add_media_ids": "", "del_media_ids": "\(id)", "csrf": csrf,
            ])
        } catch {
            medias.insert(media, at: min(index, medias.count))
            count = count.map { $0 + 1 }
            throw error
        }
    }
}

struct FolderView: View {
    let title: String
    @State private var model: FolderModel
    @State private var toast: String?
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    init(id: Int, title: String) {
        self.title = title
        _model = State(initialValue: FolderModel(id: id))
    }

    var body: some View {
        @Bindable var folder = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.serif(22)).tracking(1.6).lineLimit(1)
                    if let count = model.count {
                        Text("\(count) 个内容")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.top, 4)

                HStack(spacing: 4) {
                    ForEach(FolderModel.Order.allCases, id: \.self) { order in
                        let on = order == model.order
                        Button {
                            withAnimation(Motion.component) { folder.order = order }
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
                }

                ForEach(Array(model.medias.enumerated()), id: \.element.id) { index, media in
                    row(media)
                        .riseIn(index: index)
                        .onAppear { Task { await model.loadMore(after: media) } }
                }

                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if let error = model.error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if model.medias.isEmpty {
                    ContentUnavailableView("收藏夹是空的", systemImage: "star")
                } else if !model.hasMore {
                    Text("没有更多了")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toast($toast)
        .refreshable { await model.refresh() }
        .task { if model.medias.isEmpty { await model.refresh() } }
    }

    @ViewBuilder
    private func row(_ media: FavMedia) -> some View {
        let subtitle = "\(media.upper?.name ?? "") · \((media.cntInfo?.play ?? 0).biliCount)播放"
        if media.isInvalid {
            // 已失效：不可点，长按可移除
            VideoRow(card: media.card, subtitle: "视频已失效")
                .opacity(0.4)
                .contextMenu { removeButton(media) }
        } else {
            NavigationLink(value: media.card) { VideoRow(card: media.card, subtitle: subtitle) }
                .buttonStyle(PressableStyle())
                .zoomSource(media.card)
                .contextMenu { removeButton(media) }
        }
    }

    private func removeButton(_ media: FavMedia) -> some View {
        Button(role: .destructive) {
            Task {
                do {
                    try await model.remove(media)
                    toast = "已取消收藏"
                } catch {
                    toast = error.localizedDescription
                }
            }
        } label: {
            Label("取消收藏", systemImage: "star.slash")
        }
    }
}
