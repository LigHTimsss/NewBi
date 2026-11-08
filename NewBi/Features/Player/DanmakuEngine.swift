import UIKit
import CoreText
import QuartzCore

/// 对应全屏播放器「弹幕设置」抽屉
struct DanmakuSettings: Codable, Equatable {
    /// 显示区域：10% / 25% / 50% / 75% / 100%
    var areaRatio: CGFloat = 0.5
    var opacity: Float = 1
    /// 14–22pt，抽屉里显示为 0–100%
    var fontSize: CGFloat = 18
    /// 0 极慢 … 4 极快
    var speedLevel = 2
    // 按类型屏蔽
    var hideScroll = false
    var hideFixed = false
    var hideColored = false
    // 画面防挡
    var hideDuplicates = false
    var hideBottom = false
    // 屏蔽词
    var keywordFilterEnabled = true
    var blockedKeywords: [String] = []
    /// 同屏上限，防止高能时刻掉帧
    var maxOnScreen = 80

    var scrollDuration: CFTimeInterval { CFTimeInterval(14 - speedLevel * 2) }

    private static let storageKey = "danmakuSettings"

    static func load() -> DanmakuSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(DanmakuSettings.self, from: data) else { return DanmakuSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// 弹幕引擎：每条弹幕预渲染成位图交给一个 CALayer，运动交给 Core Animation（渲染服务进程），
/// 主线程只在「生成」时工作，播放中每帧 CPU 开销≈0。
/// 暂停 / 倍速通过宿主图层的 speed + timeOffset 实现（Apple QA1673），无需逐条处理。
@MainActor
final class DanmakuEngine {
    let layer = CALayer()
    var settings = DanmakuSettings() {
        didSet {
            layer.opacity = settings.opacity
            rebuildTracks()
            // 字号变了：提前画好的位图作废
            if settings.fontSize != oldValue.fontSize { invalidatePrepared() }
        }
    }

    /// 画好的一条弹幕位图（CGImage 不可变，只读地跨线程传递）
    private final class Rendered: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
        let time: Double

        init(image: CGImage, size: CGSize, time: Double) {
            self.image = image
            self.size = size
            self.time = time
        }
    }

    private struct RenderJob: Sendable {
        let key: String
        let content: String
        let color: UInt32
        let fontSize: CGFloat
        let time: Double
    }

    /// 接下来 1.5 秒内要出现的弹幕，提前在后台画好；spawn 时直接取用，主线程只做排轨和挂图层
    private var prepared: [String: Rendered] = [:]
    private var preparing: Set<String> = []
    /// 已经安排过预画的位置（items 下标）
    private var prefetchCursor = 0
    /// 字号 / 屏幕倍率 / 换视频时加一：之前在路上的预画结果不再收下
    private var renderGeneration = 0

    private var items: [Danmaku] = []
    private var cursor = 0
    private var lastTime: Double = -1
    private var cid: Int?
    /// 每次 load(cid:) 加一：上一轮（哪怕是同一个 cid）迟到的分段不再并入
    private var generation = 0
    /// 已成功加载的分段（含合法的空段，不再请求）
    private var loadedSegments: Set<Int> = []
    private var inflightSegments: Set<Int> = []
    /// 失败的分段：连续失败次数和下次可重试的时刻（退避），网络恢复后能补上这一段
    private var segmentFailures: [Int: (count: Int, retryAt: Date)] = [:]
    private static let maxSegmentAttempts = 5
    /// 离线缓存目录：有本地弹幕分段时优先读本地
    var localFolder: URL?

    private var size: CGSize = .zero
    private var scale: CGFloat = 3
    private var lineHeight: CGFloat { settings.fontSize + 7 }
    /// 每条轨道空出的时刻（宿主图层时间）
    private var scrollTracks: [CFTimeInterval] = []
    private var topTracks: [CFTimeInterval] = []
    private var bottomTracks: [CFTimeInterval] = []
    private var active: [(layer: CALayer, end: CFTimeInterval)] = []
    private var pool: [CALayer] = []
    /// 重复弹幕隐藏：内容 → 上次出现时刻
    private var recent: [String: CFTimeInterval] = [:]

    init() {
        layer.masksToBounds = true
    }

    // MARK: 数据

    func load(cid: Int) {
        self.cid = cid
        generation += 1
        items = []
        cursor = 0
        loadedSegments = []
        inflightSegments = []
        segmentFailures = [:]
        invalidatePrepared()
        clear()
        requestSegment(1)
    }

    private func requestSegment(_ index: Int) {
        guard let cid, !loadedSegments.contains(index), !inflightSegments.contains(index) else { return }
        if let failure = segmentFailures[index], failure.retryAt > .now { return }
        inflightSegments.insert(index)
        let generation = generation
        let local = localFolder?.appending(path: "dm_\(index).pb")
        Task {
            // 读本地文件、请求网络、Protobuf 解析、排序都在后台，主线程只做有序合并
            let result = await Task.detached(priority: .utility) {
                await Self.fetchSegment(cid: cid, index: index, local: local)
            }.value
            guard self.generation == generation else { return }
            inflightSegments.remove(index)
            if let parsed = result {
                loadedSegments.insert(index)
                segmentFailures[index] = nil
                merge(parsed)
            } else {
                let count = (segmentFailures[index]?.count ?? 0) + 1
                if count >= Self.maxSegmentAttempts {
                    loadedSegments.insert(index) // 多次失败（多半是坏数据）：本次播放不再请求
                } else {
                    // 5s → 10s → 20s → 40s
                    let delay = 5 * pow(2, Double(count - 1))
                    segmentFailures[index] = (count, .now.addingTimeInterval(delay))
                }
            }
        }
    }

    /// 本地分段（离线缓存）优先；本地缺失或损坏时退回网络。失败返回 nil，合法的空段返回 []
    nonisolated private static func fetchSegment(cid: Int, index: Int, local: URL?) async -> [Danmaku]? {
        if let local, let data = try? Data(contentsOf: local), let parsed = try? DanmakuDecoder.decode(data) {
            return parsed.sorted { $0.time < $1.time }
        }
        guard let data = try? await BiliClient.shared.data(.danmakuSegment(cid: cid, index: index)),
              let parsed = try? DanmakuDecoder.decode(data) else { return nil }
        return parsed.sorted { $0.time < $1.time }
    }

    /// 两个有序数组线性合并（不对全量重新排序）
    private func merge(_ fresh: [Danmaku]) {
        guard !fresh.isEmpty else { return }
        if let last = items.last, let first = fresh.first, first.time < last.time {
            var merged: [Danmaku] = []
            merged.reserveCapacity(items.count + fresh.count)
            var i = 0, j = 0
            while i < items.count, j < fresh.count {
                if fresh[j].time < items[i].time {
                    merged.append(fresh[j])
                    j += 1
                } else {
                    merged.append(items[i])
                    i += 1
                }
            }
            merged.append(contentsOf: items[i...])
            merged.append(contentsOf: fresh[j...])
            items = merged
        } else {
            items.append(contentsOf: fresh)
        }
        cursor = items.lowerBound(of: max(lastTime, 0))
        prefetchCursor = cursor
    }

    // MARK: 布局与时钟

    func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
        if scale != self.scale { invalidatePrepared() }
        self.scale = scale
        guard bounds.size != size else { return }
        size = bounds.size
        clear() // 旋转 / 进入全屏后重新排轨
    }

    /// 由播放器周期回调驱动（0.25s）
    func tick(at time: Double) {
        defer { lastTime = time }
        guard size.width > 0 else { return }

        // 首次 / 拖动 / 回退：清屏并重新定位游标
        if lastTime < 0 || time < lastTime || time - lastTime > 2 {
            clear()
            cursor = items.lowerBound(of: time)
            prefetchCursor = cursor
            prepared = prepared.filter { $0.value.time >= time - 1 }
        }

        // 分段懒加载 + 段末 30 秒预取
        let segment = Int(time / 360) + 1
        requestSegment(segment)
        if time.truncatingRemainder(dividingBy: 360) > 330 { requestSegment(segment + 1) }

        let now = hostTime
        sweep(now: now)
        while cursor < items.count, items[cursor].time <= time {
            let item = items[cursor]
            cursor += 1
            if time - item.time < 1, shouldShow(item, now: now) { spawn(item, now: now) }
        }
        prefetch(until: time + 1.5)
    }

    // MARK: 提前画位图

    private func invalidatePrepared() {
        renderGeneration += 1
        prepared = [:]
        preparing = []
        prefetchCursor = cursor
    }

    private static func key(_ item: Danmaku) -> String {
        "\(item.time)|\(item.color)|\(item.fontSize)|\(item.content)"
    }

    private func displayFontSize(_ item: Danmaku) -> CGFloat {
        item.fontSize <= 18 ? settings.fontSize * 0.8 : item.fontSize >= 36 ? settings.fontSize * 1.3 : settings.fontSize
    }

    /// 把接下来一小段时间里可能出现的弹幕交给后台画（每轮最多 48 条、缓存最多约 240 张，用掉或过时即丢）
    private func prefetch(until limit: Double) {
        var jobs: [RenderJob] = []
        var index = max(cursor, prefetchCursor)
        while index < items.count, items[index].time <= limit, jobs.count < 48 {
            let item = items[index]
            index += 1
            guard mayShow(item) else { continue }
            let key = Self.key(item)
            guard prepared[key] == nil, !preparing.contains(key) else { continue }
            preparing.insert(key)
            jobs.append(RenderJob(key: key, content: item.content, color: item.color, fontSize: displayFontSize(item), time: item.time))
        }
        prefetchCursor = index
        guard !jobs.isEmpty else { return }
        // 交给后台的是不可变的一份（捕获 var 会被 Swift 6 判为和主线程共享可变状态）
        let batch = jobs, scale = scale, generation = renderGeneration
        Task {
            let results = await Task.detached(priority: .utility) { () -> [(String, Rendered)] in
                batch.compactMap { job in
                    DanmakuEngine.rasterize(job.content, color: job.color, fontSize: job.fontSize, scale: scale,
                                            inset: 2, bordered: false, time: job.time).map { (job.key, $0) }
                }
            }.value
            guard generation == renderGeneration else { return }
            for job in batch { preparing.remove(job.key) }
            for (key, rendered) in results { prepared[key] = rendered }
            if prepared.count > 240 { prepared = prepared.filter { $0.value.time >= lastTime - 1 } }
        }
    }

    /// 自己发送的弹幕：立即上屏、带边框，轨道满时也强制占一条
    func showOwn(_ text: String) {
        guard size.width > 0 else { return }
        let item = Danmaku(time: max(lastTime, 0), mode: 1, fontSize: 25, color: 0xFFFFFF, content: text)
        spawn(item, now: hostTime, own: true)
    }

    /// 直播弹幕：收到就上屏。和视频弹幕走同一套筛选（类型、颜色、屏蔽词、重复、同屏上限）和排轨，
    /// 只是没有时间轴，不预画（轨道满时第一步就丢掉，不会为进不了屏的弹幕画位图）
    func showLive(_ item: Danmaku) {
        guard size.width > 0 else { return }
        let now = hostTime
        guard shouldShow(item, now: now) else { return }
        spawn(item, now: now)
    }

    func pause() {
        retime(speed: 0)
    }

    /// 继续播放，或在播放中改变倍速（长按加速、调节播放速度）
    func resume(rate: Float) {
        retime(speed: rate)
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in active { recycle(entry.layer) }
        CATransaction.commit()
        active.removeAll(keepingCapacity: true)
        recent.removeAll()
        rebuildTracks()
    }

    // MARK: - Private

    private var hostTime: CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    /// 改变弹幕图层的时间流速，并让图层本地时间在切换点连续：在飞的弹幕原地减速 / 停住 / 加速，不跳、不闪。
    /// Core Animation：本地时间 = (父时间 − beginTime) × speed + timeOffset。
    /// 切换前先读出本地时间 L 和父时间 P，再令 beginTime = P、timeOffset = L：切换瞬间本地时间仍是 L，之后按新速度走。
    /// （旧实现把本地时间当父时间用，倍速 ≠ 1 时本地时间整体错位，轨道占用判断失效、弹幕重叠；
    /// 播放中再次 resume 还会把本地时间归零。）
    private func retime(speed: Float) {
        guard layer.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        let parent = layer.superlayer?.convertTime(now, from: nil) ?? now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.beginTime = parent
        layer.timeOffset = local
        layer.speed = speed
        CATransaction.commit()
    }

    private func rebuildTracks() {
        let scrollCount = max(1, Int(size.height * settings.areaRatio / lineHeight))
        let fixedCount = max(1, Int(size.height * 0.25 / lineHeight))
        scrollTracks = Array(repeating: 0, count: scrollCount)
        topTracks = Array(repeating: 0, count: fixedCount)
        bottomTracks = Array(repeating: 0, count: fixedCount)
    }

    /// 按设置会不会显示（不看屏上数量、不记重复）：预画时用来跳过一定不会出现的
    private func mayShow(_ item: Danmaku) -> Bool {
        guard item.mode <= 6 else { return false } // 高级/代码弹幕暂不支持
        let fixed = item.mode == 4 || item.mode == 5
        if fixed ? settings.hideFixed : settings.hideScroll { return false }
        if settings.hideBottom, item.mode == 4 { return false }
        if settings.hideColored, item.color & 0xFFFFFF != 0xFFFFFF { return false }
        if settings.keywordFilterEnabled, settings.blockedKeywords.contains(where: { item.content.contains($0) }) { return false }
        return true
    }

    private func shouldShow(_ item: Danmaku, now: CFTimeInterval) -> Bool {
        guard active.count < settings.maxOnScreen, mayShow(item) else { return false }
        if settings.hideDuplicates {
            if let last = recent[item.content], now - last < 8 { return false }
            recent[item.content] = now
            if recent.count > 400 { recent = recent.filter { now - $0.value < 8 } }
        }
        return true
    }

    /// 顺序：先看有没有空轨道 → 只排版量宽 → 抢到轨道 → 才画位图。
    /// 高能时刻大部分候选在第一步就被挡掉，主线程不再为进不了屏的弹幕排版、栅格化
    private func spawn(_ item: Danmaku, now: CFTimeInterval, own: Bool = false) {
        let fixedHold: CFTimeInterval = 4
        let isTop = item.mode == 5, isFixed = item.mode == 4 || item.mode == 5
        if !own {
            let tracks = isFixed ? (isTop ? topTracks : bottomTracks) : scrollTracks
            guard tracks.contains(where: { $0 <= now }) else { return }
        }

        // 后台已经画好就直接用；没赶上（刚拖动过、密度太高）才在这里当场画
        let rendered: Rendered
        if !own, let ready = prepared.removeValue(forKey: Self.key(item)) {
            rendered = ready
        } else {
            guard let fresh = Self.rasterize(item.content, color: item.color, fontSize: displayFontSize(item), scale: scale,
                                             inset: own ? 6 : 2, bordered: own, time: item.time) else { return }
            rendered = fresh
        }
        let textSize = rendered.size

        let track: Int
        let hold: CFTimeInterval
        let duration = settings.scrollDuration
        if isFixed {
            hold = fixedHold
            guard let index = isTop ? take(&topTracks, now: now, hold: hold) : take(&bottomTracks, now: now, hold: hold) else { return }
            track = index
        } else {
            let speed = (size.width + textSize.width) / duration
            // 轨道空出 = 本条尾部完全进入屏幕 + 间隔
            hold = (textSize.width + 16) / speed
            guard let index = take(&scrollTracks, now: now, hold: hold, force: own) else { return }
            track = index
        }

        let image = rendered.image
        let sublayer = pool.popLast() ?? CALayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        sublayer.contents = image
        sublayer.contentsScale = scale
        sublayer.bounds = CGRect(origin: .zero, size: textSize)

        if isFixed {
            let y = isTop
                ? (CGFloat(track) + 0.5) * lineHeight
                : size.height - (CGFloat(track) + 0.5) * lineHeight
            sublayer.position = CGPoint(x: size.width / 2, y: y)
            layer.addSublayer(sublayer)
            active.append((sublayer, now + fixedHold))
        } else {
            let y = (CGFloat(track) + 0.5) * lineHeight
            sublayer.position = CGPoint(x: -textSize.width / 2, y: y) // 模型值 = 终点，动画结束不会闪回
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = size.width + textSize.width / 2
            move.toValue = -textSize.width / 2
            move.duration = duration
            layer.addSublayer(sublayer)
            sublayer.add(move, forKey: "move")
            active.append((sublayer, now + duration))
        }
    }

    /// - Parameter force: 没有空轨道时取最早空出的那条
    private func take(_ tracks: inout [CFTimeInterval], now: CFTimeInterval, hold: CFTimeInterval, force: Bool = false) -> Int? {
        let free = tracks.firstIndex(where: { $0 <= now })
        let earliest = force ? tracks.indices.min(by: { tracks[$0] < tracks[$1] }) : nil
        guard let index = free ?? earliest else { return nil }
        tracks[index] = now + hold
        return index
    }

    private func sweep(now: CFTimeInterval) {
        guard active.contains(where: { $0.end <= now }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        active.removeAll { entry in
            guard entry.end <= now else { return false }
            recycle(entry.layer)
            return true
        }
        CATransaction.commit()
    }

    private func recycle(_ sublayer: CALayer) {
        sublayer.removeAllAnimations()
        sublayer.removeFromSuperlayer()
        sublayer.contents = nil
        if pool.count < 120 { pool.append(sublayer) }
    }

    /// 文字 + 描边一次性画成位图，之后只做合成。用 Core Text 直接画进位图上下文（不走 UIKit 的字符串绘制），
    /// 后台线程可以安全调用：预画和当场画是同一个函数，画出来完全一样
    /// （粗体系统字、按弹幕颜色填充、55% 黑色描边，左右各留 inset，上下各留 1pt）
    private nonisolated static func rasterize(_ content: String, color: UInt32, fontSize: CGFloat, scale: CGFloat,
                                              inset: CGFloat, bordered: Bool, time: Double) -> Rendered? {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let fill = CGColor(srgbRed: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                           blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 0.55),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): NSNumber(value: -2.5),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let size = CGSize(width: ceil(width) + inset * 2, height: ceil(ascent + descent + leading) + 2)
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if bordered {
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let radius = min(frame.height, frame.width) / 2
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(1)
            context.strokePath()
        }
        // 位图坐标原点在左下：基线放在离顶部 1pt + ascent 处，与原来 UIKit 的 draw(at: (inset, 1)) 一致
        context.textPosition = CGPoint(x: inset, y: size.height - 1 - ascent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, size: size, time: time)
    }
}

private extension Array where Element == Danmaku {
    func lowerBound(of time: Double) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

// MARK: - Protobuf 解析

/// 手写的最小 Protobuf 读取器，只解析 DmSegMobileReply 用到的字段，
/// 省掉 SwiftProtobuf 依赖（约 2–3 MB 二进制体积）。
enum DanmakuDecoder {
    static func decode(_ data: Data) throws -> [Danmaku] {
        var reader = ProtoReader([UInt8](data)[...])
        var result: [Danmaku] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            if field == 1, wire == 2 {
                if let item = try element(reader.lengthDelimited()) { result.append(item) }
            } else {
                try reader.skip(wire: wire)
            }
        }
        return result
    }

    /// DanmakuElem: 2 progress(ms) · 3 mode · 4 fontsize · 5 color · 7 content
    private static func element(_ bytes: ArraySlice<UInt8>) throws -> Danmaku? {
        var reader = ProtoReader(bytes)
        var progress = 0, mode = 1, fontSize = 25
        var color: UInt32 = 0xFFFFFF
        var content = ""
        while !reader.isAtEnd {
            let (field, wire) = try reader.tag()
            switch (field, wire) {
            case (2, 0): progress = Int(truncatingIfNeeded: try reader.varint())
            case (3, 0): mode = Int(truncatingIfNeeded: try reader.varint())
            case (4, 0): fontSize = Int(truncatingIfNeeded: try reader.varint())
            case (5, 0): color = UInt32(truncatingIfNeeded: try reader.varint())
            case (7, 2): content = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            default: try reader.skip(wire: wire)
            }
        }
        guard !content.isEmpty else { return nil }
        return Danmaku(time: Double(progress) / 1000, mode: mode, fontSize: fontSize, color: color, content: content)
    }
}

private struct ProtoReader {
    struct Malformed: Error {}

    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw Malformed()
    }

    mutating func tag() throws -> (field: Int, wire: Int) {
        let raw = try varint()
        return (Int(truncatingIfNeeded: raw >> 3), Int(raw & 7))
    }

    /// 返回共享底层存储的切片，不拷贝
    mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
        // 长度来自不可信数据：先确认能表示成 Int，再和剩余字节数比较（不做 index + length，避免溢出崩溃）
        guard let length = Int(exactly: try varint()), length <= bytes.endIndex - index else { throw Malformed() }
        defer { index += length }
        return bytes[index..<(index + length)]
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: try advance(8)
        case 2: _ = try lengthDelimited()
        case 5: try advance(4)
        default: throw Malformed()
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard count <= bytes.endIndex - index else { throw Malformed() }
        index += count
    }
}
