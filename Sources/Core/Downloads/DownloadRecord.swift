import Foundation

/// 一条离线缓存：DASH 的视频、音频两路各存成一个完整的 fMP4 文件，
/// 播放时由本地服务按 sidx 生成 HLS（与在线播放同一套逻辑），弹幕分段也一并存下
struct DownloadRecord: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting, downloading, paused, failed, completed
    }

    enum Part: String, Codable, Sendable, CaseIterable {
        case video, audio
    }

    /// "<bvid>_<cid>"
    let id: String
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let cover: String
    let ownerName: String?
    let ownerMid: Int?
    let duration: Int
    let quality: Int
    let qualityName: String
    var video: DashStream
    var audio: DashStream?
    var state: State
    var videoBytes: Int64 = 0
    var videoTotal: Int64 = 0
    var audioBytes: Int64 = 0
    var audioTotal: Int64 = 0
    var videoDone = false
    var audioDone = false
    var error: String?
    let createdAt: Date
    /// 封面是否已存到本地（旧索引里没有这一项，启动读索引时查一次文件补上）
    var coverSaved: Bool?

    static func id(bvid: String, cid: Int) -> String { "\(bvid)_\(cid)" }

    var isFinished: Bool { videoDone && (audio == nil || audioDone) }

    var receivedBytes: Int64 { videoBytes + audioBytes }

    /// 总大小未知时按码率估算
    var totalBytes: Int64 {
        let known = videoTotal + audioTotal
        if known > 0 { return known }
        let bitrate = Int64(video.bandwidth + (audio?.bandwidth ?? 0))
        return bitrate * Int64(duration) / 8
    }

    var progress: Double {
        if state == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(Double(receivedBytes) / Double(totalBytes), 1)
    }

    /// 封面已下载到本地时用本地文件，断网也能显示（列表滚动时不再每行查文件）
    var coverURL: String {
        coverSaved == true ? DownloadPaths.cover(id).absoluteString : cover
    }

    var card: VideoCard {
        VideoCard(
            id: aid, bvid: bvid, cid: cid, title: title, pic: coverURL, duration: duration,
            owner: ownerMid.map { Owner(mid: $0, name: ownerName ?? "", face: nil) }, stat: nil
        )
    }

    func stream(_ part: Part) -> DashStream? { part == .video ? video : audio }
}

/// 文件布局：Application Support/Downloads/<id>/{video.m4s, audio.m4s, cover.jpg, dm_<n>.pb}
enum DownloadPaths {
    static let root: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 缓存可以重新下载，不进 iCloud 备份
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static var index: URL { root.appending(path: "index.json") }

    static func folder(_ id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    static func file(_ id: String, _ part: DownloadRecord.Part) -> URL {
        folder(id).appending(path: "\(part.rawValue).m4s")
    }

    static func resumeData(_ id: String, _ part: DownloadRecord.Part) -> URL {
        folder(id).appending(path: "\(part.rawValue).resume")
    }

    static func cover(_ id: String) -> URL { folder(id).appending(path: "cover.jpg") }

    static func danmaku(_ id: String, segment: Int) -> URL { folder(id).appending(path: "dm_\(segment).pb") }

    /// 下载任务的 taskDescription："<id>|video"
    static func taskKey(_ id: String, _ part: DownloadRecord.Part) -> String { "\(id)|\(part.rawValue)" }

    static func parse(taskKey: String) -> (id: String, part: DownloadRecord.Part)? {
        let pieces = taskKey.split(separator: "|")
        guard pieces.count == 2, let part = DownloadRecord.Part(rawValue: String(pieces[1])) else { return nil }
        return (String(pieces[0]), part)
    }

    /// 已缓存占用 / 手机剩余空间
    static func usage() -> (used: Int64, free: Int64) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        var used: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in enumerator {
                used += Int64((try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
            }
        }
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return (used, free)
    }
}
