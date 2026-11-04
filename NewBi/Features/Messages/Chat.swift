import SwiftUI

@MainActor
@Observable
final class ChatModel {
    struct Pending: Identifiable {
        let id = UUID()
        let text: String
        var failed = false
    }

    let peer: ChatPeer
    /// 按时间正序
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [Pending] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var error: String?
    private var loadingOlder = false

    init(peer: ChatPeer) {
        self.peer = peer
    }

    /// 发私信用的设备 id（UUID v4，装机后固定）
    private static var deviceID: String {
        let key = "imDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let fresh = UUID().uuidString.uppercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await BiliClient.shared.get(.chatMessages(talkerID: peer.id, sessionType: peer.sessionType), as: ChatMessagePage.self)
            messages = Self.visible(page.messages)
            hasMore = page.hasMore == 1
            error = nil
        } catch BiliError.emptyData {
            messages = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 滚到顶时取更早的一页
    func loadOlder() async {
        guard hasMore, !loadingOlder, let first = messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let page = try? await BiliClient.shared.get(
            .chatMessages(talkerID: peer.id, sessionType: peer.sessionType, end: first.seqno), as: ChatMessagePage.self
        ) else { return }
        let known = Set(messages.map(\.seqno))
        messages = Self.visible(page.messages).filter { !known.contains($0.seqno) } + messages
        hasMore = page.hasMore == 1
    }

    /// 取比最新一条更新的消息（页面打开时每隔几秒一次）
    func poll() async {
        guard let last = messages.last else {
            await load()
            return
        }
        guard let page = try? await BiliClient.shared.get(
            .chatMessages(talkerID: peer.id, sessionType: peer.sessionType, begin: last.seqno), as: ChatMessagePage.self
        ) else { return }
        let known = Set(messages.map(\.seqno))
        let fresh = Self.visible(page.messages).filter { !known.contains($0.seqno) }
        guard !fresh.isEmpty else { return }
        withAnimation(Motion.component) { messages += fresh }
        await markRead()
    }

    func markRead() async {
        guard let last = messages.last, let csrf = BiliClient.csrfToken else { return }
        try? await BiliClient.shared.post(.chatAck, form: [
            "talker_id": "\(peer.id)", "session_type": "\(peer.sessionType)", "ack_seqno": "\(last.seqno)",
            "csrf": csrf, "csrf_token": csrf, "build": "0", "mobi_app": "web",
        ])
    }

    /// 先在本地显示（发送中），成功后从服务器拉回真正的那条替换掉
    func send(_ text: String, from sender: Int) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "请先登录") }
        let item = Pending(text: text)
        withAnimation(Motion.component) { pending.append(item) }
        let device = Self.deviceID
        do {
            try await BiliClient.shared.post(.chatSend(sender: sender, receiver: peer.id, deviceID: device), form: [
                "msg[sender_uid]": "\(sender)",
                "msg[receiver_id]": "\(peer.id)",
                "msg[receiver_type]": "1",
                "msg[msg_type]": "1",
                "msg[msg_status]": "0",
                "msg[dev_id]": device,
                "msg[timestamp]": "\(Int(Date.now.timeIntervalSince1970))",
                "msg[new_face_version]": "1",
                "msg[content]": ChatMessage.encodeText(text),
                "csrf": csrf, "csrf_token": csrf, "build": "0", "mobi_app": "web",
            ])
            await poll()
            withAnimation(Motion.component) { pending.removeAll { $0.id == item.id } }
        } catch {
            if let index = pending.firstIndex(where: { $0.id == item.id }) { pending[index].failed = true }
            throw error
        }
    }

    func discard(_ item: Pending) {
        withAnimation(Motion.component) { pending.removeAll { $0.id == item.id } }
    }

    private static func visible(_ list: [ChatMessage]?) -> [ChatMessage] {
        (list ?? []).filter { !$0.isRecallCommand }.sorted { $0.seqno < $1.seqno }
    }
}

/// 私信聊天：气泡列表（自己在右、强调色；对方在左、带头像），间隔 5 分钟以上插一行时间；
/// 底部玻璃输入框；系统账号（UP 主小助手等）只能看
struct ChatView: View {
    let peer: ChatPeer
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var toast: String?
    @FocusState private var focused: Bool
    @Environment(SessionStore.self) private var session

    init(peer: ChatPeer) {
        self.peer = peer
        _model = State(initialValue: ChatModel(peer: peer))
    }

    private var myMID: Int? { session.user?.mid }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await model.loadOlder() } }
                }
                ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                    if showsTime(at: index) {
                        Text(message.date.messageTime)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                    ChatBubble(message: message, isMine: message.senderUID == myMID, peer: peer)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                ForEach(model.pending) { item in
                    PendingBubble(item: item) { model.discard(item) }
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        // 打开时停在最下面；往上加载更早的消息时保持当前看到的位置不跳
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.messages.isEmpty, model.pending.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await model.load() } }.buttonStyle(.glass)
                    }
                } else {
                    ContentUnavailableView("打个招呼吧", systemImage: "hand.wave")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !peer.isSystem {
                CommentComposer(text: $draft, placeholder: "发消息…", focused: $focused, onSend: send)
            }
        }
        .background(Theme.background)
        .navigationTitle(peer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !peer.isSystem {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.space(mid: peer.id)) {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("对方空间")
                }
            }
        }
        .toast($toast, bottomPadding: 80)
        .task {
            await model.load()
            await model.markRead()
            // 页面开着时每 5 秒看一眼有没有新消息（离开页面自动停）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.poll()
            }
        }
    }

    private func showsTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return model.messages[index].timestamp - model.messages[index - 1].timestamp > 300
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let me = myMID else { return }
        draft = ""
        Task {
            do {
                try await model.send(text, from: me)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let peer: ChatPeer
    @Environment(\.accent) private var accent
    @Environment(\.openURL) private var openURL

    var body: some View {
        if message.isRecalled {
            Text(isMine ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if isMine { Spacer(minLength: 48) } else { avatar }
                content
                if !isMine { Spacer(minLength: 48) }
            }
        }
    }

    private var avatar: some View {
        RemoteImage(url: peer.face, size: CGSize(width: 34, height: 34))
            .frame(width: 34, height: 34)
            .clipShape(.circle)
    }

    @ViewBuilder
    private var content: some View {
        switch message.body {
        case .text(let text):
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(2)
                .foregroundStyle(isMine ? .white : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(isMine ? AnyShapeStyle(accent.accentFill) : AnyShapeStyle(Theme.card), in: .rect(cornerRadius: 18))
        case .image(let url, let width, let height):
            let ratio = (width ?? 0) > 0 && (height ?? 0) > 0 ? (width ?? 1) / (height ?? 1) : 1
            RemoteImage(url: url, size: CGSize(width: 200, height: 200 / ratio))
                .frame(width: min(200, 200 * ratio), height: min(200 / ratio, 200))
                .clipShape(.rect(cornerRadius: 14))
        case .card(let title, let text, let cover, let link):
            Button { if let link { openURL(link) } } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if let cover {
                        RemoteImage(url: cover, size: CGSize(width: 230, height: 130))
                            .frame(width: 230, height: 130)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        if let text { Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                    }
                    .padding(10)
                }
                .frame(width: 230, alignment: .leading)
                .background(Theme.card)
                .clipShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
        case .notice(let title, let text, let action, let link):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                if let link {
                    Theme.separator.frame(height: 1)
                    Button { openURL(link) } label: {
                        HStack {
                            Text(action ?? "查看详情")
                            Spacer()
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(14)
            .frame(maxWidth: 280, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 16))
        }
    }
}

private struct PendingBubble: View {
    let item: ChatModel.Pending
    var onDiscard: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 48)
            if item.failed {
                Button(action: onDiscard) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .accessibilityLabel("发送失败，点按移除")
            } else {
                ProgressView().controlSize(.small)
            }
            Text(item.text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(accent.accentFill.opacity(0.7), in: .rect(cornerRadius: 18))
        }
    }
}
