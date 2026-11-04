import Foundation

// MARK: - 历史记录

/// /x/web-interface/history/cursor（游标分页）
struct HistoryPage: Decodable, Sendable {
    struct Cursor: Decodable, Sendable {
        let max: Int
        let viewAt: Int
        let business: String

        private enum CodingKeys: String, CodingKey {
            case max, business
            case viewAt = "view_at"
        }
    }

    let cursor: Cursor?
    let list: [HistoryItem]?
}

struct HistoryItem: Decodable, Identifiable, Sendable {
    struct Info: Decodable, Sendable {
        /// 视频为 aid
        let oid: Int
        let bvid: String?
        let cid: Int?
        let business: String
        /// 观看设备：1/3/5/7 手机 · 2 网页 · 4/6 平板 · 33 电视
        let dt: Int?
    }

    let title: String
    let cover: String?
    let history: Info
    let authorName: String?
    let authorMid: Int?
    /// 秒级时间戳
    let viewAt: Int
    /// 看到的秒数；-1 表示已看完
    let progress: Int
    let duration: Int

    /// 删除接口用的 kid："archive_123"
    var id: String { "\(history.business)_\(history.oid)" }
    var isFinished: Bool { progress < 0 || (duration > 0 && progress >= duration - 5) }
    var progressRatio: Double {
        guard duration > 0 else { return 0 }
        return isFinished ? 1 : min(max(Double(progress) / Double(duration), 0), 1)
    }

    var deviceIcon: String {
        switch history.dt {
        case 1, 3, 5, 7: "iphone"
        case 2: "desktopcomputer"
        case 4, 6: "ipad"
        case 33: "tv"
        default: "play.rectangle"
        }
    }

    var card: VideoCard {
        VideoCard(
            id: history.oid, bvid: history.bvid ?? "", cid: history.cid, title: title, pic: cover ?? "", duration: duration,
            owner: authorMid.map { Owner(mid: $0, name: authorName ?? "", face: nil) }, stat: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, cover, history, progress, duration
        case authorName = "author_name"
        case authorMid = "author_mid"
        case viewAt = "view_at"
    }
}

/// /x/player/wbi/v2：上次看到哪里（用于续播）
struct PlayerInfo: Decodable, Sendable {
    /// 毫秒
    let lastPlayTime: Int?
    let lastPlayCid: Int?

    private enum CodingKeys: String, CodingKey {
        case lastPlayTime = "last_play_time"
        case lastPlayCid = "last_play_cid"
    }
}

// MARK: - 稍后再看

struct WatchLaterPage: Decodable, Sendable {
    let count: Int?
    let list: [WatchLaterItem]?
}

struct WatchLaterItem: Decodable, Identifiable, Sendable {
    let aid: Int
    let bvid: String
    let cid: Int?
    let title: String
    let pic: String
    let duration: Int
    let owner: Owner?
    let stat: VideoStat?
    /// 看到的秒数；-1 表示已看完；0 表示未看
    let progress: Int?
    /// 加入时间（秒级时间戳）
    let addAt: Int?

    var id: Int { aid }
    var isFinished: Bool {
        guard let progress else { return false }
        return progress < 0 || (duration > 0 && progress >= duration - 5)
    }
    var progressRatio: Double {
        guard let progress, duration > 0 else { return 0 }
        return isFinished ? 1 : min(max(Double(progress) / Double(duration), 0), 1)
    }

    var card: VideoCard {
        VideoCard(id: aid, bvid: bvid, cid: cid, title: title, pic: pic, duration: duration, owner: owner, stat: stat)
    }

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, pic, duration, owner, stat, progress
        case addAt = "add_at"
    }
}

/// 添加到稍后再看：首页卡片长按、视频详情「更多」都会用到
enum WatchLater {
    static func add(aid: Int) async throws {
        guard let csrf = BiliClient.csrfToken else { throw BiliError.api(code: -101, message: "登录后才能添加稍后再看") }
        try await BiliClient.shared.post(.watchLaterAdd, form: ["aid": "\(aid)", "csrf": csrf])
    }
}

// MARK: - 收藏

struct FavFolderPage: Decodable, Sendable {
    let list: [FavFolder]?
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case list
        case hasMore = "has_more"
    }
}

struct FavFolder: Decodable, Identifiable, Hashable, Sendable {
    /// media_id
    let id: Int
    let title: String
    let cover: String?
    let mediaCount: Int
    /// list-all 带 rid 查询时：1 表示该视频已在此收藏夹
    let favState: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, cover
        case mediaCount = "media_count"
        case favState = "fav_state"
    }
}

struct FavResourcePage: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        let title: String
        let mediaCount: Int

        private enum CodingKeys: String, CodingKey {
            case title
            case mediaCount = "media_count"
        }
    }

    let info: Info?
    let medias: [FavMedia]?
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case info, medias
        case hasMore = "has_more"
    }
}

struct FavMedia: Decodable, Identifiable, Sendable {
    struct Upper: Decodable, Sendable {
        let mid: Int
        let name: String
    }

    struct Count: Decodable, Sendable {
        let play: Int?
        let danmaku: Int?
    }

    /// aid
    let id: Int
    let bvid: String?
    let title: String
    let cover: String
    let duration: Int
    let upper: Upper?
    let cntInfo: Count?
    /// 9 表示已失效
    let attr: Int?

    var isInvalid: Bool { attr == 9 || title == "已失效视频" }

    var card: VideoCard {
        VideoCard(
            id: id, bvid: bvid ?? "", cid: nil, title: title, pic: cover, duration: duration,
            owner: upper.map { Owner(mid: $0.mid, name: $0.name, face: nil) },
            stat: VideoStat(view: cntInfo?.play, danmaku: cntInfo?.danmaku, like: nil, coin: nil, favorite: nil, share: nil, reply: nil)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, bvid, title, cover, duration, upper, attr
        case cntInfo = "cnt_info"
    }
}

struct FavouredInfo: Decodable, Sendable {
    let favoured: Bool
}
