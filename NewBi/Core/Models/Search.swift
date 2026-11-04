import Foundation

extension KeyedDecodingContainer {
    /// 搜索接口里数字有时是字符串（"--"、"12345"），统一按 0 兜底
    func flexibleInt(_ key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let text = try? decode(String.self, forKey: key), let value = Int(text) { return value }
        return 0
    }
}

struct SearchResult<Item: Decodable & Sendable>: Decodable, Sendable {
    let numPages: Int?
    let result: [Item]?
}

struct SearchVideo: Decodable, Identifiable, Sendable {
    let aid: Int
    let bvid: String
    /// 含 `<em class="keyword">` 高亮标签
    let titleHTML: String
    let pic: String
    let play: Int
    let danmaku: Int
    /// 接口给的是 "12:08"，这里转成秒
    let duration: Int
    let author: String
    let mid: Int
    let pubdate: Int

    var id: Int { aid }

    var card: VideoCard {
        VideoCard(
            id: aid, bvid: bvid, cid: nil, title: BiliHTML.plain(titleHTML), pic: pic, duration: duration,
            owner: Owner(mid: mid, name: author, face: nil),
            stat: VideoStat(view: play, danmaku: danmaku, like: nil, coin: nil, favorite: nil, share: nil, reply: nil)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, title, pic, play, danmaku, duration, author, mid, pubdate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = c.flexibleInt(.aid)
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        titleHTML = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pic = try c.decodeIfPresent(String.self, forKey: .pic) ?? ""
        play = c.flexibleInt(.play)
        danmaku = c.flexibleInt(.danmaku)
        duration = ((try? c.decode(String.self, forKey: .duration)) ?? "").durationSeconds
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        mid = c.flexibleInt(.mid)
        pubdate = c.flexibleInt(.pubdate)
    }
}

struct SearchUser: Decodable, Identifiable, Sendable {
    let mid: Int
    let uname: String
    let upic: String
    let fans: Int
    let videos: Int
    let usign: String
    let level: Int

    var id: Int { mid }

    private enum CodingKeys: String, CodingKey {
        case mid, uname, upic, fans, videos, usign, level
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mid = c.flexibleInt(.mid)
        uname = try c.decodeIfPresent(String.self, forKey: .uname) ?? ""
        upic = try c.decodeIfPresent(String.self, forKey: .upic) ?? ""
        fans = c.flexibleInt(.fans)
        videos = c.flexibleInt(.videos)
        usign = try c.decodeIfPresent(String.self, forKey: .usign) ?? ""
        level = c.flexibleInt(.level)
    }
}

/// 番剧 / 影视搜索结果（search_type=media_bangumi / media_ft）
struct SearchMedia: Decodable, Identifiable, Sendable {
    struct Score: Decodable, Sendable {
        let score: Double?
        let userCount: Int?

        private enum CodingKeys: String, CodingKey {
            case score
            case userCount = "user_count"
        }
    }

    let seasonID: Int
    /// 含 `<em class="keyword">` 高亮
    let titleHTML: String
    let cover: String
    /// "番剧" / "国创" / "电影" …
    let typeName: String
    let styles: String
    let areas: String
    let pubtime: Int
    /// 总集数
    let episodes: Int
    let score: Score?

    var id: Int { seasonID }
    var webURL: URL? { URL(string: "https://www.bilibili.com/bangumi/play/ss\(seasonID)") }

    private enum CodingKeys: String, CodingKey {
        case title, cover, styles, areas, pubtime
        case seasonID = "season_id"
        case typeName = "season_type_name"
        case episodes = "ep_size"
        case score = "media_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonID = c.flexibleInt(.seasonID)
        titleHTML = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        typeName = try c.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        styles = try c.decodeIfPresent(String.self, forKey: .styles) ?? ""
        areas = try c.decodeIfPresent(String.self, forKey: .areas) ?? ""
        pubtime = c.flexibleInt(.pubtime)
        episodes = c.flexibleInt(.episodes)
        score = try? c.decode(Score.self, forKey: .score)
    }
}

/// 直播间搜索结果（search_type=live_room）
struct SearchLive: Decodable, Identifiable, Sendable {
    let roomID: Int
    let titleHTML: String
    let cover: String
    let uname: String
    let online: Int
    /// 1 直播中
    let liveStatus: Int
    let area: String

    var id: Int { roomID }
    var isLive: Bool { liveStatus == 1 }
    var webURL: URL? { URL(string: "https://live.bilibili.com/\(roomID)") }

    private enum CodingKeys: String, CodingKey {
        case title, uname, online
        case roomID = "roomid"
        case cover = "user_cover"
        case liveStatus = "live_status"
        case area = "cate_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomID = c.flexibleInt(.roomID)
        titleHTML = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        uname = try c.decodeIfPresent(String.self, forKey: .uname) ?? ""
        online = c.flexibleInt(.online)
        liveStatus = c.flexibleInt(.liveStatus)
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
    }
}

struct HotWord: Decodable, Hashable, Sendable {
    let keyword: String
    let showName: String?

    private enum CodingKeys: String, CodingKey {
        case keyword
        case showName = "show_name"
    }
}

struct SearchSquare: Decodable, Sendable {
    struct Trending: Decodable, Sendable {
        let list: [HotWord]?
    }

    let trending: Trending?
}

/// 搜索联想（s.search.bilibili.com，不走 {code,data} 格式）
struct SuggestResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Tag: Decodable, Sendable {
            let value: String
        }

        let tag: [Tag]?
    }

    let result: Result?

    private enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 无结果时 result 可能是 [] 而不是对象
        result = try? c.decode(Result.self, forKey: .result)
    }
}
