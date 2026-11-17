import Foundation
import Observation

/// 网络和解码离开主线程；字幕 CDN 不携带登录 Cookie。
private actor SubtitleLoader {
    static let shared = SubtitleLoader()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    func load(_ raw: String) async throws -> [SubtitleCue] {
        let raw = raw.hasPrefix("//") ? "https:" + raw : raw
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme ?? ""),
              let host = parts.host?.lowercased(),
              host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host.hasSuffix(".hdslb.com"),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw BiliError.badURL }
        parts.scheme = "https"
        guard let url = parts.url else { throw BiliError.badURL }
        var request = URLRequest(url: url)
        request.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw BiliError.emptyData }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 8 * 1024 * 1024 { throw BiliError.emptyData }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(SubtitleDocument.self, from: data).body
            .filter { $0.from.isFinite && $0.to.isFinite && $0.from >= 0 && $0.to > $0.from }
            .sorted { $0.from < $1.from }
    }
}

@MainActor @Observable
final class SubtitleStore {
    private(set) var sourceID = ""
    private(set) var tracks: [SubtitleTrack] = []
    private(set) var selectedID: String?
    private(set) var text = ""
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var source: (bvid: String, cid: Int)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var time = 0.0
    @ObservationIgnored private var cache: [String: [SubtitleCue]] = [:]

    func reset(bvid: String? = nil, cid: Int? = nil) {
        sourceID = "\(bvid ?? ""):\(cid ?? 0)"
        generation += 1
        selectionGeneration += 1
        task?.cancel()
        task = nil
        source = if let bvid, let cid { (bvid, cid) } else { nil }
        tracks = []; cues = []; cache = [:]
        selectedID = nil; text = ""; error = nil; loading = false; loaded = false; time = 0
    }

    func loadList(force: Bool = false) async {
        guard (!loaded || force), !loading, let source else { return }
        let token = generation
        loading = true
        error = nil
        defer { if token == generation { loading = false } }
        do {
            let info = try await BiliClient.shared.get(.playerInfo(bvid: source.bvid, cid: source.cid), as: PlayerInfo.self)
            guard token == generation, !Task.isCancelled else { return }
            var ids = Set<String>()
            tracks = (info.subtitle?.subtitles ?? []).filter { !$0.subtitle_url.isEmpty && ids.insert($0.id).inserted }
            loaded = true
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = "字幕列表加载失败，请重试"
        }
    }

    func select(_ track: SubtitleTrack?) {
        selectionGeneration += 1
        let token = selectionGeneration
        task?.cancel()
        cues = []; text = ""; error = nil; loading = false
        selectedID = track?.id
        guard let track else { return }
        if let cached = cache[track.id] { cues = cached; update(at: time); return }
        loading = true
        task = Task { [weak self] in
            do {
                let cues = try await SubtitleLoader.shared.load(track.subtitle_url)
                guard let self, !Task.isCancelled, self.selectionGeneration == token else { return }
                if self.cache.count >= 4 { self.cache.removeAll() }
                self.cache[track.id] = cues
                self.cues = cues
                self.loading = false
                self.update(at: self.time)
            } catch {
                guard let self, !Task.isCancelled, self.selectionGeneration == token else { return }
                self.loading = false
                self.selectedID = nil
                self.error = "字幕加载失败，请重新选择"
            }
        }
    }

    /// 复用播放器时钟，二分查找当前句；只有文字改变才通知视图。
    func update(at seconds: Double) {
        time = seconds
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].from <= seconds { low = mid + 1 } else { high = mid }
        }
        let next = low > 0 && seconds < cues[low - 1].to ? cues[low - 1].content : ""
        if text != next { text = next }
    }
}
