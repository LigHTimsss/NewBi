import SwiftUI

// MARK: - 未读数（首页右上角信封上的红点）

@MainActor
@Observable
final class MessageBadge {
    static let shared = MessageBadge()

    private(set) var counts: [NoticeKind: Int] = [:]
    private(set) var chat = 0

    var total: Int { counts.values.reduce(0, +) + chat }

    func count(_ kind: NoticeKind) -> Int { counts[kind] ?? 0 }

    /// 两个轻量请求，并发发出；未登录直接清零
    func check(loggedIn: Bool) async {
        guard loggedIn else {
            counts = [:]
            chat = 0
            return
        }
        async let feed = try? BiliClient.shared.get(.msgUnread, as: MsgUnread.self)
        async let dm = try? BiliClient.shared.get(.dmUnread, as: DMUnread.self)
        let (unread, direct) = await (feed, dm)
        withAnimation(Motion.component) {
            if let unread {
                counts = [
                    .reply: unread.reply ?? 0, .at: unread.at ?? 0,
                    .like: unread.like ?? 0, .system: unread.sysMsg ?? 0,
                ]
            }
            if let direct { chat = direct.total }
        }
    }

    func clear(_ kind: NoticeKind) {
        withAnimation(Motion.component) { counts[kind] = 0 }
    }

    func readChat(_ count: Int) {
        withAnimation(Motion.component) { chat = max(chat - count, 0) }
    }
}

// MARK: - 私信会话列表

@MainActor
@Observable
final class ChatSessionsModel {
    struct Row: Identifiable {
        let session: ChatSession
        let name: String
        let face: String?
        var unread: Int

        var id: String { session.id }
        var peer: ChatPeer {
            ChatPeer(id: session.talkerID, name: name, face: face, sessionType: session.sessionType, isSystem: session.isSystem)
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasMore = false
    private var profiles: [Int: UserCardLite] = [:]

    func refresh() async { await load(reset: true) }

    func loadMore(after row: Row) async {
        guard row.id == rows.last?.id, hasMore else { return }
        await load(reset: false)
    }

    func markRead(_ row: Row) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index].unread = 0
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await BiliClient.shared.get(.chatSessions(endTs: reset ? nil : rows.last?.session.sessionTs), as: ChatSessionList.self)
            // 只要和人 / 系统账号的单聊；粉丝团群聊不做
            let sessions = (page.sessionList ?? []).filter { $0.sessionType == 1 && $0.talkerID > 0 }
            let unknown = sessions.filter { !$0.isSystem && profiles[$0.talkerID] == nil }.map(\.talkerID)
            if !unknown.isEmpty, let cards = try? await BiliClient.shared.get(.userCards(unknown), as: [UserCardLite].self) {
                for card in cards { profiles[card.mid] = card }
            }
            let fresh = sessions.map(makeRow)
            if reset {
                rows = fresh
            } else {
                let known = Set(rows.map(\.id))
                rows += fresh.filter { !known.contains($0.id) }
            }
            hasMore = page.hasMore == 1 && !fresh.isEmpty
            error = nil
        } catch BiliError.emptyData {
            if reset { rows = [] }
            hasMore = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeRow(_ session: ChatSession) -> Row {
        let name: String
        let face: String?
        if let info = session.accountInfo, let title = info.name, !title.isEmpty {
            name = title
            face = info.picURL
        } else if let card = profiles[session.talkerID] {
            name = card.name
            face = card.face
        } else {
            name = "用户 \(session.talkerID)"
            face = nil
        }
        return Row(session: session, name: name, face: face, unread: session.unreadCount ?? 0)
    }
}

// MARK: - 消息中心

/// 仿官方客户端：上面四个入口（回复我的 / @ 我的 / 收到的赞 / 系统通知，带未读数），下面是私信会话列表
struct MessageCenterView: View {
    @Environment(SessionStore.self) private var session
    @State private var model = ChatSessionsModel()

    var body: some View {
        Group {
            if session.isLoggedIn {
                content
            } else {
                LoginPrompt(message: "登录后查看回复、@、点赞和私信")
            }
        }
        .background(Theme.background)
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: session.isLoggedIn) {
            guard session.isLoggedIn else { return }
            if model.rows.isEmpty { await model.refresh() }
            await MessageBadge.shared.check(loggedIn: true)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                entries
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("私信").font(.serif(17)).tracking(1.4)
                    if MessageBadge.shared.chat > 0 {
                        Text("\(MessageBadge.shared.chat) 条未读")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 4)
                sessions
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable {
            await model.refresh()
            await MessageBadge.shared.check(loggedIn: true)
        }
    }

    private var entries: some View {
        HStack(spacing: 0) {
            ForEach(NoticeKind.allCases) { kind in
                NavigationLink(value: Route.notices(kind)) {
                    NoticeEntry(kind: kind, count: MessageBadge.shared.count(kind))
                }
                .buttonStyle(PressableStyle())
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 16)
        .background(Theme.card, in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var sessions: some View {
        if model.rows.isEmpty {
            Group {
                if model.isLoading {
                    ProgressView()
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
                    }
                } else {
                    ContentUnavailableView("还没有私信", systemImage: "envelope.open")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    NavigationLink(value: Route.chat(row.peer)) {
                        SessionRow(row: row)
                    }
                    .buttonStyle(PressableStyle())
                    .simultaneousGesture(TapGesture().onEnded {
                        MessageBadge.shared.readChat(row.unread)
                        model.markRead(row)
                    })
                    .riseIn(index: index)
                    .onAppear { Task { await model.loadMore(after: row) } }
                    if index < model.rows.count - 1 {
                        Theme.separator.frame(height: 1).padding(.leading, 76)
                    }
                }
            }
            .background(Theme.card, in: .rect(cornerRadius: 22))
        }
    }
}

private struct NoticeEntry: View {
    let kind: NoticeKind
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(kind.tint.gradient, in: .circle)
                .shadow(color: kind.tint.opacity(0.35), radius: 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    UnreadBadge(count: count).offset(x: 6, y: -4)
                }
            Text(kind.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(count > 0 ? "\(count) 条未读" : "")
    }
}

extension NoticeKind {
    var tint: Color {
        switch self {
        case .reply: Color(red: 0.25, green: 0.6, blue: 1)
        case .at: Color(red: 0.16, green: 0.74, blue: 0.56)
        case .like: Color(red: 1, green: 0.38, blue: 0.55)
        case .system: Color(red: 1, green: 0.62, blue: 0.2)
        }
    }
}

private struct SessionRow: View {
    let row: ChatSessionsModel.Row

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: row.face, size: CGSize(width: 48, height: 48))
                .frame(width: 48, height: 48)
                .clipShape(.circle)
                .overlay(alignment: .bottomTrailing) {
                    if row.session.isSystem {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .blue)
                            .background(Theme.card, in: .circle)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if row.session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if let date = row.session.date {
                        Text(date.messageTime)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                HStack(spacing: 6) {
                    Text(row.session.lastMsg?.preview ?? " ")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    UnreadBadge(count: row.unread)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .animation(Motion.component, value: row.unread)
    }
}

// MARK: - 回复我的 / @ 我的 / 收到的赞 / 系统通知

@MainActor
@Observable
final class NoticeListModel {
    let kind: NoticeKind
    private(set) var items: [Notice] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private var cursor: NoticeCursor?
    private var systemCursor: Int?
    private var reachedEnd = false

    init(kind: NoticeKind) {
        self.kind = kind
    }

    func refresh() async {
        cursor = nil
        systemCursor = nil
        reachedEnd = false
        await load(reset: true)
    }

    func loadMore(after notice: Notice) async {
        guard notice.id == items.last?.id, !reachedEnd else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh: [Notice]
            let client = BiliClient.shared
            let id = reset ? nil : cursor?.id
            let time = reset ? nil : cursor?.time
            switch kind {
            case .reply, .at:
                let page = try await client.get(.notices(kind, cursorID: id, cursorTime: time), as: InteractionPage.self)
                fresh = (page.items ?? []).map { kind == .reply ? Notice(reply: $0) : Notice(at: $0) }
                cursor = page.cursor
                reachedEnd = page.cursor?.isEnd ?? true
            case .like:
                let page = try await client.get(.notices(.like, cursorID: id, cursorTime: time), as: LikePage.self)
                fresh = (page.total?.items ?? []).map(Notice.init(like:))
                cursor = page.total?.cursor
                reachedEnd = page.total?.cursor?.isEnd ?? true
            case .system:
                guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
                let endpoint: Endpoint = reset || systemCursor == nil
                    ? .systemNotices(csrf: csrf)
                    : .systemNoticesMore(csrf: csrf, cursor: systemCursor ?? 0)
                let page = try await client.get(endpoint, as: SystemNoticePage.self)
                fresh = page.items.map(Notice.init(system:))
                systemCursor = page.items.last.map { $0.cursor ?? $0.id }
                reachedEnd = page.items.isEmpty
                // 首页看过即标为已读（尽力而为）
                if reset, let newest = page.items.first {
                    _ = try? await client.data(.systemNoticesRead(csrf: csrf, cursor: newest.cursor ?? newest.id))
                }
            }
            if reset {
                items = fresh
            } else {
                let known = Set(items.map(\.id))
                items += fresh.filter { !known.contains($0.id) }
            }
            error = nil
        } catch BiliError.emptyData {
            if reset { items = [] }
            reachedEnd = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct NoticeListView: View {
    let kind: NoticeKind
    @State private var model: NoticeListModel
    @Environment(SessionStore.self) private var session

    init(kind: NoticeKind) {
        self.kind = kind
        _model = State(initialValue: NoticeListModel(kind: kind))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, notice in
                    Group {
                        if kind == .system {
                            SystemNoticeRow(notice: notice)
                        } else {
                            NoticeRow(notice: notice)
                        }
                    }
                    .riseIn(index: index)
                    .onAppear { Task { await model.loadMore(after: notice) } }
                    Theme.separator.frame(height: 1).padding(.leading, kind == .system ? 16 : 68)
                }
                if model.isLoading, !model.items.isEmpty {
                    ProgressView().padding()
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if model.items.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await model.refresh() } }.buttonStyle(.glass)
                    }
                } else {
                    ContentUnavailableView("暂时没有\(kind.title)", systemImage: kind.icon)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            guard session.isLoggedIn, model.items.isEmpty else { return }
            await model.refresh()
            MessageBadge.shared.clear(kind)
        }
    }
}

/// 一条互动通知：头像 · 谁做了什么 · 对方的话 · 被互动的我的内容（灰底引用）· 时间 · 右侧封面
private struct NoticeRow: View {
    let notice: Notice
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatars
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text(names).font(.system(size: 14, weight: .semibold))) \(Text(notice.action).font(.system(size: 13)).foregroundStyle(Theme.secondaryText))")
                    .lineLimit(2)
                if let content = notice.content {
                    Text(content)
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .lineLimit(5)
                }
                if let quote = notice.quote {
                    Text(quote)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: .rect(cornerRadius: 10))
                }
                if let date = notice.date {
                    Text(date.messageTime)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let image = notice.image {
                RemoteImage(url: image, size: CGSize(width: 56, height: 56))
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .onTapGesture { if let link = notice.link { openURL(link) } }
    }

    private var names: String {
        let shown = notice.users.prefix(2).map(\.nickname).joined(separator: "、")
        return shown.isEmpty ? "有人" : shown
    }

    /// 单人一个头像；多人时两个头像错叠
    private var avatars: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Array(notice.users.prefix(2).enumerated()).reversed()), id: \.element.mid) { index, user in
                NavigationLink(value: Route.space(mid: user.mid)) {
                    RemoteImage(url: user.avatar, size: CGSize(width: 40, height: 40))
                        .frame(width: index == 0 ? 40 : 28, height: index == 0 ? 40 : 28)
                        .clipShape(.circle)
                        .overlay { Circle().strokeBorder(Theme.background, lineWidth: index == 0 ? 0 : 2) }
                }
                .buttonStyle(PressableStyle())
                .offset(x: index == 0 ? 0 : 18, y: index == 0 ? 0 : 20)
            }
        }
        .frame(width: 40, height: 40, alignment: .topLeading)
    }
}

private struct SystemNoticeRow: View {
    let notice: Notice
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(notice.title ?? "系统通知")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let date = notice.date {
                    Text(date.messageTime)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if let content = notice.content {
                Text(Self.render(content, link: accent))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 正文里的链接写成 `#{文字}{"网址"}`，换成可点的链接
    static func render(_ content: String, link color: Color) -> AttributedString {
        var result = AttributedString()
        var rest = content[...]
        while let match = rest.firstMatch(of: /#\{([^}]*)\}\{"([^"]*)"\}/) {
            result += AttributedString(String(rest[..<match.range.lowerBound]))
            var piece = AttributedString(String(match.output.1))
            if let url = AppLink.web(String(match.output.2)) {
                piece.link = url
                piece.foregroundColor = color
            }
            result += piece
            rest = rest[match.range.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }
}

extension Date {
    /// 今天 → 14:05 · 昨天 → 昨天 14:05 · 今年 → 3月2日 · 更早 → 2024/3/2
    var messageTime: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "昨天 " + formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month().day())
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
