import Foundation
import VideoToolbox

/// DASH → HLS：AVPlayer 不支持 DASH，这里把 B 站的 fMP4 + sidx 转成
/// 带 EXT-X-BYTERANGE 的 HLS 播放列表，交给 AVPlayer 播放。
/// 这样画中画、AirPlay、HDR、硬件解码、系统播放控制都照常可用，不需要引入 FFmpeg。
///
///   B 站 DASH ──取 init + sidx──▶ SegmentIndex ──▶ master / video / audio m3u8
///                                                     │
///   AVPlayer ◀── http://127.0.0.1:port/<会话>/… ──── LocalMediaServer（转发分段并加 Referer）

enum DashError: LocalizedError {
    case noStream
    case missingIndex
    case badIndex

    var errorDescription: String? {
        switch self {
        case .noStream: "没有可播放的 DASH 流"
        case .missingIndex: "DASH 流缺少分段索引"
        case .badIndex: "DASH 分段索引解析失败"
        }
    }
}

// MARK: - 选流

struct DashSelection: Sendable {
    let video: DashStream
    let audio: DashStream?

    var quality: Int { video.id }
    /// 125 HDR 真彩 · 126 杜比视界
    var isHDR: Bool { video.id == 125 || video.id == 126 }

    /// "HEVC · 1920×1080 · HDR"
    var label: String {
        let codec = switch video.codec {
        case 13: "AV1"
        case 12: "HEVC"
        default: "AVC"
        }
        var parts = [codec]
        if let width = video.width, let height = video.height { parts.append("\(width)×\(height)") }
        if video.id == 126 { parts.append("杜比视界") } else if isHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}

enum DashSelector {
    /// 编码优先级。A17 Pro 起有 AV1 硬解：同画质下码率更低、画质更好、更省电
    /// - Parameter preference: "auto" 硬解优先（AV1 → HEVC → AVC）· "compat" 兼容优先（AVC → HEVC）
    static func codecOrder(preference: String) -> [Int] {
        let av1 = VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) // 'av01'
        switch preference {
        case "compat": return [7, 12]
        default: return (av1 ? [13] : []) + [12, 7]
        }
    }

    /// 取不超过目标画质的最高一档；同一档内按编码优先级挑；音频取码率最高的一路
    static func select(_ dash: DashInfo, quality: Int, codecOrder: [Int]) -> DashSelection? {
        let ids = Set(dash.video.map(\.id))
        guard let target = ids.filter({ $0 <= quality }).max() ?? ids.min() else { return nil }
        let candidates = dash.video.filter { $0.id == target }
        guard let video = codecOrder.lazy.compactMap({ codec in candidates.first { $0.codec == codec } }).first else { return nil }
        let audio = dash.audio?.max { $0.bandwidth < $1.bandwidth }
        return DashSelection(video: video, audio: audio)
    }
}

// MARK: - 分段索引（sidx）

struct SegmentIndex: Sendable {
    struct Segment: Sendable {
        let offset: Int
        let length: Int
        let duration: Double
    }

    let initData: Data
    let segments: [Segment]

    /// 一次 Range 请求取回 init + sidx（通常不到 10KB）
    static func load(_ stream: DashStream) async throws -> SegmentIndex {
        guard let base = stream.segmentBase,
              let initRange = parseRange(base.initialization),
              let indexRange = parseRange(base.indexRange) else { throw DashError.missingIndex }
        let data = try await MediaFetch.range(stream.urls, 0...indexRange.upperBound)
        return try parse(data, initRange: initRange, indexRange: indexRange)
    }

    /// init / sidx 范围都来自远端（或本地缓存的记录），切片前逐一核对，不让越界切片终止进程
    private static func parse(_ data: Data, initRange: ClosedRange<Int>, indexRange: ClosedRange<Int>) throws -> SegmentIndex {
        guard data.count > indexRange.upperBound, data.count > initRange.upperBound else { throw DashError.badIndex }
        let segments = try SIDX.parse(data, at: indexRange.lowerBound, end: indexRange.upperBound + 1)
        return SegmentIndex(initData: data.subdata(in: 0..<(initRange.upperBound + 1)), segments: segments)
    }

    static func loadOptional(_ stream: DashStream?) async throws -> SegmentIndex? {
        guard let stream else { return nil }
        return try await load(stream)
    }

    /// 离线缓存：从本地文件开头读 init + sidx
    static func loadLocal(_ stream: DashStream, file: URL) throws -> SegmentIndex {
        guard let base = stream.segmentBase,
              let initRange = parseRange(base.initialization),
              let indexRange = parseRange(base.indexRange) else { throw DashError.missingIndex }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: indexRange.upperBound + 1) ?? Data()
        return try parse(data, initRange: initRange, indexRange: indexRange)
    }

    /// init + sidx 头部正常不到几十 KB，超过 8 MB 视为异常数据，不去读
    private static let headerLimit = 8 * 1024 * 1024

    private static func parseRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 0, parts[0] <= parts[1], parts[1] < headerLimit else { return nil }
        return parts[0]...parts[1]
    }
}

/// ISO/IEC 14496-12 Segment Index Box。所有字段都来自网络或本地文件，按不可信输入处理：
/// 版本、盒长、偏移逐项校验，累加用溢出检查，任何异常都抛 badIndex（走降级），不会让进程崩溃
enum SIDX {
    /// - Parameters:
    ///   - start: sidx 盒子在 data 里的起点
    ///   - end: indexRange 的结束位置（不含），sidx 不能超出
    static func parse(_ data: Data, at start: Int, end: Int) throws -> [SegmentIndex.Segment] {
        guard start >= 0, start < end, end <= data.count else { throw DashError.badIndex }
        var reader = BigEndianReader(data: data, offset: start)
        let size = Int(try reader.u32())
        guard try reader.u32() == 0x7369_6478 else { throw DashError.badIndex } // 'sidx'
        // size == 1（64 位盒长）/ 0（到文件尾）在 sidx 里不会出现，一并拒绝
        guard size >= 32, size <= end - start else { throw DashError.badIndex }
        let version = try reader.u8()
        guard version <= 1 else { throw DashError.badIndex }
        try reader.skip(3 + 4) // flags + reference_ID
        let timescale = Double(try reader.u32())
        let firstOffset: Int
        if version == 0 {
            try reader.skip(4)
            firstOffset = Int(try reader.u32())
        } else {
            try reader.skip(8)
            guard let value = Int(exactly: try reader.u64()), value <= Int(Int32.max) else { throw DashError.badIndex }
            firstOffset = value
        }
        try reader.skip(2)
        let count = Int(try reader.u16())
        // 每条引用 12 字节，必须完整落在盒子里
        guard timescale > 0, count > 0, reader.offset + count * 12 <= start + size else { throw DashError.badIndex }

        // 偏移以 sidx 盒子之后的第一个字节为基准
        var offset = start + size + firstOffset
        var segments: [SegmentIndex.Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let reference = try reader.u32()
            // 最高位为 1 表示引用的是下一级 sidx（B 站不会下发），按异常处理
            guard reference & 0x8000_0000 == 0 else { throw DashError.badIndex }
            let length = Int(reference & 0x7FFF_FFFF)
            let duration = Double(try reader.u32()) / timescale
            try reader.skip(4) // SAP 信息
            guard length > 0 else { throw DashError.badIndex }
            segments.append(.init(offset: offset, length: length, duration: duration))
            let (next, overflow) = offset.addingReportingOverflow(length)
            guard !overflow else { throw DashError.badIndex }
            offset = next
        }
        return segments
    }
}

private struct BigEndianReader {
    let data: Data
    var offset: Int

    mutating func u8() throws -> UInt8 { UInt8(try read(1)) }
    mutating func u16() throws -> UInt16 { UInt16(try read(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try read(4)) }
    mutating func u64() throws -> UInt64 { try read(8) }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= data.count - offset else { throw DashError.badIndex }
        offset += count
    }

    private mutating func read(_ count: Int) throws -> UInt64 {
        guard offset >= 0, count <= data.count - offset else { throw DashError.badIndex }
        var value: UInt64 = 0
        for index in 0..<count {
            value = value << 8 | UInt64(data[data.startIndex + offset + index])
        }
        offset += count
        return value
    }
}

// MARK: - HLS 会话

/// 一次播放对应一组本地路由；对象释放时自动注销
final class DashHLSSession: Sendable {
    let masterURL: URL
    private let prefix: String

    fileprivate init(masterURL: URL, prefix: String) {
        self.masterURL = masterURL
        self.prefix = prefix
    }

    deinit {
        LocalMediaServer.shared.unregister(prefix: prefix)
    }
}

/// 地址过期时重新请求 playurl。视频、音频两路几乎同时过期，30 秒内共用同一次结果
actor DashRefresher {
    private let fetch: @Sendable () async throws -> DashInfo
    private var cached: (info: DashInfo, at: Date)?
    private var inflight: Task<DashInfo, Error>?

    init(fetch: @escaping @Sendable () async throws -> DashInfo) {
        self.fetch = fetch
    }

    func latest() async throws -> DashInfo {
        if let cached, Date.now.timeIntervalSince(cached.at) < 30 { return cached.info }
        if let inflight { return try await inflight.value }
        let task = Task { [fetch] in try await fetch() }
        inflight = task
        defer { inflight = nil }
        let info = try await task.value
        cached = (info, .now)
        return info
    }

    /// 新结果里找同一路流（画质 + 编码相同即为同一个文件，分段偏移不变）
    func urls(videoID: Int, codec: Int) async throws -> [URL] {
        guard let stream = try await latest().video.first(where: { $0.id == videoID && $0.codec == codec }) else { throw DashError.noStream }
        return stream.urls
    }

    func urls(audioID: Int) async throws -> [URL] {
        guard let stream = try await latest().audio?.first(where: { $0.id == audioID }) else { throw DashError.noStream }
        return stream.urls
    }
}

enum DashHLSBuilder {
    private static let playlistType = "application/vnd.apple.mpegurl"

    /// - Parameter refresher: 地址过期时用来换新地址；nil 则不刷新
    static func build(_ selection: DashSelection, refresher: DashRefresher?) async throws -> DashHLSSession {
        let server = LocalMediaServer.shared
        async let port = server.start()
        async let videoIndex = SegmentIndex.load(selection.video)
        async let audioIndex = SegmentIndex.loadOptional(selection.audio)
        let (videoSegments, audioSegments, serverPort) = try await (videoIndex, audioIndex, port)

        let videoID = selection.video.id, codec = selection.video.codec
        let videoSource = UpstreamSource(urls: selection.video.urls, refresher: refresher.map { refresher -> UpstreamSource.Refresher in
            { try await refresher.urls(videoID: videoID, codec: codec) }
        })

        let prefix = "/\(UUID().uuidString)/"
        var routes: [String: LocalMediaServer.Route] = [
            prefix + "video-init.mp4": .data(Patch.sampleEntry(videoSegments.initData), contentType: "video/mp4"),
            prefix + "video.mp4": .upstream(videoSource, contentType: "video/mp4"),
            prefix + "video.m3u8": .data(Data(mediaPlaylist(videoSegments, initName: "video-init.mp4", mediaName: "video.mp4").utf8), contentType: playlistType),
        ]
        if let audio = selection.audio, let audioSegments {
            let audioID = audio.id
            let audioSource = UpstreamSource(urls: audio.urls, refresher: refresher.map { refresher -> UpstreamSource.Refresher in
                { try await refresher.urls(audioID: audioID) }
            })
            routes[prefix + "audio-init.mp4"] = .data(audioSegments.initData, contentType: "audio/mp4")
            routes[prefix + "audio.mp4"] = .upstream(audioSource, contentType: "audio/mp4")
            routes[prefix + "audio.m3u8"] = .data(Data(mediaPlaylist(audioSegments, initName: "audio-init.mp4", mediaName: "audio.mp4").utf8), contentType: playlistType)
        }
        routes[prefix + "master.m3u8"] = .data(Data(masterPlaylist(selection).utf8), contentType: playlistType)
        server.register(routes)

        guard let url = URL(string: "http://127.0.0.1:\(serverPort)\(prefix)master.m3u8") else { throw DashError.noStream }
        return DashHLSSession(masterURL: url, prefix: prefix)
    }

    /// 离线缓存：同样生成 HLS，只是分段直接从本地文件按 Range 读取，完全不联网
    static func buildLocal(_ record: DownloadRecord) async throws -> DashHLSSession {
        let server = LocalMediaServer.shared
        let port = try await server.start()
        let videoFile = DownloadPaths.file(record.id, .video)
        let videoSegments = try SegmentIndex.loadLocal(record.video, file: videoFile)
        let selection = DashSelection(video: record.video, audio: record.audio)

        let prefix = "/\(UUID().uuidString)/"
        var routes: [String: LocalMediaServer.Route] = [
            prefix + "video-init.mp4": .data(Patch.sampleEntry(videoSegments.initData), contentType: "video/mp4"),
            prefix + "video.mp4": .file(videoFile, contentType: "video/mp4"),
            prefix + "video.m3u8": .data(Data(mediaPlaylist(videoSegments, initName: "video-init.mp4", mediaName: "video.mp4").utf8), contentType: playlistType),
        ]
        if let audio = record.audio {
            let audioFile = DownloadPaths.file(record.id, .audio)
            let audioSegments = try SegmentIndex.loadLocal(audio, file: audioFile)
            routes[prefix + "audio-init.mp4"] = .data(audioSegments.initData, contentType: "audio/mp4")
            routes[prefix + "audio.mp4"] = .file(audioFile, contentType: "audio/mp4")
            routes[prefix + "audio.m3u8"] = .data(Data(mediaPlaylist(audioSegments, initName: "audio-init.mp4", mediaName: "audio.mp4").utf8), contentType: playlistType)
        }
        routes[prefix + "master.m3u8"] = .data(Data(masterPlaylist(selection).utf8), contentType: playlistType)
        server.register(routes)

        guard let url = URL(string: "http://127.0.0.1:\(port)\(prefix)master.m3u8") else { throw DashError.noStream }
        return DashHLSSession(masterURL: url, prefix: prefix)
    }

    private static func mediaPlaylist(_ index: SegmentIndex, initName: String, mediaName: String) -> String {
        let target = Int((index.segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(initName)\"",
        ]
        lines.reserveCapacity(index.segments.count * 3 + 8)
        for segment in index.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(mediaName)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func masterPlaylist(_ selection: DashSelection) -> String {
        let video = selection.video
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var codecs = [Patch.codecs(video.codecs)]
        if let audio = selection.audio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
            codecs.append(audio.codecs)
        }
        var attributes = [
            "BANDWIDTH=\(video.bandwidth + (selection.audio?.bandwidth ?? 0))",
            "CODECS=\"\(codecs.joined(separator: ","))\"",
        ]
        if let width = video.width, let height = video.height { attributes.append("RESOLUTION=\(width)x\(height)") }
        if let fps = frameRate(video.frameRate) { attributes.append(String(format: "FRAME-RATE=%.3f", fps)) }
        if selection.isHDR { attributes.append("VIDEO-RANGE=PQ") }
        if selection.audio != nil { attributes.append("AUDIO=\"aud\"") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// "29.970" 或 "30000/1001"
    private static func frameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first
    }
}

/// Apple 平台只认 hvc1 / dvh1 标记的 HEVC / 杜比视界；B 站下发的是 hev1 / dvhe。
/// 两者区别只在参数集是否允许放在码流里，B 站的流在 hvcC 里带了完整参数集，改标记即可播放。
private enum Patch {
    static func sampleEntry(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        replace(&bytes, "hev1", with: "hvc1")
        replace(&bytes, "dvhe", with: "dvh1")
        return Data(bytes)
    }

    static func codecs(_ text: String) -> String {
        text.replacingOccurrences(of: "hev1", with: "hvc1").replacingOccurrences(of: "dvhe", with: "dvh1")
    }

    private static func replace(_ bytes: inout [UInt8], _ from: String, with to: String) {
        let source = Array(from.utf8), target = Array(to.utf8)
        var index = 0
        while index + 4 <= bytes.count {
            if bytes[index..<index + 4].elementsEqual(source) {
                bytes.replaceSubrange(index..<index + 4, with: target)
                index += 4
            } else {
                index += 1
            }
        }
    }
}
