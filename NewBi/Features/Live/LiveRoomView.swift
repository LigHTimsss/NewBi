import SwiftUI
import AVKit

/// 直播间：上面是画面（系统播放器，自带播放 / 暂停、画中画、投屏和全屏），
/// 下面是主播、标题、分区、人气和画质。直播弹幕要走长连接，暂未接入
@MainActor
@Observable
final class LiveRoomModel {
    enum Phase: Equatable {
        case loading
        case live
        /// 没开播（或在轮播）
        case offline
        case failed(String)
    }

    let requestedRoomID: Int
    private(set) var phase: Phase = .loading
    private(set) var info: LiveRoomInfo?
    private(set) var anchor: LiveStatus?
    private(set) var qualities: [LivePlayInfo.Quality] = []
    private(set) var quality = 0
    private(set) var switching = false
    let player = AVPlayer()

    /// 默认要原画；服务器会按登录状态降到能给的最高一档
    private static let preferredQuality = 10000

    init(roomID: Int) {
        requestedRoomID = roomID
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func load() async {
        if info == nil { phase = .loading }
        do {
            let info = try await LiveAPI.roomInfo(roomID: requestedRoomID)
            self.info = info
            if info.uid > 0 {
                anchor = try? await LiveAPI.status(uids: [info.uid])[info.uid]
                LiveStatusCenter.shared.refresh(info.uid)
            }
            guard info.isLive else {
                stop()
                phase = .offline
                return
            }
            try await play(qn: quality == 0 ? Self.preferredQuality : quality)
            phase = .live
        } catch {
            if info == nil { phase = .failed(error.localizedDescription) }
            else { ToastCenter.shared.show(error.localizedDescription) }
        }
    }

    func select(_ qn: Int) async {
        guard qn != quality, !switching else { return }
        switching = true
        defer { switching = false }
        do {
            try await play(qn: qn)
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private func play(qn: Int) async throws {
        guard let roomID = info?.roomID, roomID > 0 else { throw BiliError.emptyData }
        let playInfo = try await LiveAPI.playInfo(roomID: roomID, qn: qn)
        guard let codec = playInfo.hls, let url = codec.url else { throw LiveError.noStream }
        // 只列出这一路流真的能切到的画质
        qualities = playInfo.qualities.filter { codec.acceptQn.contains($0.qn) }
        quality = codec.currentQn
        // 视频页还在胶囊里播的话先停下，免得两路声音
        VideoStage.shared.model?.player.pause()
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": BiliClient.userAgent, "Referer": "https://live.bilibili.com/"]])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    enum LiveError: LocalizedError {
        case noStream
        var errorDescription: String? { "没有可播放的直播流" }
    }
}

struct LiveRoomView: View {
    @State private var model: LiveRoomModel
    @Environment(\.accent) private var accent
    @Environment(\.scenePhase) private var scenePhase

    init(roomID: Int) {
        _model = State(initialValue: LiveRoomModel(roomID: roomID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stage
                if let info = model.info {
                    details(info)
                        .padding(.horizontal, 16)
                } else if case .failed(let message) = model.phase {
                    ContentUnavailableView {
                        Label("进不了直播间", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { Task { await model.load() } }
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationTitle("直播间")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    // MARK: 画面

    private var stage: some View {
        ZStack {
            Color.black
            switch model.phase {
            case .live:
                LivePlayerView(player: model.player)
            case .offline:
                if let info = model.info {
                    RemoteImage(url: info.cover.isEmpty ? info.keyframe : info.cover, size: CGSize(width: 400, height: 225))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(Color.black.opacity(0.45))
                }
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 28))
                    Text("主播还没开播").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
            case .loading:
                ProgressView().tint(.white)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: 资料

    private func details(_ info: LiveRoomInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            anchorRow(info)

            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.serif(19))
                    .tracking(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    let area = [info.parentAreaName, info.areaName].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !area.isEmpty {
                        Text(area)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.selection, in: .capsule)
                    }
                    if info.isLive, let started = info.startedAt {
                        // 已播时长每分钟走一次，不必每秒重绘
                        TimelineView(.everyMinute) { context in
                            Label(Self.elapsed(since: started, now: context.date), systemImage: "clock")
                                .labelStyle(CompactLabelStyle())
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            }

            if model.phase == .live, model.qualities.count > 1 {
                qualityRow
            }

            let intro = info.plainDescription
            if !intro.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("直播间简介").font(.system(size: 13, weight: .semibold))
                    Text(intro)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func anchorRow(_ info: LiveRoomInfo) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.space(mid: info.uid)) {
                HStack(spacing: 12) {
                    RemoteImage(url: model.anchor?.face, size: CGSize(width: 44, height: 44))
                        .frame(width: 44, height: 44)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.anchor?.uname ?? "主播")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if info.isLive {
                                LiveTag(height: 15)
                            }
                            Text(info.isLive ? "\(info.online.biliCount) 人气" : "房间号 \(info.roomID)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
            Spacer(minLength: 0)
            NavigationLink(value: Route.space(mid: info.uid)) {
                Text("主页")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Theme.selection, in: .capsule)
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
        }
    }

    private var qualityRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.qualities) { option in
                    let on = option.qn == model.quality
                    Button {
                        Task { await model.select(option.qn) }
                    } label: {
                        Text(option.desc)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? accent : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(on ? accent.opacity(0.14) : Theme.selection, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(model.switching)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start)) / 60)
        return minutes >= 60 ? "已播 \(minutes / 60) 小时 \(minutes % 60) 分" : "已播 \(minutes) 分钟"
    }
}

/// 系统播放器：直播进度条、画中画、投屏都是现成的。
/// 点全屏时临时放开横屏（App 平时只允许竖屏），退出全屏再锁回竖屏
private struct LivePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        // 离开直播间就停流，画中画留不住，干脆不给
        controller.allowsPictureInPicturePlayback = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            Orientation.lock(.landscape, preferred: .landscapeRight)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled else { return }
                MainActor.assumeIsolated { Orientation.lock(.portrait) }
            }
        }
    }
}
