import SwiftUI

enum RelationKind: Hashable {
    case followings, followers

    var title: String { self == .followings ? "我的关注" : "我的粉丝" }
    var emptyText: String { self == .followings ? "还没有关注任何人" : "还没有粉丝" }
}

/// 关注 / 粉丝列表：分页加载，每个人的关注状态可以就地改
@MainActor
@Observable
final class RelationListModel {
    let mid: Int
    let kind: RelationKind
    private(set) var users: [RelationUser] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    /// 每个人的关注状态（随列表加载创建，滚动出屏再回来也不丢）
    @ObservationIgnored private var relations: [Int: RelationModel] = [:]
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private static let pageSize = 50

    init(mid: Int, kind: RelationKind) {
        self.mid = mid
        self.kind = kind
    }

    func relation(for user: RelationUser) -> RelationModel {
        relations[user.mid] ?? RelationModel(mid: user.mid)
    }

    /// 他是否关注了我：粉丝列表里都是；关注列表里只有互相关注的是
    func followsMe(_ user: RelationUser) -> Bool {
        kind == .followers || user.isMutual
    }

    func loadIfNeeded() {
        if users.isEmpty, !isLoading { load(reset: true) }
    }

    func refresh() async {
        load(reset: true)
        await loadTask?.value
    }

    func loadMore(after user: RelationUser) {
        guard user.id == users.last?.id else { return }
        load(reset: false)
    }

    func retry() {
        load(reset: users.isEmpty)
    }

    private func load(reset: Bool) {
        if reset {
            loadTask?.cancel()
            page = 0
            hasMore = true
            isLoading = false
        }
        guard !isLoading, hasMore else { return }
        isLoading = true
        let next = page + 1, mid = mid, kind = kind
        loadTask = Task {
            do {
                let endpoint: Endpoint = kind == .followings ? .followings(mid: mid, page: next) : .followers(mid: mid, page: next)
                let result = try await BiliClient.shared.get(endpoint, as: RelationPage.self)
                guard !Task.isCancelled else { return }
                let list = result.list ?? []
                let known = reset ? [] : Set(users.map(\.mid))
                let fresh = list.filter { !known.contains($0.mid) }
                for user in fresh {
                    // 整页重拉时以服务器为准；翻页时已有的保留（可能刚在列表里改过）
                    if reset || relations[user.mid] == nil {
                        let relation = relations[user.mid] ?? RelationModel(mid: user.mid)
                        relation.seed(user.isFollowing)
                        relations[user.mid] = relation
                    }
                }
                users = reset ? fresh : users + fresh
                total = result.total
                page = next
                hasMore = list.count >= Self.pageSize && users.count < (result.total ?? .max)
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// 我的页「关注」「粉丝」：头像、名字、认证或签名，右侧就地关注 / 回关 / 取关；点人进空间
struct RelationListView: View {
    @State private var model: RelationListModel
    @State private var toast: String?
    @Environment(SessionStore.self) private var session

    init(mid: Int, kind: RelationKind) {
        _model = State(initialValue: RelationListModel(mid: mid, kind: kind))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let total = model.total, total > 0 {
                    Text("共 \(total.biliCount) 人")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 10)
                }
                ForEach(model.users) { user in
                    RelationRow(user: user, relation: model.relation(for: user), followsMe: model.followsMe(user), ownList: model.mid == session.mid) { toast = $0 }
                        .onAppear { model.loadMore(after: user) }
                    if user.id != model.users.last?.id {
                        Theme.separator.frame(height: 1).padding(.leading, 58)
                    }
                }
                footer
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await model.refresh() }
        .navigationTitle(model.mid == session.mid ? model.kind.title : (model.kind == .followers ? "粉丝" : "关注"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Theme.background)
        .toast($toast, bottomPadding: 40)
        .task { model.loadIfNeeded() }
        // 列表里关注 / 取关过：回到我的页时数字要对
        .onDisappear { Task { await session.refresh() } }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if let error = model.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { model.retry() }.buttonStyle(.glass)
            }
        } else if model.users.isEmpty {
            ContentUnavailableView(model.kind.emptyText, systemImage: "person.2")
        } else if !model.hasMore {
            Text("没有更多了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }
}

private struct RelationRow: View {
    let user: RelationUser
    let relation: RelationModel
    let followsMe: Bool
    let ownList: Bool
    var onError: (String) -> Void
    @State private var confirmUnfollow = false
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.space(mid: user.mid)) {
                HStack(spacing: 12) {
                    RemoteImage(url: user.face, size: CGSize(width: 46, height: 46))
                        .frame(width: 46, height: 46)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.uname)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(user.isVIP ? accent.accentText(scheme) : .primary)
                            .lineLimit(1)
                        if let subtitle = user.subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            if ownList { relationButton }
        }
        .padding(.vertical, 10)
    }

    /// 已关注：互相关注 / 已关注（灰）；未关注：回关 / 关注（强调色）。取关前二次确认
    private var relationButton: some View {
        let following = relation.isFollowing
        let title = following ? (followsMe ? "互相关注" : "已关注") : (followsMe ? "回关" : "关注")
        return Button {
            if following { confirmUnfollow = true } else { toggle() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(following ? Theme.secondaryText : .white)
                .padding(.horizontal, 14)
                .frame(minWidth: 72)
                .frame(height: 30)
                .background(following ? Theme.selection : accent.accentFill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.component, value: following)
        .sensoryFeedback(.success, trigger: following) { _, new in new }
        .confirmationDialog("确定不再关注 \(user.uname)？", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("不再关注", role: .destructive) { toggle() }
        }
        .accessibilityLabel(title)
    }

    private func toggle() {
        Task {
            do { try await relation.toggle() } catch { onError(error.localizedDescription) }
        }
    }
}
