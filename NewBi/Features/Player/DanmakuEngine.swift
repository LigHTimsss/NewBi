import UIKit
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
        }
    }

    private var items: [Danmaku] = []
    private var cursor = 0
    private var lastTime: Double = -1
    private var cid: Int?
    private var loadedSegments: Set<Int> = []
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
        items = []
        loadedSegments = []
        clear()
        requestSegment(1)
    }

    private func requestSegment(_ index: Int) {
        guard let cid, loadedSegments.insert(index).inserted else { return }
        let local = localFolder?.appending(path: "dm_\(index).pb")
        Task {
            var segment = local.flatMap { try? Data(contentsOf: $0) }
            if segment == nil {
                segment = try? await BiliClient.shared.data(.danmakuSegment(cid: cid, index: index))
            }
            guard let data = segment else { return }
            // Protobuf 解析放后台
            let parsed = await Task.detached(priority: .utility) { (try? DanmakuDecoder.decode(data)) ?? [] }.value
            guard self.cid == cid else { return }
            items.append(contentsOf: parsed)
            items.sort { $0.time < $1.time }
            cursor = items.lowerBound(of: max(lastTime, 0))
        }
    }

    // MARK: 布局与时钟

    func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
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
    }

    /// 自己发送的弹幕：立即上屏、带边框，轨道满时也强制占一条
    func showOwn(_ text: String) {
        guard size.width > 0 else { return }
        let item = Danmaku(time: max(lastTime, 0), mode: 1, fontSize: 25, color: 0xFFFFFF, content: text)
        spawn(item, now: hostTime, own: true)
    }

    func pause() {
        guard layer.speed != 0 else { return }
        let paused = hostTime
        layer.speed = 0
        layer.timeOffset = paused
    }

    func resume(rate: Float) {
        let paused = layer.timeOffset
        layer.speed = rate
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
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

    private func rebuildTracks() {
        let scrollCount = max(1, Int(size.height * settings.areaRatio / lineHeight))
        let fixedCount = max(1, Int(size.height * 0.25 / lineHeight))
        scrollTracks = Array(repeating: 0, count: scrollCount)
        topTracks = Array(repeating: 0, count: fixedCount)
        bottomTracks = Array(repeating: 0, count: fixedCount)
    }

    private func shouldShow(_ item: Danmaku, now: CFTimeInterval) -> Bool {
        guard active.count < settings.maxOnScreen, item.mode <= 6 else { return false } // 高级/代码弹幕暂不支持
        let fixed = item.mode == 4 || item.mode == 5
        if fixed ? settings.hideFixed : settings.hideScroll { return false }
        if settings.hideBottom, item.mode == 4 { return false }
        if settings.hideColored, item.color & 0xFFFFFF != 0xFFFFFF { return false }
        if settings.keywordFilterEnabled, settings.blockedKeywords.contains(where: { item.content.contains($0) }) { return false }
        if settings.hideDuplicates {
            if let last = recent[item.content], now - last < 8 { return false }
            recent[item.content] = now
            if recent.count > 400 { recent = recent.filter { now - $0.value < 8 } }
        }
        return true
    }

    private func spawn(_ item: Danmaku, now: CFTimeInterval, own: Bool = false) {
        guard let (image, textSize) = render(item, bordered: own) else { return }
        let fixedHold: CFTimeInterval = 4
        let sublayer = pool.popLast() ?? CALayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        sublayer.contents = image
        sublayer.contentsScale = scale
        sublayer.bounds = CGRect(origin: .zero, size: textSize)

        switch item.mode {
        case 4, 5:
            let isTop = item.mode == 5
            guard let track = isTop ? take(&topTracks, now: now, hold: fixedHold) : take(&bottomTracks, now: now, hold: fixedHold) else {
                pool.append(sublayer)
                return
            }
            let y = isTop
                ? (CGFloat(track) + 0.5) * lineHeight
                : size.height - (CGFloat(track) + 0.5) * lineHeight
            sublayer.position = CGPoint(x: size.width / 2, y: y)
            layer.addSublayer(sublayer)
            active.append((sublayer, now + fixedHold))

        default:
            let duration = settings.scrollDuration
            let speed = (size.width + textSize.width) / duration
            // 轨道空出 = 本条尾部完全进入屏幕 + 间隔
            let hold = (textSize.width + 16) / speed
            guard let track = take(&scrollTracks, now: now, hold: hold, force: own) else {
                pool.append(sublayer)
                return
            }
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

    /// 文字 + 描边一次性画成位图，之后只做合成
    private func render(_ item: Danmaku, bordered: Bool = false) -> (CGImage, CGSize)? {
        let fontSize = item.fontSize <= 18 ? settings.fontSize * 0.8 : item.fontSize >= 36 ? settings.fontSize * 1.3 : settings.fontSize
        let text = NSAttributedString(string: item.content, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor(rgb: item.color),
            .strokeColor: UIColor.black.withAlphaComponent(0.55),
            .strokeWidth: -2.5,
        ])
        let raw = text.size()
        let inset: CGFloat = bordered ? 6 : 2
        let size = CGSize(width: ceil(raw.width) + inset * 2, height: ceil(raw.height) + 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if bordered {
                let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let path = UIBezierPath(roundedRect: frame, cornerRadius: size.height / 2)
                UIColor.white.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            text.draw(at: CGPoint(x: inset, y: 1))
        }
        return image.cgImage.map { ($0, size) }
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

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
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
        let length = Int(truncatingIfNeeded: try varint())
        guard length >= 0, index + length <= bytes.endIndex else { throw Malformed() }
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
        guard index + count <= bytes.endIndex else { throw Malformed() }
        index += count
    }
}
