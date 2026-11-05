import SwiftUI

enum PlayerPanel: Hashable {
    case danmaku, quality, speed, more, parts
    /// 评论：右侧浮起的小窗，不退出全屏
    case comments
}

enum GestureHUD: Equatable {
    case seek(to: Double, duration: Double)
    case brightness(Double)
    case volume(Double)
    case boost(Float)

    var isBoost: Bool {
        if case .boost = self { true } else { false }
    }
}

private enum PanMode {
    case seek(from: Double)
    case brightness(from: CGFloat)
    case volume(from: Float)
}

/// 「播放器 · 横屏全屏」画板：控件层、手势层、锁屏、右侧玻璃抽屉
struct FullscreenOverlay: View {
    let model: VideoDetailModel
    @Binding var locked: Bool
    var onExit: () -> Void
    /// 点左上角 UP 主：退出全屏后进他的空间
    var onUploader: (Int) -> Void
    var onFavorite: () -> Void

    @State private var showControls = true
    @State private var panel: PlayerPanel?
    @State private var hud: GestureHUD?
    @State private var pan: PanMode?
    @State private var hideTask: Task<Void, Never>?
    @State private var message = ""
    @State private var toast: String?
    /// 横屏为 compact；竖屏视频的竖屏全屏为 regular
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var inputFocused: Bool
    /// 长按临时 2 倍速：按住中，松手恢复原速
    @GestureState private var hold = Hold()
    @Environment(\.accent) private var accent

    private var player: PlayerController { model.player }

    var body: some View {
        ZStack {
            gestureLayer

            if showControls && !locked {
                chrome.transition(.opacity)
            }

            if showControls {
                lockButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }

            if let hud {
                HUDView(hud: hud)
                    .frame(maxHeight: .infinity, alignment: hud.isBoost ? .top : .center)
                    .padding(.top, hud.isBoost ? 16 : 0)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if panel != nil {
                // 点击抽屉外关闭（透明，不跟着滑）
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { closePanel() }
                    .accessibilityLabel("关闭面板")
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let panel {
                    Group {
                        if panel == .comments {
                            CommentsPanel(model: model.comments) { closePanel() }
                        } else {
                            PlayerDrawer(panel: panel, controller: player, model: model) { closePanel(then: $0) }
                        }
                    }
                    // 评论浮窗宽度可伸缩：先占满它要的宽度，剩下的才给左边的空白
                    .layoutPriority(1)
                    // 只按抽屉自己的宽度滑进滑出：以前连同整屏宽的透明层一起平移，
                    // 横屏下位移是抽屉宽度的两倍多，同样 420ms 走完显得一顿一顿
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(Motion.micro, value: showControls)
        .animation(Motion.micro, value: hud)
        .animation(Motion.micro, value: toast)
        .sensoryFeedback(.impact(weight: .light), trigger: locked)
        .onAppear { scheduleHide() }
        .onChange(of: hold) { _, hold in
            player.setBoost(hold.active)
            hud = hold.active && player.isBoosting ? .boost(player.boostRate) : nil
        }
        .onChange(of: panel) { scheduleHide() }
        .onChange(of: inputFocused) { scheduleHide() }
    }

    // MARK: 手势（对应画板旁的手势说明）

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) {
                    guard !locked else { return }
                    player.togglePlay()
                }
                .onTapGesture {
                    if panel != nil { closePanel(); return }
                    inputFocused = false
                    showControls.toggle()
                    scheduleHide()
                }
                .gesture(panGesture(in: geo.size), including: locked ? .none : .all)
                .simultaneousGesture(holdGesture, including: locked ? .none : .all)
        }
        .ignoresSafeArea()
    }

    /// 收起抽屉；`then` 在收起动画结束后才执行（换画质、改倍速这类重活不和动画抢主线程）
    private func openPanel(_ target: PlayerPanel) {
        withAnimation(Motion.tab) { panel = target }
    }

    /// 收起用「越来越快」的曲线：滑入的曲线前快后慢，拿来收起时最后一小段会拖着走，看起来像卡了一下再收完
    private static let panelOut = Animation.timingCurve(0.4, 0, 0.9, 0.6, duration: 0.3)

    private func closePanel(then next: (@MainActor () -> Void)? = nil) {
        // 面板完全移除后再做重活（换画质、改倍速）：不在收起的最后一段抢主线程
        withAnimation(Self.panelOut, completionCriteria: .removed) {
            panel = nil
        } completion: {
            next?()
        }
    }

    private struct Hold: Equatable {
        var active = false
    }

    /// 长按：临时 2 倍速，松手恢复原速
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($hold) { value, state, _ in
                if case .second(true, _) = value { state.active = true }
            }
    }

    /// 左右滑：拖动进度；左半屏上下滑：亮度；右半屏上下滑：音量
    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !hold.active else { return }
                if pan == nil {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    if horizontal {
                        pan = .seek(from: player.currentTime)
                    } else if value.startLocation.x < size.width / 2 {
                        pan = .brightness(from: ScreenBrightness.current)
                    } else {
                        pan = .volume(from: player.volume)
                    }
                }
                let vertical = value.translation.height / (size.height * 0.8)
                switch pan {
                case .seek(let from):
                    // 满屏横滑 ≈ 90 秒；短视频按时长缩放
                    let span = min(player.duration, 90)
                    let target = min(max(from + Double(value.translation.width / size.width) * span, 0), player.duration)
                    hud = .seek(to: target, duration: player.duration)
                case .brightness(let from):
                    let level = min(max(from - vertical, 0), 1)
                    ScreenBrightness.set(level)
                    hud = .brightness(Double(level))
                case .volume(let from):
                    let level = min(max(from - Float(vertical), 0), 1)
                    player.volume = level
                    hud = .volume(Double(level))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .seek(let target, _) = hud { player.seek(seconds: target) }
                pan = nil
                hud = nil
            }
    }

    // MARK: 控件

    private var chrome: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 150)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                topBar
                uploaderChip
                    .padding(.leading, 10)
                    .padding(.top, 8)
                Spacer()
                FullscreenProgress(controller: player)
                    .padding(.horizontal, 8)
                bottomBar
                    .padding(.top, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        let stat = model.detail?.stat
        return HStack(alignment: .top, spacing: 6) {
            iconButton("chevron.left", "返回", action: onExit)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.detail?.title ?? model.card.title)
                    .font(.serif(19))
                    .tracking(1.1)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                if let online = model.onlineText {
                    Label("\(online) 人正在观看", systemImage: "person.2")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: 470, alignment: .leading)

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                iconButton(
                    model.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", "点赞",
                    count: (stat?.like ?? 0) + model.likeDelta, tint: model.isLiked ? accent : nil
                ) {
                    Task { try? await model.toggleLike() }
                }
                iconButton("text.bubble", "评论", count: model.comments.total ?? stat?.reply) { openPanel(.comments) }
                iconButton(model.isFavoured ? "star.fill" : "star", "收藏",
                           count: (stat?.favorite ?? 0) + model.favDelta, tint: model.isFavoured ? accent : nil,
                           action: onFavorite)
                if model.pages.count > 1 {
                    iconButton("list.bullet.rectangle", "选集", width: 30) { openPanel(.parts) }
                }
                iconButton("ellipsis", "更多", width: 30) { openPanel(.more) }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var uploaderChip: some View {
        if let owner = model.detail?.owner {
            Button { onUploader(owner.mid) } label: {
                HStack(spacing: 8) {
                    RemoteImage(url: owner.face, size: CGSize(width: 26, height: 26))
                        .frame(width: 26, height: 26)
                        .clipShape(.circle)
                    Text(owner.name).font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .frame(height: 34)
                .contentShape(.capsule)
            }
            .buttonStyle(PressableStyle())
            .glassEffect(.clear.interactive(), in: .capsule)
            .accessibilityLabel("UP 主 \(owner.name)")
            .accessibilityHint("退出全屏，进入 UP 主空间")
        }
    }

    private var bottomBar: some View {
        let qualityName = player.qualities.first(where: { $0.id == player.quality })?.shortName ?? "画质"
        return HStack(spacing: 8) {
            iconButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "暂停" : "播放") {
                player.togglePlay()
            }
            iconButton(
                player.danmakuEnabled ? "text.bubble.fill" : "text.bubble", "弹幕开关",
                tint: player.danmakuEnabled ? accent : nil
            ) {
                player.danmakuEnabled.toggle()
            }
            iconButton("slider.horizontal.3", "弹幕设置") { openPanel(.danmaku) }

            // 竖屏全屏（竖屏视频）放不下输入框：只留按钮
            if verticalSizeClass == .compact {
                TextField("", text: $message, prompt: Text("发个友善的弹幕见证当下").foregroundStyle(.white.opacity(0.62)))
                    .font(.system(size: 14))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .padding(.horizontal, 8)
                    .accessibilityLabel("发送弹幕")
            } else {
                Spacer(minLength: 8)
            }

            textButton(player.rate == 1 ? "倍速" : player.rate.speedLabel) { openPanel(.speed) }
            textButton(qualityName) { openPanel(.quality) }
        }
        .padding(.horizontal, 8)
    }

    private var lockButton: some View {
        Button {
            withAnimation(Motion.component) {
                locked.toggle()
                panel = nil
            }
            scheduleHide()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 19))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(locked ? "解锁屏幕" : "锁定屏幕")
    }

    private func iconButton(
        _ icon: String, _ label: String, count: Int? = nil, tint: Color? = nil,
        width: CGFloat = 44, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .frame(width: width, height: 44)
                .overlay(alignment: .topTrailing) {
                    if let count {
                        Text(count.biliCount)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .fixedSize()
                            .offset(x: 8, y: -2)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(count.map { "\(label) \($0.biliCount)" } ?? label)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: 行为

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        inputFocused = false
        Task {
            do {
                try await player.sendDanmaku(text)
                show(toast: "发送成功")
            } catch {
                show(toast: error.localizedDescription)
            }
        }
    }

    private func show(toast text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }

    /// 3.5 秒无操作自动隐藏（打开抽屉、输入弹幕、暂停时不隐藏）
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, panel == nil, !inputFocused, locked || player.isPlaying else { return }
            showControls = false
        }
    }
}

// MARK: - 进度条：已播 / 已缓冲 / 呼吸光点

// MARK: - 评论浮窗

/// 全屏时看评论：从右侧滑出的浮窗，视频照常播放；和竖屏「评论」Tab 是同一份评论数据（已加载的不重复请求）
private struct CommentsPanel: View {
    let model: CommentModel
    var onClose: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }

    var body: some View {
        // 浮窗里没有导航栈：点头像不跳空间
        CommentSection(model: model, linksToSpace: false, onClose: onClose)
            // 横屏 400 宽；竖屏全屏时屏幕窄，收到屏宽以内
            .frame(maxWidth: 400)
            .frame(maxHeight: .infinity)
            .background {
                // 大面积用 Material，比 glassEffect 便宜；和右侧抽屉同一个压暗色
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color(red: 14 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.55)))
                    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
            .clipShape(shape)
            .padding(.vertical, 12)
            .padding(.trailing, 12)
    }
}

private struct FullscreenProgress: View {
    let controller: PlayerController
    @State private var dragFraction: Double?
    @Environment(\.accent) private var accent

    var body: some View {
        let duration = controller.duration
        let fraction = dragFraction ?? (duration > 0 ? controller.currentTime / duration : 0)
        let buffered = duration > 0 ? min(controller.bufferedTime / duration, 1) : 0

        VStack(alignment: .leading, spacing: 10) {
            Text("\(Int(duration * fraction).durationText) / \(Int(duration).durationText)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                    Capsule().fill(.white.opacity(0.4)).frame(width: width * buffered, height: 3)
                    Capsule().fill(accent).frame(width: width * fraction, height: 3)
                    // 普通白色圆点：不发光、不呼吸
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: width * fraction - 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / width, 0), 1) }
                        .onEnded { _ in
                            if let dragFraction { controller.seek(to: dragFraction) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(duration * fraction).durationText) / \(Int(duration).durationText)")
        }
    }
}

// MARK: - 手势提示

private struct HUDView: View {
    let hud: GestureHUD
    @Environment(\.accent) private var accent

    var body: some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var content: some View {
        switch hud {
        case .seek(let target, let duration):
            VStack(spacing: 10) {
                Text("\(Int(target).durationText) / \(Int(duration).durationText)")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                bar(duration > 0 ? target / duration : 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        case .brightness(let level):
            row("sun.max.fill", level)
        case .volume(let level):
            row(level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", level)
        case .boost(let rate):
            HStack(spacing: 6) {
                Image(systemName: "forward.fill").symbolEffect(.pulse)
                Text("\(rate.speedLabel) 倍速播放中")
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
    }

    private func row(_ icon: String, _ level: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            bar(level)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    private func bar(_ value: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: 140, height: 3)
            .overlay(alignment: .leading) {
                Capsule().fill(accent).frame(width: 140 * min(max(value, 0), 1), height: 3)
            }
    }
}
