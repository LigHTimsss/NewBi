import AVFoundation
import SwiftUI

struct QualityOption: Identifiable, Hashable, Sendable {
    let id: Int
    /// 如 "高清 1080P"
    let name: String
    /// 接口在 accept_quality 里列出、但当前账号拿不到流的画质（未登录 / 非大会员）
    var available = true
    /// 直播的画质编号（150、250、10000…）和视频不是一套，按视频的规则会全被标成大会员：由直播自己给
    var vipOverride: Bool? = nil
    /// 1080P+ / 1080P60 / 4K / HDR / 杜比视界 / 8K 需要大会员
    var needsVIP: Bool { vipOverride ?? (id >= 112) }
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
    static let speeds: [Float] = [0.5, 0.75, 1, 1.5, 2]

    private enum Stage {
        case systemDash, ffmpegDash, systemMP4

        var engine: EngineKind { self == .ffmpegDash ? .ffmpeg : .system }
    }

    /// 当前引擎；切换时 PlayerSurface 会换上新引擎的画面
    private(set) var engine: any PlaybackEngine
    let danmaku = DanmakuEngine()

    private(set) var isPlaying = false
    /// 当前这一项的第一帧已经可以显示（引擎的 firstFrame）：之前播放区盖着封面。换视频 / 换 P 时重置
    private(set) var hasFrame = false
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
    @ObservationIgnored var onReplay: (() -> Void)?
    @ObservationIgnored var onEnded: (() -> Void)?

    /// 播放方式：播完之后做什么
    enum EndAction: String, CaseIterable, Hashable {
        /// 自动连播：下一 P / 连播队列（遵循设置里的「自动连播分 P」）
        case next
        /// 单集循环
        case loop
        /// 播完暂停
        case stop

        var title: String {
            switch self {
            case .next: "自动连播"
            case .loop: "单集循环"
            case .stop: "播完暂停"
            }
        }

        var icon: String {
            switch self {
            case .next: "arrow.forward.to.line"
            case .loop: "repeat.1"
            case .stop: "pause.circle"
            }
        }
    }

    private static let endActionKey = "playerEndAction"
    var endAction: EndAction {
        didSet { UserDefaults.standard.set(endAction.rawValue, forKey: Self.endActionKey) }
    }
    @ObservationIgnored private var reachedEnd = false

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

    /// 长按画面时的临时倍速。系统播放器播 HLS 超过 2 倍会跳帧卡顿，所以固定 2 倍（已经是 2 倍时长按不变速）
    let boostRate: Float = 2
    /// 直播全屏方向优先依据解码后的显示尺寸；尚未就绪时由房间标记兜底。
    var liveVideoIsPortrait: Bool? {
        guard let system = engine as? AVPlayerEngine,
              let size = system.player.currentItem?.presentationSize,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size.height > size.width
    }

    var supportsPictureInPicture: Bool { engine.supportsPictureInPicture }
    var isPictureInPictureActive: Bool { engine.isPictureInPictureActive }

    @ObservationIgnored private var stage: Stage = .systemDash
    @ObservationIgnored private var source: (bvid: String, cid: Int)?
    /// 直播间（真实房间号）。直播没有时长、不能拖进度、不能变速，也没有视频弹幕
    private(set) var liveRoomID: Int?
    var isLive: Bool { liveRoomID != nil }
    private var hasSource: Bool { source != nil || liveRoomID != nil }
    /// 持有即保持本地路由有效；替换时旧会话自动注销
    @ObservationIgnored private var hls: DashHLSSession?
    /// 已离线缓存时优先播本地文件（不联网、不受地址过期影响）
    @ObservationIgnored private var localRecord: DownloadRecord?
    /// 离线缓存第一次播放失败的具体原因（哪个播放器、什么错误）：最后显示给用户，方便定位
    @ObservationIgnored private var offlineFailure: String?
    /// 当前 DASH 流的编码（7 / 12 / 13），MP4 时为 nil
    @ObservationIgnored private var currentCodec: Int?
    /// 系统引擎播放失败过的编码，后续选流时跳过
    @ObservationIgnored private var failedCodecs: Set<Int> = []
    /// 当前播放项是否已经开始播放过（中途出错多半是地址过期、网络抖动或本地代理被系统回收）
    @ObservationIgnored private var itemWasReady = false
    @ObservationIgnored private var lastSameStageRetry: Date?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// shutdown() 之后为 true：还在路上的取流 / 详情请求回来时不再加载、不再自动播放、不再接管锁屏
    @ObservationIgnored private(set) var isClosed = false
    /// 播放世代：换 P、换画质、失败恢复、重试各加一；取流回来时世代不符就丢弃
    @ObservationIgnored private var generation = 0
    /// 引擎里实际装着的那一项对应的 CID（和 currentTime 同时提交）。切 P 时新流装上之前仍是旧 CID
    @ObservationIgnored private(set) var playingCid: Int?
    /// 等待用户确认移动网络播放（设置 → 移动网络播放提醒）
    private(set) var needsCellularConfirm = false
    @ObservationIgnored private var pendingStart: Double?

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
        endAction = UserDefaults.standard.string(forKey: Self.endActionKey).flatMap(EndAction.init(rawValue:)) ?? .next
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

    /// 兜底：正常情况下舞台关掉 / 换走视频时已经调过 shutdown()。
    /// 这里不写被观察的属性（析构中触发观察通知不安全），只做必须的释放
    isolated deinit {
        guard !isClosed else { return }
        clock?.cancel()
        sleepTask?.cancel()
        engine.teardown()
        RemoteControl.shared.deactivate(ObjectIdentifier(self))
    }

    /// 舞台关掉或换走这个视频时显式收尾：停播、释放引擎和本地代理路由、交出锁屏控制、断开回调。
    /// 不依赖 deinit —— 还在路上的网络请求、动画闭包都可能让对象多活一会儿，期间不能再出声或抢锁屏。
    /// 不清 currentTime / duration：收尾后还要用它们上报观看进度。可重复调用
    func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        clock?.cancel()
        clock = nil
        sleepTask?.cancel()
        sleepTask = nil
        onReplay = nil
        onEnded = nil
        onRequestPart = nil
        engine.teardown()
        hls = nil
        danmaku.clear()
        isBoosting = false
        isPlaying = false
        // 画面已释放：页面淡出途中盖回封面，不露黑底
        hasFrame = false
        RemoteControl.shared.deactivate(ObjectIdentifier(self))
    }

    /// 锁屏 / 控制中心显示的标题、UP 主、封面
    func setNowPlaying(title: String, artist: String, cover: String) {
        guard !isClosed else { return }
        RemoteControl.shared.activate(self, metadata: .init(title: title, artist: artist, cover: cover))
    }

    func requestPart(offset: Int) {
        guard offset > 0 ? hasNextPart : hasPreviousPart else { return }
        onRequestPart?(offset)
    }

    // MARK: 加载

    /// 设置里的「移动网络播放提醒」：本次启动内确认过一次就不再问
    private static var cellularConfirmed = false

    private static var initialStage: Stage {
        enginePreference == "ffmpeg" && EngineFactory.ffmpegAvailable ? .ffmpegDash : .systemDash
    }

    /// 换视频 / 换分 P：新的播放世代，之前所有还在路上的取流结果作废（连续切 P 时不会被旧请求覆盖）
    /// - Parameter startAt: 续播位置（秒），来自历史记录
    func load(bvid: String, cid: Int, startAt: Double? = nil) async {
        guard !isClosed else { return }
        generation += 1
        if source != nil { engine.pause() } // 切 P：旧的这一 P 不再继续出声
        source = (bvid, cid)
        stage = Self.initialStage
        failedCodecs = []
        lastSameStageRetry = nil
        offlineFailure = nil
        error = nil
        hasFrame = false // 新的一 P 出第一帧前盖着封面
        localRecord = DownloadManager.shared.completed(bvid: bvid, cid: cid)
        offlineFailure = nil
        danmaku.localFolder = localRecord.map { DownloadPaths.folder($0.id) }

        let alert = UserDefaults.standard.bool(forKey: "cellularAlert")
        if localRecord == nil, alert, !Self.cellularConfirmed, NetworkStatus.shared.isCellular {
            // 先问再取流：用户没点继续之前不发出任何媒体 / 弹幕请求
            pendingStart = startAt
            needsCellularConfirm = true
            return
        }
        needsCellularConfirm = false
        await start(startAt: startAt, autoplay: UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true)
    }

    /// 进直播间：只用系统播放器放 HLS（直播流地址里带签名，过期或断流时重新取一次地址）
    func loadLive(roomID: Int) async {
        guard !isClosed else { return }
        generation += 1
        engine.pause()
        source = nil
        liveRoomID = roomID
        stage = .systemDash
        failedCodecs = []
        lastSameStageRetry = nil
        offlineFailure = nil
        localRecord = nil
        error = nil
        hasFrame = false
        duration = 0
        currentTime = 0
        isBoosting = false
        if rate != 1 { setRate(1) }
        danmaku.clear()

        let alert = UserDefaults.standard.bool(forKey: "cellularAlert")
        if alert, !Self.cellularConfirmed, NetworkStatus.shared.isCellular {
            pendingStart = nil
            needsCellularConfirm = true
            return
        }
        needsCellularConfirm = false
        await start(startAt: nil, autoplay: true)
    }

    /// 「移动网络播放提醒」里点了继续播放
    func confirmCellular() {
        guard needsCellularConfirm, !isClosed else { return }
        Self.cellularConfirmed = true
        needsCellularConfirm = false
        let startAt = pendingStart
        pendingStart = nil
        Task { await start(startAt: startAt, autoplay: true) }
    }

    private func start(startAt: Double?, autoplay: Bool) async {
        guard hasSource else { return }
        let generation = generation
        if let source { danmaku.load(cid: source.cid) }
        await play(quality: isLive ? Self.liveDefaultQuality : Self.defaultQuality, resumeAt: startAt)
        guard !isClosed, generation == self.generation, error == nil else { return }
        if autoplay { engine.play() }
    }

    /// 播放区里的「重试」：从第一级重新取流，回到当前位置
    func retry() {
        guard !isClosed, hasSource, !needsCellularConfirm else { return }
        generation += 1
        let generation = generation
        stage = isLive ? .systemDash : Self.initialStage
        failedCodecs = []
        lastSameStageRetry = nil
        offlineFailure = nil
        error = nil
        // 直播重试就是回到最新画面
        let time = currentTime > 0 && !isLive ? currentTime : nil
        let qn = quality > 0 ? quality : (isLive ? Self.liveDefaultQuality : Self.defaultQuality)
        Task {
            await play(quality: qn, resumeAt: time)
            guard !isClosed, generation == self.generation, error == nil else { return }
            engine.play()
        }
    }

    func changeQuality(_ qn: Int) async {
        guard qn != quality, !isClosed, hasSource else { return }
        generation += 1
        let generation = generation
        let time: Double? = isLive ? nil : currentTime
        let wasPlaying = isPlaying
        await play(quality: qn, resumeAt: time)
        if wasPlaying, !isClosed, generation == self.generation { engine.play() }
    }

    /// 取流结果：等全部 await 结束、确认仍是当前世代后才一次性提交到控制器
    private struct Prepared {
        let url: URL
        var headers: [String: String]?
        let label: String
        let session: DashHLSSession?
        let codec: Int?
        let quality: Int
        /// 0 表示等引擎就绪后再给出（MP4）
        let duration: Double
        let qualities: [QualityOption]
    }

    /// 取流并装载。所有结果在最后一个 await 之后、核对世代通过才写入（hls、画质、时长、引擎），
    /// 旧的一 P / 旧画质的请求晚回来时直接丢弃（它建的本地代理会话随之释放）
    private func play(quality qn: Int, resumeAt time: Double?) async {
        guard hasSource, !isClosed else { return }
        let source = source
        let generation = generation
        do {
            let prepared: Prepared
            if let liveRoomID {
                prepared = try await prepareLive(liveRoomID, quality: qn)
            } else if let source {
                switch stage {
                case .systemDash, .ffmpegDash:
                    if let record = localRecord {
                        prepared = try await prepareLocal(record)
                    } else {
                        // FFmpeg 不受系统解码器限制，不沿用系统引擎的失败编码
                        prepared = try await prepareDash(source, quality: qn, excluding: stage == .systemDash ? failedCodecs : [])
                    }
                case .systemMP4:
                    prepared = try await prepareMP4(source, quality: qn)
                }
            } else {
                return
            }
            // 取流期间已被关掉，或用户又切了 P / 画质：作废
            guard !isClosed, generation == self.generation else { return }
            hls = prepared.session
            currentCodec = prepared.codec
            quality = prepared.quality
            duration = prepared.duration
            qualities = prepared.qualities
            switchEngine(to: stage.engine)
            itemWasReady = false
            reachedEnd = false
            // 直播的时间轴是滑动窗口：不按旧位置 seek，直接从最新画面开始
            let startAt = isLive ? nil : time
            engine.load(url: prepared.url, headers: prepared.headers, startAt: startAt)
            // 已装载的这一项和它的时钟一起提交：进度上报只采样这里（不会把上一 P 的进度记到新 CID 上）
            playingCid = source?.cid
            currentTime = startAt ?? 0
            bufferedTime = 0
            streamLabel = "\(engine.kind.rawValue) · \(prepared.label)"
            error = nil
        } catch {
            guard !isClosed, generation == self.generation else { return }
            // 这一级连流都拿不到（无 DASH / 无可用编码），直接走下一级
            if advanceStage() {
                await play(quality: qn, resumeAt: time)
            } else {
                self.error = Self.describe(error, offline: localRecord != nil)
            }
        }
    }

    /// 直播默认要原画；服务器按登录状态给能给的最高一档（未登录多为 720P）
    private static let liveDefaultQuality = 10000

    /// 直播：取 HLS 地址（优先 fmp4 + AVC）。直播没有时长，画质只列这一路流能切到的几档
    private func prepareLive(_ roomID: Int, quality qn: Int) async throws -> Prepared {
        let info = try await LiveAPI.playInfo(roomID: roomID, qn: qn)
        guard info.liveStatus == 1 else { throw LiveAPI.LiveError.offline }
        guard let codec = info.hls, let url = codec.url else { throw DashError.noStream }
        let options = info.qualities
            .filter { codec.acceptQn.contains($0.qn) }
            .map { QualityOption(id: $0.qn, name: $0.desc, vipOverride: false) }
        return Prepared(
            url: url,
            headers: LiveAPI.mediaHeaders,
            label: "直播 · HLS · \(codec.codecName.uppercased())",
            session: nil,
            codec: nil,
            quality: codec.currentQn,
            duration: 0,
            qualities: options
        )
    }

    /// 离线缓存：画质固定为缓存时选的那一档
    private func prepareLocal(_ record: DownloadRecord) async throws -> Prepared {
        let session = try await DashHLSBuilder.buildLocal(record)
        return Prepared(
            url: session.masterURL,
            label: "本地缓存 · " + DashSelection(video: record.video, audio: record.audio).label,
            session: session,
            codec: record.video.codec,
            quality: record.quality,
            duration: Double(record.duration),
            qualities: [QualityOption(id: record.quality, name: record.qualityName)]
        )
    }

    private func prepareDash(_ source: (bvid: String, cid: Int), quality qn: Int, excluding: Set<Int>) async throws -> Prepared {
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
        return Prepared(
            url: session.masterURL,
            label: "DASH · " + selection.label,
            session: session,
            codec: selection.video.codec,
            quality: selection.quality,
            duration: Double(dash.duration),
            qualities: Self.options(accept: info, available: Set(dash.video.map(\.id)))
        )
    }

    private func prepareMP4(_ source: (bvid: String, cid: Int), quality qn: Int) async throws -> Prepared {
        let info = try await BiliClient.shared.get(.playURL(bvid: source.bvid, cid: source.cid, qn: qn, dash: false), as: PlayURLInfo.self)
        guard let raw = info.durl?.first?.url, let url = URL(string: raw) else { throw BiliError.emptyData }
        return Prepared(
            url: url,
            headers: BiliClient.mediaHeaders,
            label: "MP4",
            session: nil,
            codec: nil,
            quality: info.quality,
            duration: 0,
            qualities: Self.options(accept: info, available: nil)
        )
    }

    /// 播放区显示的错误：区分登录失效、无权观看、网络和媒体本身的问题
    /// 离线缓存放不了：带上第一次失败的具体原因
    private static func offlineMessage(_ reason: String?) -> String {
        reason.map { "离线缓存无法播放：\($0)" } ?? "离线缓存无法播放，可删除后重新缓存"
    }

    /// 播放器报的错误：说明是哪个播放器、错误域和错误码（系统错误文案常常只有「无法完成操作」）
    private static func reason(_ error: Error?, engine: EngineKind) -> String {
        guard let error else { return "\(engine.rawValue) 播放失败" }
        let ns = error as NSError
        return "\(engine.rawValue)：\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
    }

    private static func describe(_ error: Error, offline: Bool) -> String {
        if offline { return "离线缓存无法播放：\(error.localizedDescription)" }
        switch error {
        case let live as LiveAPI.LiveError: return live.localizedDescription
        case BiliError.api(let code, let message):
            switch code {
            case -101: return "登录已失效，请重新登录后播放"
            case -403, -404, 62002, 62004, 62012, 87007, 87008: return "无法观看：\(message)"
            default: return "取流失败：\(message)（\(code)）"
            }
        case BiliError.http(let status): return "网络错误（HTTP \(status)），请稍后重试"
        case let urlError as URLError:
            return urlError.code == .notConnectedToInternet ? "网络未连接，请检查网络后重试" : "网络连接失败，请稍后重试"
        case is DashError: return "视频流解析失败，请稍后重试"
        default: return "播放失败，请稍后重试"
        }
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
            // 媒体可播 ≠ 画面可显示：封面要等 firstFrame 才撤
            itemWasReady = true
            let seconds = engine.duration
            if seconds > 0 { duration = seconds }
            RemoteControl.shared.refresh(self)
        case .firstFrame:
            hasFrame = true
        case .failed(let failure):
            if localRecord != nil, offlineFailure == nil {
                offlineFailure = Self.reason(failure, engine: engine.kind)
            }
            recover()
        case .ended:
            // 直播流播到头 = 主播下播（或断流）：不连播、不循环
            if isLive {
                error = LiveAPI.LiveError.offline.localizedDescription
                return
            }
            reachedEnd = true
            switch endAction {
            case .loop:
                play()
                return
            case .stop:
                return
            case .next:
                break
            }
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
        guard !isClosed else { return }
        let canRetrySameStage = lastSameStageRetry.map { Date.now.timeIntervalSince($0) > 60 } ?? true
        if itemWasReady, canRetrySameStage {
            // 播放中途出错：先在同一级重新取流（新地址、必要时重启本地代理），不急着降级
            lastSameStageRetry = .now
        } else if stage == .systemDash, localRecord == nil, let codec = currentCodec, codec != 7 {
            // 在线流可以换一种编码再试；离线缓存只有这一个文件，换编码没有意义，直接进入下一级
            failedCodecs.insert(codec)
        } else if !advanceStage() {
            error = localRecord != nil ? Self.offlineMessage(offlineFailure) : "播放失败，请稍后重试"
            return
        }
        generation += 1
        let generation = generation
        let time = currentTime, qn = quality
        Task {
            await play(quality: qn, resumeAt: time)
            guard !isClosed, generation == self.generation, error == nil else { return }
            engine.play()
        }
    }

    private func advanceStage() -> Bool {
        // 直播只走系统播放器：同一级重新取地址就是全部的恢复手段
        if isLive { return false }
        switch stage {
        case .systemDash:
            let ffmpegAllowed = Self.enginePreference != "system" && EngineFactory.ffmpegAvailable
            // 离线缓存只在能读本地文件的两个引擎之间换，不悄悄改成在线播放（耗流量、掩盖本地问题）
            if localRecord != nil, !ffmpegAllowed { return false }
            stage = ffmpegAllowed ? .ffmpegDash : .systemMP4
        case .ffmpegDash:
            if localRecord != nil { return false }
            stage = .systemMP4
        case .systemMP4:
            return false
        }
        return true
    }

    // MARK: 控制

    func togglePlay() {
        guard !isClosed else { return }
        if reachedEnd || !engine.isPlaying { play() } else { pause() }
    }

    func play() {
        guard !isClosed else { return }
        if reachedEnd {
            reachedEnd = false
            onReplay?()
            currentTime = 0
            engine.seek(to: 0)
        }
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
        if reachedEnd, target < duration { onReplay?() }
        reachedEnd = target >= duration
        currentTime = target
        engine.seek(to: target)
        RemoteControl.shared.refresh(self)
    }

    func setRate(_ value: Float) {
        // 直播只能 1 倍速
        guard !isLive || value == 1 else { return }
        rate = value
        engine.setRate(value)
        if isPlaying { danmaku.resume(rate: value) }
        RemoteControl.shared.refresh(self)
    }

    /// 长按画面临时 2 倍速（弹幕一起加速）
    func setBoost(_ on: Bool) {
        guard on != isBoosting, isPlaying || !on, !isLive || !on else { return }
        // 本来就在 2 倍：没有更快的可加
        if on, rate >= boostRate { return }
        isBoosting = on
        let effective = isBoosting ? boostRate : rate
        engine.setRate(effective)
        // 暂停中松手：弹幕保持暂停，等真正开始播放时由 tick 按当时的速度恢复
        if isPlaying { danmaku.resume(rate: effective) }
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
        guard let source, !isLive else { return }
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能发送弹幕") }
        try await BiliClient.shared.post(.postDanmaku, form: [
            "type": "1", "oid": "\(source.cid)", "bvid": source.bvid, "msg": text,
            "progress": "\(Int(currentTime * 1000))", "color": "16777215", "fontsize": "25",
            "pool": "0", "mode": "1", "rnd": "\(Int(Date.now.timeIntervalSince1970 * 1000))",
            "csrf": csrf, "csrf_token": csrf,
        ])
        danmaku.showOwn(text)
    }

    /// 直播弹幕到达：开着弹幕、正在播、不在迷你条里才上屏（暂停时不攒，继续播放后从最新的开始）
    func receiveLive(_ item: Danmaku) {
        guard isLive, danmakuEnabled, isPlaying, !isMinimized, !isClosed else { return }
        danmaku.showLive(item)
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
            if !playing, isBoosting {
                // 长按中卡顿 / 暂停：结束临时倍速时引擎也要回到用户倍速，
                // 否则缓冲结束后一直按 2× 播放，而松手时 setBoost(false) 因为已不在加速而被忽略
                isBoosting = false
                engine.setRate(rate)
            }
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
    /// 放在按钮里时设为 false：UIKit 视图默认接收触摸，会挡住外层按钮
    var interactive = true
    /// 舞台上的画面。同一个画面视图只能在一处：收起 / 展开途中和停在胶囊时归舞台（isMinimized），铺满后归视频页。
    /// 不按这个分，两处都刷新时会互相抢，视频页就黑屏了
    var isMini = false

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.isUserInteractionEnabled = interactive
        if showsDanmaku { view.attach(controller.danmaku) }
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        // 读取 engine / isMinimized 建立观察：切换引擎、缩小 / 展开时自动换到该在的地方
        let video = controller.engine.view
        if controller.isMinimized == isMini { view.setVideo(video) }
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
