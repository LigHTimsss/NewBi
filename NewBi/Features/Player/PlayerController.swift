import AVFoundation
import SwiftUI

struct QualityOption: Identifiable, Hashable, Sendable {
    let id: Int
    /// 如 "高清 1080P"
    let name: String
    /// 接口在 accept_quality 里列出、但当前账号拿不到流的画质（未登录 / 非大会员）
    var available = true
    /// 1080P+ / 1080P60 / 4K / HDR / 杜比视界 / 8K 需要大会员
    var needsVIP: Bool { id >= 112 }
    /// 按钮上的短名："1080P"
    var shortName: String {
        name.split(separator: " ").first(where: { $0.contains(where: \.isNumber) }).map(String.init) ?? name
    }
}

/// 播放控制：取流、选引擎、失败降级、弹幕时钟。界面只和它打交道。
///
/// 降级链（设置 → 播放引擎 = 自动）：
///   系统 · DASH（AV1 / HEVC）→ 系统 · DASH（AVC）→ FFmpeg · DASH → 系统 · MP4
@MainActor
@Observable
final class PlayerController {
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private enum Stage {
        case systemDash, ffmpegDash, systemMP4

        var engine: EngineKind { self == .ffmpegDash ? .ffmpeg : .system }
    }

    /// 当前引擎；切换时 PlayerSurface 会换上新引擎的画面
    private(set) var engine: any PlaybackEngine
    let danmaku = DanmakuEngine()

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var bufferedTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    /// 用户选择的倍速
    private(set) var rate: Float = 1
    /// 长按临时倍速中
    private(set) var isBoosting = false
    private(set) var qualities: [QualityOption] = []
    private(set) var quality = 0
    /// 当前流的说明，如 "AVPlayer · DASH · HEVC · 1920×1080 · HDR"
    private(set) var streamLabel: String?
    private(set) var sleepDeadline: Date?

    var danmakuEnabled = true {
        didSet { if !danmakuEnabled { danmaku.clear() } }
    }
    /// 缩成迷你播放条时不生成弹幕（小画面上看不清，也省掉图层开销）
    var isMinimized = false {
        didSet { if isMinimized { danmaku.clear() } }
    }

    /// 多 P：由详情模型设置；锁屏「上一首 / 下一首」和播完连播都走 onRequestPart
    var hasNextPart = false
    var hasPreviousPart = false
    @ObservationIgnored var onRequestPart: ((Int) -> Void)?
    /// 整个视频播完（没有下一 P 可连播时）：连播队列用
    @ObservationIgnored var onEnded: (() -> Void)?

    /// 实际播放速度（含长按临时倍速）
    var effectiveRate: Float { isBoosting ? boostRate : rate }
    var danmakuSettings: DanmakuSettings {
        didSet {
            guard danmakuSettings != oldValue else { return }
            danmaku.settings = danmakuSettings
            danmakuSettings.save()
        }
    }
    /// 画面尺寸：铺满（裁切）/ 适应
    var fillScreen = false {
        didSet { engine.setFill(fillScreen) }
    }
    var mirrored = false

    var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    var boostRate: Float { rate >= 2 ? 3 : 2 }
    var supportsPictureInPicture: Bool { engine.supportsPictureInPicture }
    var isPictureInPictureActive: Bool { engine.isPictureInPictureActive }

    @ObservationIgnored private var stage: Stage = .systemDash
    @ObservationIgnored private var source: (bvid: String, cid: Int)?
    /// 持有即保持本地路由有效；替换时旧会话自动注销
    @ObservationIgnored private var hls: DashHLSSession?
    /// 已离线缓存时优先播本地文件（不联网、不受地址过期影响）
    @ObservationIgnored private var localRecord: DownloadRecord?
    /// 当前 DASH 流的编码（7 / 12 / 13），MP4 时为 nil
    @ObservationIgnored private var currentCodec: Int?
    /// 系统引擎播放失败过的编码，后续选流时跳过
    @ObservationIgnored private var failedCodecs: Set<Int> = []
    /// 当前播放项是否已经开始播放过（中途出错多半是地址过期、网络抖动或本地代理被系统回收）
    @ObservationIgnored private var itemWasReady = false
    @ObservationIgnored private var lastSameStageRetry: Date?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    /// 设置 → 播放引擎：auto 自动 · system 仅系统 · ffmpeg 始终 FFmpeg
    private static var enginePreference: String {
        UserDefaults.standard.string(forKey: "enginePreference") ?? "auto"
    }

    /// 设置里的「默认画质」，默认 1080P；未登录时服务器会自动降到可用的最高档
    private static var defaultQuality: Int {
        let value = UserDefaults.standard.integer(forKey: "defaultQuality")
        return value > 0 ? value : 80
    }

    init() {
        danmakuSettings = DanmakuSettings.load()
        engine = AVPlayerEngine()
        danmaku.settings = danmakuSettings
        attach(engine)
        // 4 Hz 时钟：进度条和弹幕生成足够；弹幕运动本身在 Core Animation 里，不依赖这个频率
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Swift 6.2 isolated deinit：详情页出栈、模型释放时在主线程清理
    isolated deinit {
        clock?.cancel()
        sleepTask?.cancel()
        engine.teardown()
        RemoteControl.shared.deactivate(ObjectIdentifier(self))
    }

    /// 锁屏 / 控制中心显示的标题、UP 主、封面
    func setNowPlaying(title: String, artist: String, cover: String) {
        RemoteControl.shared.activate(self, metadata: .init(title: title, artist: artist, cover: cover))
    }

    func requestPart(offset: Int) {
        guard offset > 0 ? hasNextPart : hasPreviousPart else { return }
        onRequestPart?(offset)
    }

    // MARK: 加载

    /// - Parameter startAt: 续播位置（秒），来自历史记录
    func load(bvid: String, cid: Int, startAt: Double? = nil) async {
        source = (bvid, cid)
        stage = Self.enginePreference == "ffmpeg" && EngineFactory.ffmpegAvailable ? .ffmpegDash : .systemDash
        localRecord = DownloadManager.shared.completed(bvid: bvid, cid: cid)
        danmaku.localFolder = localRecord.map { DownloadPaths.folder($0.id) }
        danmaku.load(cid: cid)
        await play(quality: Self.defaultQuality, resumeAt: startAt)
        if UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true { engine.play() }
    }

    func changeQuality(_ qn: Int) async {
        guard qn != quality else { return }
        let time = currentTime
        let wasPlaying = isPlaying
        await play(quality: qn, resumeAt: time)
        if wasPlaying { engine.play() }
    }

    private func play(quality qn: Int, resumeAt time: Double?) async {
        guard let source else { return }
        do {
            let url: URL
            var headers: [String: String]?
            let label: String
            switch stage {
            case .systemDash, .ffmpegDash:
                if let record = localRecord {
                    // 离线缓存：画质固定为缓存时选的那一档
                    let session = try await DashHLSBuilder.buildLocal(record)
                    hls = session
                    currentCodec = record.video.codec
                    quality = record.quality
                    duration = Double(record.duration)
                    qualities = [QualityOption(id: record.quality, name: record.qualityName)]
                    url = session.masterURL
                    label = "本地缓存 · " + DashSelection(video: record.video, audio: record.audio).label
                } else {
                    // FFmpeg 不受系统解码器限制，不沿用系统引擎的失败编码
                    let prepared = try await prepareDash(source, quality: qn, excluding: stage == .systemDash ? failedCodecs : [])
                    url = prepared.0
                    label = prepared.1
                }
            case .systemMP4:
                url = try await prepareMP4(source, quality: qn)
                headers = BiliClient.mediaHeaders
                label = "MP4"
            }
            switchEngine(to: stage.engine)
            itemWasReady = false
            engine.load(url: url, headers: headers, startAt: time)
            streamLabel = "\(engine.kind.rawValue) · \(label)"
            error = nil
        } catch {
            // 这一级连流都拿不到（无 DASH / 无可用编码），直接走下一级
            if advanceStage() {
                await play(quality: qn, resumeAt: time)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func prepareDash(_ source: (bvid: String, cid: Int), quality qn: Int, excluding: Set<Int>) async throws -> (URL, String) {
        let info = try await BiliClient.shared.get(.playURL(bvid: source.bvid, cid: source.cid, qn: qn, dash: true), as: PlayURLInfo.self)
        guard let dash = info.dash else { throw DashError.noStream }
        let preference = UserDefaults.standard.string(forKey: "codecPreference") ?? "auto"
        let order = DashSelector.codecOrder(preference: preference).filter { !excluding.contains($0) }
        guard let selection = DashSelector.select(dash, quality: qn, codecOrder: order) else { throw DashError.noStream }

        // 地址约 2 小时过期：过期时按同一画质重新请求 playurl，本地代理换上新地址继续播放
        let qnForRefresh = selection.quality
        let refresher = DashRefresher { [bvid = source.bvid, cid = source.cid] in
            let info = try await BiliClient.shared.get(.playURL(bvid: bvid, cid: cid, qn: qnForRefresh, dash: true), as: PlayURLInfo.self)
            guard let dash = info.dash else { throw DashError.noStream }
            return dash
        }
        let session = try await DashHLSBuilder.build(selection, refresher: refresher)
        hls = session
        currentCodec = selection.video.codec
        quality = selection.quality
        duration = Double(dash.duration)
        qualities = Self.options(accept: info, available: Set(dash.video.map(\.id)))
        return (session.masterURL, "DASH · " + selection.label)
    }

    private func prepareMP4(_ source: (bvid: String, cid: Int), quality qn: Int) async throws -> URL {
        let info = try await BiliClient.shared.get(.playURL(bvid: source.bvid, cid: source.cid, qn: qn, dash: false), as: PlayURLInfo.self)
        guard let raw = info.durl?.first?.url, let url = URL(string: raw) else { throw BiliError.emptyData }
        hls = nil
        currentCodec = nil
        duration = 0 // 播放项就绪后由引擎给出
        quality = info.quality
        qualities = Self.options(accept: info, available: nil)
        return url
    }

    /// accept_quality 里列出的全部画质；DASH 下没有返回流的那几档标为不可用（需登录 / 大会员）
    private static func options(accept info: PlayURLInfo, available: Set<Int>?) -> [QualityOption] {
        zip(info.acceptQuality, info.acceptDescription).map { id, name in
            QualityOption(id: id, name: name, available: available?.contains(id) ?? true)
        }
    }

    // MARK: 引擎与降级

    private func switchEngine(to kind: EngineKind) {
        guard engine.kind != kind, let next = EngineFactory.make(kind) else { return }
        engine.teardown()
        engine = next
        attach(next)
    }

    private func attach(_ engine: any PlaybackEngine) {
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.setRate(rate)
        engine.setFill(fillScreen)
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ready:
            itemWasReady = true
            let seconds = engine.duration
            if seconds > 0 { duration = seconds }
            RemoteControl.shared.refresh(self)
        case .failed:
            recover()
        case .ended:
            // 多 P 连播（设置里可关）
            if hasNextPart, UserDefaults.standard.object(forKey: "autoNextPart") as? Bool ?? true {
                onRequestPart?(1)
            } else {
                onEnded?()
            }
        }
    }

    /// 播放中途失败：同一级换编码，或进入下一级，并从当前位置续播
    private func recover() {
        let canRetrySameStage = lastSameStageRetry.map { Date.now.timeIntervalSince($0) > 60 } ?? true
        if itemWasReady, canRetrySameStage {
            // 播放中途出错：先在同一级重新取流（新地址、必要时重启本地代理），不急着降级
            lastSameStageRetry = .now
        } else if stage == .systemDash, let codec = currentCodec, codec != 7 {
            failedCodecs.insert(codec)
        } else if !advanceStage() {
            error = "播放失败，请稍后重试"
            return
        }
        let time = currentTime, qn = quality
        Task {
            await play(quality: qn, resumeAt: time)
            engine.play()
        }
    }

    private func advanceStage() -> Bool {
        switch stage {
        case .systemDash:
            let ffmpegAllowed = Self.enginePreference != "system" && EngineFactory.ffmpegAvailable
            stage = ffmpegAllowed ? .ffmpegDash : .systemMP4
        case .ffmpegDash:
            stage = .systemMP4
        case .systemMP4:
            return false
        }
        return true
    }

    // MARK: 控制

    func togglePlay() {
        isPlaying ? engine.pause() : engine.play()
    }

    func play() {
        engine.play()
    }

    func pause() {
        engine.pause()
    }

    func seek(to fraction: Double) {
        seek(seconds: duration * min(max(fraction, 0), 1))
    }

    func seek(seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        currentTime = target
        engine.seek(to: target)
        RemoteControl.shared.refresh(self)
    }

    func setRate(_ value: Float) {
        rate = value
        engine.setRate(value)
        if isPlaying { danmaku.resume(rate: value) }
        RemoteControl.shared.refresh(self)
    }

    /// 长按画面临时倍速（弹幕一起加速）
    func setBoost(_ on: Bool) {
        guard on != isBoosting, isPlaying || !on else { return }
        isBoosting = on
        let effective = on ? boostRate : rate
        engine.setRate(effective)
        danmaku.resume(rate: effective)
    }

    func sleep(after minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = .now.addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.engine.pause()
            self?.sleepDeadline = nil
        }
    }

    func sendDanmaku(_ text: String) async throws {
        guard let source else { return }
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能发送弹幕") }
        try await BiliClient.shared.post(.postDanmaku, form: [
            "type": "1", "oid": "\(source.cid)", "bvid": source.bvid, "msg": text,
            "progress": "\(Int(currentTime * 1000))", "color": "16777215", "fontsize": "25",
            "pool": "0", "mode": "1", "rnd": "\(Int(Date.now.timeIntervalSince1970 * 1000))",
            "csrf": csrf, "csrf_token": csrf,
        ])
        danmaku.showOwn(text)
    }

    func togglePictureInPicture() {
        engine.togglePictureInPicture()
    }

    // MARK: 时钟

    private func tick() {
        let seconds = engine.currentTime
        // 只在变化时写入，暂停时不触发界面刷新
        if abs(seconds - currentTime) > 0.05 { currentTime = seconds }
        let buffered = engine.bufferedTime
        if abs(buffered - bufferedTime) > 0.5 { bufferedTime = buffered }

        let playing = engine.isPlaying
        if playing != isPlaying {
            isPlaying = playing
            if !playing { isBoosting = false }
            playing ? danmaku.resume(rate: isBoosting ? boostRate : rate) : danmaku.pause()
            RemoteControl.shared.refresh(self)
        }
        if playing, danmakuEnabled, !isMinimized { danmaku.tick(at: seconds) }
    }
}

extension Float {
    /// 1 → "1.0x"，0.75 → "0.75x"
    var speedLabel: String {
        self == rounded() ? String(format: "%.1fx", self) : String(format: "%gx", self)
    }
}

// MARK: - 视图

/// 视频画面（来自当前引擎）在下、弹幕图层在上；镜像只作用于视频，弹幕文字不会反过来
struct PlayerSurface: UIViewRepresentable {
    let controller: PlayerController
    /// 迷你播放条里只要画面，不挂弹幕图层（否则弹幕会按小尺寸重新布局）
    var showsDanmaku = true

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        if showsDanmaku { view.attach(controller.danmaku) }
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        // 读取 engine 建立观察：切换引擎时自动换上新画面
        view.setVideo(controller.engine.view)
        view.mirrored = controller.mirrored
    }
}

final class PlayerHostView: UIView {
    private var video: UIView?
    private var danmaku: DanmakuEngine?

    var mirrored = false {
        didSet { video?.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ engine: DanmakuEngine) {
        danmaku = engine
        layer.addSublayer(engine.layer)
    }

    /// 同一个画面视图在迷你条和视频页之间移动：被别的宿主拿走后再次更新时要拿回来
    func setVideo(_ view: UIView) {
        guard view !== video || view.superview !== self else { return }
        if view !== video { video?.removeFromSuperview() }
        video = view
        insertSubview(view, at: 0) // 在弹幕图层之下
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 有 transform 时不能直接设 frame
        video?.bounds = bounds
        video?.center = CGPoint(x: bounds.midX, y: bounds.midY)
        danmaku?.layout(in: bounds, scale: traitCollection.displayScale)
    }
}
