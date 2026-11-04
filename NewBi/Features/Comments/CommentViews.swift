import SwiftUI

/// 详情页「评论」Tab；也用于动态的评论面板
struct CommentSection: View {
    let model: CommentModel
    /// 半屏面板里不跳空间页（面板内没有对应的导航目标）
    var linksToSpace = true
    @State private var draft = ""
    @State private var replyTarget: Reply?
    @State private var thread: Reply?
    @State private var toast: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                ForEach(model.top) { reply in
                    row(reply, isTop: true)
                }
                ForEach(Array(model.replies.enumerated()), id: \.element.id) { index, reply in
                    row(reply)
                        .riseIn(index: index)
                        .onAppear { model.loadMore(after: reply) }
                }
                footer
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            CommentComposer(
                text: $draft,
                placeholder: replyTarget.map { "回复 @\($0.member.uname)：" } ?? "发一条友善的评论",
                focused: $focused,
                onSend: send
            )
        }
        .toast($toast, bottomPadding: 80)
        .task { model.loadIfNeeded() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, draft.isEmpty { replyTarget = nil }
        }
        .sheet(item: $thread) { root in
            ReplyThreadView(model: model, root: root)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("评论").font(.serif(17)).tracking(1.4)
            if let total = model.total {
                Text(total.biliCount)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                withAnimation(Motion.component) { model.toggleSort() }
            } label: {
                Label(model.sort.title, systemImage: "arrow.up.arrow.down")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.interpolate)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.selection, in: .capsule)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ reply: Reply, isTop: Bool = false) -> some View {
        CommentRow(
            reply: reply,
            model: model,
            isTop: isTop,
            linksToSpace: linksToSpace,
            onReply: { target in
                replyTarget = target
                focused = true
            },
            onOpenThread: { thread = $0 },
            onError: { toast = $0 }
        )
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if let error = model.error {
            ContentUnavailableView {
                Label("评论加载失败", systemImage: "text.bubble")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.reload() } }.buttonStyle(.glass)
            }
        } else if model.replies.isEmpty, model.top.isEmpty {
            ContentUnavailableView("还没有评论", systemImage: "text.bubble", description: Text("来抢沙发吧"))
        } else if model.isEnd {
            Text("没有更多评论了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = replyTarget
        Task {
            do {
                try await model.send(text, root: target)
                draft = ""
                replyTarget = nil
                focused = false
                toast = target == nil ? "评论成功" : "回复成功"
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}

// MARK: - 单条评论

struct CommentRow: View {
    let reply: Reply
    let model: CommentModel
    var isTop = false
    /// 楼中楼预览框（评论详情页里不显示）
    var showsPreview = true
    /// 点头像进 UP 主空间（半屏的评论详情里不跳转）
    var linksToSpace = true
    var onReply: (Reply) -> Void
    var onOpenThread: (Reply) -> Void
    var onError: (String) -> Void
    @State private var viewer: ImageViewerRequest?
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let liked = model.isLiked(reply)
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(reply.member.uname)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(reply.isVIP ? accent.accentText(scheme) : Theme.secondaryText)
                        .lineLimit(1)
                    if let level = reply.member.levelInfo?.currentLevel {
                        LevelBadge(level: level)
                    }
                    if isTop {
                        Text("置顶")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent.accentText(scheme))
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .overlay { RoundedRectangle(cornerRadius: 4).stroke(accent.accentText(scheme), lineWidth: 1) }
                    }
                }

                RichText(reply.content.message, emotes: reply.content.emoteURLs)
                    .textSelection(.enabled)

                if let pictures = reply.content.pictures, !pictures.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(pictures.prefix(3).enumerated()), id: \.element.imgSrc) { index, picture in
                            Button {
                                viewer = ImageViewerRequest(urls: pictures.map(\.imgSrc), index: index)
                            } label: {
                                RemoteImage(url: picture.imgSrc, size: CGSize(width: 96, height: 96))
                                    .frame(width: 96, height: 96)
                                    .clipShape(.rect(cornerRadius: 8))
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("查看图片 \(index + 1)")
                        }
                    }
                    .imageViewer($viewer)
                }

                HStack(spacing: 18) {
                    Text(reply.metaText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    Button {
                        Task {
                            do { try await model.toggleLike(reply) } catch { onError(error.localizedDescription) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .symbolEffect(.bounce, value: liked)
                                .contentTransition(.symbolEffect(.replace))
                            let count = model.likeCount(reply)
                            if count > 0 {
                                Text(count.biliCount).contentTransition(.numericText())
                            }
                        }
                        .foregroundStyle(liked ? accent.accentText(scheme) : Theme.secondaryText)
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(liked ? "取消点赞" : "点赞")
                    .sensoryFeedback(.impact(weight: .light), trigger: liked)

                    Button { onReply(reply) } label: {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minWidth: 32, minHeight: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("回复")
                }
                .font(.system(size: 13))
                .animation(Motion.component, value: liked)

                if showsPreview, reply.rcount > 0 || reply.replies?.isEmpty == false {
                    threadPreview(reply.replies ?? [])
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Theme.separator.frame(height: 0.5).padding(.leading, 64)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let image = RemoteImage(url: reply.member.avatar, size: CGSize(width: 36, height: 36))
            .frame(width: 36, height: 36)
            .clipShape(.circle)
        if linksToSpace, let mid = reply.member.midValue {
            NavigationLink(value: Route.space(mid: mid)) { image }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(reply.member.uname) 的空间")
        } else {
            image
        }
    }

    private func threadPreview(_ previews: [Reply]) -> some View {
        Button { onOpenThread(reply) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(previews.prefix(2)) { sub in
                    Text("\(Text(sub.member.uname).foregroundStyle(accent.accentText(scheme)))：\(sub.content.message)")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if reply.rcount > previews.prefix(2).count {
                    HStack(spacing: 2) {
                        Text(reply.replyControl?.subReplyEntryText ?? "共\(reply.rcount)条回复")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(accent.accentText(scheme))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 输入栏

struct CommentComposer: View {
    @Binding var text: String
    var placeholder: String
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void
    @Environment(\.accent) private var accent

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .focused(focused)
                .padding(.vertical, 11)
            if canSend {
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(accent.accentFill, in: .circle)
                }
                .buttonStyle(PressableStyle())
                .padding(.bottom, 3)
                .accessibilityLabel("发送")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 4)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(Motion.component, value: canSend)
    }
}

// MARK: - 评论详情（楼中楼）

struct ReplyThreadView: View {
    let model: CommentModel
    @State private var thread: ReplyThreadModel
    @State private var draft = ""
    @State private var target: Reply?
    @State private var toast: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: CommentModel, root: Reply) {
        self.model = model
        _thread = State(initialValue: ReplyThreadModel(oid: model.oid, type: model.type, root: root))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(thread.root)
                    Theme.card.frame(height: 8)
                    Text("相关回复共 \(thread.total ?? thread.root.rcount) 条")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    ForEach(Array(thread.replies.enumerated()), id: \.element.id) { index, reply in
                        row(reply)
                            .riseIn(index: index)
                            .onAppear {
                                if reply.id == thread.replies.last?.id { Task { await thread.loadMore() } }
                            }
                    }
                    if thread.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    } else if let error = thread.error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("评论详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                CommentComposer(
                    text: $draft,
                    placeholder: "回复 @\((target ?? thread.root).member.uname)：",
                    focused: $focused,
                    onSend: send
                )
            }
            .toast($toast, bottomPadding: 80)
            .task { await thread.loadMore() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ reply: Reply) -> some View {
        CommentRow(
            reply: reply,
            model: model,
            showsPreview: false,
            linksToSpace: false,
            onReply: { reply in
                target = reply.id == thread.root.id ? nil : reply
                focused = true
            },
            onOpenThread: { _ in },
            onError: { toast = $0 }
        )
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parent = target
        Task {
            do {
                if let reply = try await model.send(text, root: thread.root, parent: parent) {
                    withAnimation(Motion.component) { thread.append(reply) }
                }
                draft = ""
                target = nil
                focused = false
                toast = "回复成功"
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
