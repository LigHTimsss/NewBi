import SwiftUI

/// 直播间全屏控件：和视频全屏同一套样式和手势（单击显隐、双击暂停、左半屏亮度、右半屏音量、锁屏、玻璃抽屉），
/// 去掉直播用不上的：进度条和横滑拖进度、长按倍速、倍速面板、弹幕和评论。
/// 抽屉里只有画质和更多（定时关闭、画面尺寸、镜像、后台播放、画中画、投屏）
struct LiveFullscreenOverlay: View {
    let model: LiveRoomModel
    @Binding var locked: Bool
    var onExit: () -> Void
    /// 点主播：退出全屏后进空间
    var onAnchor: (Int) -> Void

    @State private var showControls = true
    @State private var panel: PlayerPanel?
    @State private var hud: GestureHUD?
    @State private var pan: Pan?
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accent) private var accent

    private enum Pan {
        case brightness(from: CGFloat)
        case volume(from: Float)
        /// 横向拖动：直播不能拖进度，忽略
        case ignore
    }

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
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            FullscreenPanelLayer(panel: $panel, controller: player, model: nil, close: { closePanel(then: $0) }, changed: scheduleHide)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(Motion.micro, value: showControls)
        .animation(Motion.micro, value: hud)
        .sensoryFeedback(.impact(weight: .light), trigger: locked)
        .onAppear { scheduleHide() }
        .onChange(of: player.isPlaying) { scheduleHide() }
    }

    // MARK: 手势

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
                    showControls.toggle()
                    scheduleHide()
                }
                .gesture(panGesture(in: geo.size), including: locked ? .none : .all)
        }
        .ignoresSafeArea()
    }

    /// 左半屏上下滑：亮度；右半屏上下滑：音量
    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if pan == nil {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        pan = .ignore
                    } else if value.startLocation.x < size.width / 2 {
                        pan = .brightness(from: ScreenBrightness.current)
                    } else {
                        pan = .volume(from: player.volume)
                    }
                }
                let vertical = value.translation.height / (size.height * 0.8)
                switch pan {
                case .brightness(let from):
                    let level = min(max(from - vertical, 0), 1)
                    ScreenBrightness.set(level)
                    hud = .brightness(Double(level))
                case .volume(let from):
                    let level = min(max(from - Float(vertical), 0), 1)
                    player.volume = level
                    hud = .volume(Double(level))
                case .ignore, nil:
                    break
                }
            }
            .onEnded { _ in
                pan = nil
                hud = nil
                scheduleHide()
            }
    }

    // MARK: 控件

    private var chrome: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 130)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                topBar
                anchorChip
                    .padding(.leading, 10)
                    .padding(.top, 8)
                Spacer()
                bottomBar
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 6) {
            iconButton("chevron.left", "退出全屏", action: onExit)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.info?.title ?? "直播间")
                    .font(.serif(19))
                    .tracking(1.1)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                if let info = model.info {
                    HStack(spacing: 8) {
                        LiveTag(height: 16)
                        Label("\(info.online.biliCount) 人气", systemImage: "flame")
                            .labelStyle(CompactLabelStyle())
                        if !info.areaName.isEmpty { Text(info.areaName) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: 470, alignment: .leading)

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                if let url = model.shareURL {
                    iconButton("square.and.arrow.up", "分享") {
                        ShareCenter.shared.share(title: model.info?.title ?? "直播间", url: url)
                    }
                }
                iconButton("ellipsis", "更多", width: 30) { openPanel(.more) }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var anchorChip: some View {
        if let info = model.info, let anchor = model.anchor {
            Button { onAnchor(info.uid) } label: {
                HStack(spacing: 8) {
                    RemoteImage(url: anchor.face, size: CGSize(width: 26, height: 26))
                        .frame(width: 26, height: 26)
                        .clipShape(.circle)
                    Text(anchor.uname).font(.system(size: 14, weight: .medium))
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
            .accessibilityLabel("主播 \(anchor.uname)")
            .accessibilityHint("退出全屏，进入主播空间")
        }
    }

    private var bottomBar: some View {
        let qualityName = player.qualities.first(where: { $0.id == player.quality })?.shortName ?? "画质"
        return HStack(spacing: 8) {
            iconButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "暂停" : "播放") {
                player.togglePlay()
            }
            iconButton("arrow.clockwise", "刷新直播") {
                player.retry()
                scheduleHide()
            }
            Spacer(minLength: 8)
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

    private func iconButton(_ icon: String, _ label: String, width: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .frame(width: width, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
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

    // MARK: 面板

    private func openPanel(_ target: PlayerPanel) {
        withAnimation(Motion.tab) { panel = target }
    }

    /// 和视频全屏一样：收起用越来越快的曲线，面板完全移除后才做下一步
    private static let panelOut = Animation.timingCurve(0.4, 0, 0.9, 0.6, duration: 0.3)

    private func closePanel(then next: (@MainActor () -> Void)? = nil) {
        withAnimation(Self.panelOut, completionCriteria: .removed) {
            panel = nil
        } completion: {
            next?()
        }
    }

    /// 3.5 秒无操作自动隐藏（打开抽屉、暂停时不隐藏）
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, pan == nil, panel == nil, locked || player.isPlaying else { return }
            showControls = false
        }
    }
}
