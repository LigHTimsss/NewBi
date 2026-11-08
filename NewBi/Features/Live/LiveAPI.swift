import Foundation

/// 直播接口都在 api.live.bilibili.com，返回格式和主站不一样（`msg` / `message` 都有，
/// 批量查开播状态没人有直播间时 `data` 是空数组），所以单独一个小客户端，不走 BiliClient。
/// 用同一个 Cookie 仓库：登录后能拿到更高的直播画质
enum LiveAPI {
    private static let host = "https://api.live.bilibili.com"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": BiliClient.userAgent, "Referer": "https://live.bilibili.com/"]
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// 一批 UP 主的直播间状态（一次最多 50 个）。没有直播间的人不在结果里
    static func status(uids: [Int]) async throws -> [Int: LiveStatus] {
        let items = uids.map { URLQueryItem(name: "uids[]", value: String($0)) }
        let map = try await get("/room/v1/Room/get_status_info_by_uids", items, as: LiveStatusMap.self)
        return map.rooms
    }

    /// 直播间资料。`roomID` 可以是短号（比如 6），返回里的 `roomID` 是真实房间号
    static func roomInfo(roomID: Int) async throws -> LiveRoomInfo {
        try await get("/room/v1/Room/get_info", [URLQueryItem(name: "room_id", value: String(roomID))], as: LiveRoomInfo.self)
    }

    /// 播放地址。`qn` 是想要的画质，服务器按登录状态给能给的最高一档（未登录多为 720P）
    static func playInfo(roomID: Int, qn: Int) async throws -> LivePlayInfo {
        try await get("/xlive/web-room/v2/index/getRoomPlayInfo", [
            URLQueryItem(name: "room_id", value: String(roomID)),
            URLQueryItem(name: "protocol", value: "0,1"),
            URLQueryItem(name: "format", value: "0,1,2"),
            URLQueryItem(name: "codec", value: "0,1"),
            URLQueryItem(name: "qn", value: String(qn)),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "ptype", value: "8"),
        ], as: LivePlayInfo.self)
    }

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let message: String?
        let msg: String?
        let data: T?
    }

    private static func get<T: Decodable & Sendable>(_ path: String, _ items: [URLQueryItem], as type: T.Type) async throws -> T {
        guard var components = URLComponents(string: host + path) else { throw BiliError.badURL }
        components.queryItems = items
        guard let url = components.url else { throw BiliError.badURL }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BiliError.http(http.statusCode)
        }
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw BiliError.decoding(error)
        }
        guard envelope.code == 0 else {
            throw BiliError.api(code: envelope.code, message: envelope.message ?? envelope.msg ?? "")
        }
        guard let value = envelope.data else { throw BiliError.emptyData }
        return value
    }
}

// MARK: - 模型

/// 某个 UP 主的直播间（来自批量查询）。`liveStatus`：0 未开播 · 1 直播中 · 2 轮播
struct LiveStatus: Decodable, Sendable, Equatable {
    let roomID: Int
    let liveStatus: Int
    let title: String
    let online: Int
    let uname: String
    let face: String
    let cover: String
    let areaName: String

    var isLive: Bool { liveStatus == 1 && roomID > 0 }

    private enum CodingKeys: String, CodingKey {
        case title, online, uname, face
        case roomID = "room_id"
        case liveStatus = "live_status"
        case cover = "cover_from_user"
        case areaName = "area_v2_name"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomID = c.flexibleInt(.roomID)
        liveStatus = c.flexibleInt(.liveStatus)
        online = c.flexibleInt(.online)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        uname = (try? c.decode(String.self, forKey: .uname)) ?? ""
        face = (try? c.decode(String.self, forKey: .face)) ?? ""
        cover = (try? c.decode(String.self, forKey: .cover)) ?? ""
        areaName = (try? c.decode(String.self, forKey: .areaName)) ?? ""
    }
}

/// 批量查询的 data：按 uid 字符串索引的对象；一个都没有时接口给 `[]`
private struct LiveStatusMap: Decodable, Sendable {
    let rooms: [Int: LiveStatus]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let byID = try? container.decode([String: LiveStatus].self) else {
            rooms = [:]
            return
        }
        var rooms: [Int: LiveStatus] = [:]
        for (key, value) in byID {
            if let uid = Int(key) { rooms[uid] = value }
        }
        self.rooms = rooms
    }
}

struct LiveRoomInfo: Decodable, Sendable {
    let uid: Int
    let roomID: Int
    let title: String
    let liveStatus: Int
    let online: Int
    let areaName: String
    let parentAreaName: String
    let cover: String
    let keyframe: String
    let description: String
    /// 开播时间「2026-11-08 20:01:33」；未开播是全 0
    let liveTime: String

    var isLive: Bool { liveStatus == 1 }

    private enum CodingKeys: String, CodingKey {
        case uid, title, online, keyframe, description
        case roomID = "room_id"
        case liveStatus = "live_status"
        case areaName = "area_name"
        case parentAreaName = "parent_area_name"
        case cover = "user_cover"
        case liveTime = "live_time"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = c.flexibleInt(.uid)
        roomID = c.flexibleInt(.roomID)
        liveStatus = c.flexibleInt(.liveStatus)
        online = c.flexibleInt(.online)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        areaName = (try? c.decode(String.self, forKey: .areaName)) ?? ""
        parentAreaName = (try? c.decode(String.self, forKey: .parentAreaName)) ?? ""
        cover = (try? c.decode(String.self, forKey: .cover)) ?? ""
        keyframe = (try? c.decode(String.self, forKey: .keyframe)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        liveTime = (try? c.decode(String.self, forKey: .liveTime)) ?? ""
    }

    /// 简介是 HTML 片段：去掉标签和常见实体，留纯文字
    var plainDescription: String {
        description
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 开播时刻（北京时间）；未开播为 nil
    var startedAt: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: liveTime)
    }
}

struct LivePlayInfo: Decodable, Sendable {
    struct Quality: Decodable, Sendable, Identifiable, Equatable {
        let qn: Int
        let desc: String
        var id: Int { qn }
    }

    struct Codec: Decodable, Sendable {
        struct Host: Decodable, Sendable {
            let host: String
            let extra: String
        }

        let codecName: String
        let currentQn: Int
        let acceptQn: [Int]
        let baseURL: String
        let urlInfo: [Host]

        private enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case currentQn = "current_qn"
            case acceptQn = "accept_qn"
            case baseURL = "base_url"
            case urlInfo = "url_info"
        }

        var url: URL? {
            guard let first = urlInfo.first else { return nil }
            return URL(string: first.host + baseURL + first.extra)
        }
    }

    struct Format: Decodable, Sendable {
        let formatName: String
        let codec: [Codec]
        private enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case codec
        }
    }

    struct Stream: Decodable, Sendable {
        let protocolName: String
        let format: [Format]
        private enum CodingKeys: String, CodingKey {
            case protocolName = "protocol_name"
            case format
        }
    }

    private struct PlayURL: Decodable, Sendable {
        let qualities: [Quality]?
        let stream: [Stream]?
        private enum CodingKeys: String, CodingKey {
            case qualities = "g_qn_desc"
            case stream
        }
    }

    private struct Wrapper: Decodable, Sendable {
        let playurl: PlayURL?
    }

    let roomID: Int
    let liveStatus: Int
    private let playurlInfo: Wrapper?

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case liveStatus = "live_status"
        case playurlInfo = "playurl_info"
    }

    var qualities: [Quality] { playurlInfo?.playurl?.qualities ?? [] }

    /// 系统播放器能放的 HLS：优先 fmp4 + AVC，其次 ts + AVC，最后才是 HEVC
    var hls: Codec? {
        let formats = (playurlInfo?.playurl?.stream ?? [])
            .filter { $0.protocolName == "http_hls" }
            .flatMap(\.format)
        for (format, codec) in [("fmp4", "avc"), ("ts", "avc"), ("fmp4", "hevc"), ("ts", "hevc")] {
            if let match = formats.first(where: { $0.formatName == format })?.codec.first(where: { $0.codecName == codec }),
               match.url != nil {
                return match
            }
        }
        return nil
    }
}
