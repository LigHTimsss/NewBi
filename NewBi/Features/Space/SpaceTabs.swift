import SwiftUI

// 空间页「动态 / 合集 / 收藏」三个 Tab；都嵌在空间页的外层 ScrollView 里，用 Lazy 容器按需创建

// MARK: - 动态

struct SpaceDynamics: View {
    let model: DynamicModel
    @State private var commentTarget: CommentTarget?
    @State private var viewer: ImageViewerRequest?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                DynamicCard(
                    item: item,
                    model: model,
                    onComment: { commentTarget = CommentTarget(item: item) },
                    onImage: { urls, i in viewer = ImageViewerRequest(urls: urls, index: i) }
                )
                .riseIn(index: index)
                .onAppear { model.loadMore(after: item) }
            }
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("动态加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
                }
            } else if model.items.isEmpty {
                ContentUnavailableView("还没有动态", systemImage: "safari")
            } else if !model.hasMore {
                EndOfList()
            }
        }
        .padding(.horizontal, 16)
        .onAppear { model.loadIfNeeded() }
        .sheet(item: $commentTarget) { DynamicCommentSheet(target: $0) }
        .imageViewer($viewer)
    }
}

// MARK: - 合集

struct SpaceSeasons: View {
    let model: SpaceModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if let seasons = model.seasons {
                if seasons.isEmpty {
                    ContentUnavailableView("还没有合集", systemImage: "square.stack")
                }
                ForEach(Array(seasons.enumerated()), id: \.element.id) { index, season in
                    SeasonSection(season: season, mid: model.mid, owner: model.profile.map { Owner(mid: model.mid, name: $0.card.name, face: $0.card.face) })
                        .riseIn(index: index)
                }
            } else if let error = model.seasonsError {
                ContentUnavailableView {
                    Label("合集加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.loadSeasons(force: true) } }.buttonStyle(.glass)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
        }
        .padding(.horizontal, 16)
        .task { await model.loadSeasons() }
    }
}

/// 一个合集：标题行（点进全部）+ 横向前几个视频
private struct SeasonSection: View {
    let season: SpaceSeason
    let mid: Int
    let owner: Owner?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Route.season(mid: mid, id: season.sourceID, title: season.meta.name, isSeries: season.isSeries)) {
                HStack(spacing: 6) {
                    Image(systemName: season.isSeries ? "list.bullet.rectangle" : "square.stack")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                    Text(season.meta.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let total = season.meta.total {
                        Text("\(total)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(season.archives ?? []) { archive in
                        let card = archive.card(owner: owner)
                        VideoLink(card: card) {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteImage(url: archive.pic, size: CGSize(width: 160, height: 90))
                                    .frame(width: 160, height: 90)
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(archive.duration.durationText)
                                            .font(.system(size: 11, weight: .medium))
                                            .monospacedDigit()
                                            .foregroundStyle(.white)
                                            .shadow(radius: 2)
                                            .padding(5)
                                    }
                                    .clipShape(.rect(cornerRadius: 10))
                                    .videoCover(cornerRadius: 10)
                                Text(archive.title)
                                    .font(.system(size: 13))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                    .frame(width: 160, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .watchLaterMenu(card)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// 合集 / 系列详情：全部视频，按顺序；从这里进入的视频播完按合集顺序连播
@MainActor
@Observable
final class SeasonModel {
    let mid: Int
    let id: Int
    let isSeries: Bool
    private(set) var archives: [SeasonArchive] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var page = 1

    var hasMore: Bool { total.map { archives.count < $0 } ?? true }

    init(mid: Int, id: Int, isSeries: Bool) {
        self.mid = mid
        self.id = id
        self.isSeries = isSeries
    }

    func loadMore(after archive: SeasonArchive? = nil) async {
        if let archive, archive.id != archives.last?.id { return }
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let endpoint: Endpoint = isSeries
                ? .seriesArchives(mid: mid, seriesID: id, page: page)
                : .seasonArchives(mid: mid, seasonID: id, page: page)
            let result = try await BiliClient.shared.get(endpoint, as: SeasonArchivePage.self)
            let known = Set(archives.map(\.id))
            let fresh = (result.archives ?? []).filter { !known.contains($0.id) }
            archives += fresh
            total = fresh.isEmpty ? archives.count : (result.page?.total ?? archives.count)
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SeasonView: View {
    let title: String
    @State private var model: SeasonModel

    init(mid: Int, id: Int, title: String, isSeries: Bool) {
        self.title = title
        _model = State(initialValue: SeasonModel(mid: mid, id: id, isSeries: isSeries))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let total = model.total {
                    Text("共 \(total) 个视频 · 从这里播放会按顺序连播")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(Array(model.archives.enumerated()), id: \.element.id) { index, archive in
                    let card = archive.card(owner: nil)
                    VideoLink(card: card, beforeOpen: { PlayQueue.shared.start(model.archives.map { $0.card(owner: nil) }, title: title) }) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 24, alignment: .trailing)
                                .padding(.top, 2)
                            VideoRow(card: card, subtitle: "\((archive.stat?.view ?? 0).biliCount)播放")
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .watchLaterMenu(card)
                    .riseIn(index: index)
                    .task { await model.loadMore(after: archive) }
                }
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if let error = model.error {
                    ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if !model.hasMore, !model.archives.isEmpty {
                    EndOfList()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { if model.archives.isEmpty { await model.loadMore() } }
    }
}

// MARK: - 收藏

struct SpaceFavorites: View {
    let model: SpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let folders = model.favorites {
                if folders.isEmpty {
                    ContentUnavailableView("没有公开的收藏夹", systemImage: "star")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                        ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                            NavigationLink(value: Route.favoriteFolder(id: folder.id, title: folder.title)) {
                                FolderCard(folder: folder)
                            }
                            .buttonStyle(PressableStyle())
                            .riseIn(index: index)
                        }
                    }
                }
            } else if let error = model.favoritesError {
                ContentUnavailableView {
                    Label("收藏夹加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await model.loadFavorites(force: true) } }.buttonStyle(.glass)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
        }
        .padding(.horizontal, 16)
        .task { await model.loadFavorites() }
    }
}

private struct EndOfList: View {
    var body: some View {
        Text("没有更多了")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(24)
    }
}
