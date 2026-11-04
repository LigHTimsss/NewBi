import Foundation

struct Owner: Decodable, Hashable, Sendable {
    let mid: Int
    let name: String
    let face: String?
}

struct VideoStat: Decodable, Hashable, Sendable {
    let view: Int?
    let danmaku: Int?
    let like: Int?
    let coin: Int?
    let favorite: Int?
    let share: Int?
    let reply: Int?
}

/// 列表卡片：推荐流用 `id`，热门/相关推荐用 `aid`
struct VideoCard: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let bvid: String
    let cid: Int?
    let title: String
    let pic: String
    let duration: Int
    let owner: Owner?
    let stat: VideoStat?

    private enum CodingKeys: String, CodingKey {
        case id, aid, bvid, cid, title, pic, duration, owner, stat
    }

    init(id: Int, bvid: String, cid: Int?, title: String, pic: String, duration: Int, owner: Owner?, stat: VideoStat?) {
        self.id = id
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.pic = pic
        self.duration = duration
        self.owner = owner
        self.stat = stat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .aid) ?? c.decode(Int.self, forKey: .id)
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        cid = try c.decodeIfPresent(Int.self, forKey: .cid)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pic = try c.decodeIfPresent(String.self, forKey: .pic) ?? ""
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        owner = try c.decodeIfPresent(Owner.self, forKey: .owner)
        stat = try c.decodeIfPresent(VideoStat.self, forKey: .stat)
    }
}

struct RecommendFeed: Decodable, Sendable {
    let item: [VideoCard]
}

struct PopularFeed: Decodable, Sendable {
    let list: [VideoCard]
    let noMore: Bool

    private enum CodingKeys: String, CodingKey {
        case list
        case noMore = "no_more"
    }
}

struct VideoPage: Decodable, Hashable, Sendable {
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
}

struct VideoDetail: Decodable, Sendable {
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let desc: String
    let pic: String
    let pubdate: Int
    let duration: Int
    let tname: String?
    let owner: Owner
    let stat: VideoStat
    let pages: [VideoPage]?
}

/// fnval=4048 时返回 dash；fnval=1 时返回 durl（MP4，兜底）
struct PlayURLInfo: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let url: String
        let backupURL: [String]?
        let length: Int

        private enum CodingKeys: String, CodingKey {
            case url, length
            case backupURL = "backup_url"
        }
    }

    let quality: Int
    let acceptQuality: [Int]
    let acceptDescription: [String]
    let durl: [Segment]?
    let dash: DashInfo?

    private enum CodingKeys: String, CodingKey {
        case quality, durl, dash
        case acceptQuality = "accept_quality"
        case acceptDescription = "accept_description"
    }
}

struct DashInfo: Decodable, Sendable {
    /// 秒
    let duration: Int
    let video: [DashStream]
    let audio: [DashStream]?
}

/// DASH 中的一路流（视频为某画质 + 某编码，音频为某码率）。均为单个 fMP4 文件 + sidx 索引
struct DashStream: Codable, Sendable {
    struct SegmentBase: Codable, Sendable {
        /// "0-1003"
        let initialization: String
        /// "1004-1475"
        let indexRange: String

        private enum CodingKeys: String, CodingKey {
            case initialization
            case indexRange = "index_range"
        }
    }

    /// 视频为画质 qn，音频为 30216 / 30232 / 30280
    let id: Int
    let baseURL: String
    let backupURL: [String]?
    let bandwidth: Int
    /// "avc1.640032" / "hev1.1.6.L150.90" / "av01.0.08M.08" / "mp4a.40.2"
    let codecs: String
    let width: Int?
    let height: Int?
    let frameRate: String?
    let codecid: Int?
    let segmentBase: SegmentBase?

    /// 7 AVC · 12 HEVC · 13 AV1
    var codec: Int {
        if let codecid { return codecid }
        if codecs.hasPrefix("av01") { return 13 }
        if codecs.hasPrefix("hev1") || codecs.hasPrefix("hvc1") { return 12 }
        return 7
    }

    /// 主地址 + 备用地址；PCDN（mcdn）节点不稳定，排到最后
    var urls: [URL] {
        let all = [baseURL] + (backupURL ?? [])
        let ordered = all.filter { !$0.contains("mcdn") } + all.filter { $0.contains("mcdn") }
        return ordered.compactMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, bandwidth, codecs, width, height, codecid
        case baseURL = "base_url"
        case backupURL = "backup_url"
        case frameRate = "frame_rate"
        case segmentBase = "segment_base"
    }
}

/// 弹幕（DmSegMobileReply.elems）
struct Danmaku: Sendable {
    /// 秒
    let time: Double
    /// 1–3 滚动，4 底部，5 顶部，6 逆向，7 高级，8 代码，9 BAS
    let mode: Int
    let fontSize: Int
    let color: UInt32
    let content: String
}

struct OnlineTotal: Decodable, Sendable {
    /// 可能是 "39" 或 "1000+"
    let total: String
}

// MARK: - 账号

struct NavInfo: Decodable, Sendable {
    struct WBIImage: Decodable, Sendable {
        let imgURL: String
        let subURL: String

        var imgKey: String? { Self.key(imgURL) }
        var subKey: String? { Self.key(subURL) }

        private static func key(_ url: String) -> String? {
            URL(string: url)?.deletingPathExtension().lastPathComponent
        }

        private enum CodingKeys: String, CodingKey {
            case imgURL = "img_url"
            case subURL = "sub_url"
        }
    }

    struct Level: Decodable, Sendable {
        let currentLevel: Int

        private enum CodingKeys: String, CodingKey {
            case currentLevel = "current_level"
        }
    }

    let isLogin: Bool
    let mid: Int?
    let uname: String?
    let face: String?
    let money: Double?
    let vipStatus: Int?
    let levelInfo: Level?
    let wbiImg: WBIImage?

    private enum CodingKeys: String, CodingKey {
        case isLogin, mid, uname, face, money, vipStatus
        case levelInfo = "level_info"
        case wbiImg = "wbi_img"
    }
}

struct NavStat: Decodable, Sendable {
    let following: Int
    let follower: Int
    let dynamicCount: Int

    private enum CodingKeys: String, CodingKey {
        case following, follower
        case dynamicCount = "dynamic_count"
    }
}

struct FingerSPI: Decodable, Sendable {
    let b3: String
    let b4: String

    private enum CodingKeys: String, CodingKey {
        case b3 = "b_3"
        case b4 = "b_4"
    }
}

struct QRGenerate: Decodable, Sendable {
    let url: String
    let qrcodeKey: String

    private enum CodingKeys: String, CodingKey {
        case url
        case qrcodeKey = "qrcode_key"
    }
}

struct QRPoll: Decodable, Sendable {
    let code: Int
    let message: String
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case code, message
        case refreshToken = "refresh_token"
    }
}
