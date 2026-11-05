import Foundation

/// /x/web-interface/card
struct SpaceCard: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        struct Level: Decodable, Sendable {
            let currentLevel: Int

            private enum CodingKeys: String, CodingKey {
                case currentLevel = "current_level"
            }
        }

        /// type 0 个人认证 · 1 机构认证 · -1 无
        struct Official: Decodable, Sendable {
            let type: Int
            let desc: String
        }

        struct Vip: Decodable, Sendable {
            struct Label: Decodable, Sendable {
                let text: String?
            }

            let vipStatus: Int?
            let label: Label?
        }

        let name: String
        let face: String
        let sign: String
        let fans: Int
        let attention: Int
        let levelInfo: Level?
        let officialVerify: Official?
        let vip: Vip?

        private enum CodingKeys: String, CodingKey {
            case name, face, sign, fans, attention, vip
            case levelInfo = "level_info"
            case officialVerify = "official_verify"
        }
    }

    struct Space: Decodable, Sendable {
        /// 大头图
        let lImg: String?

        private enum CodingKeys: String, CodingKey {
            case lImg = "l_img"
        }
    }

    let card: Card
    let space: Space?
    let following: Bool
    let archiveCount: Int?
    let likeNum: Int?

    private enum CodingKeys: String, CodingKey {
        case card, space, following
        case archiveCount = "archive_count"
        case likeNum = "like_num"
    }
}

/// /x/space/wbi/arc/search
struct SpaceArcSearch: Decodable, Sendable {
    struct List: Decodable, Sendable {
        let vlist: [SpaceVideo]?
    }

    struct Page: Decodable, Sendable {
        let count: Int
    }

    let list: List
    let page: Page
}

struct SpaceVideo: Decodable, Identifiable, Sendable {
    let aid: Int
    let bvid: String
    let title: String
    let pic: String
    let duration: Int
    let play: Int
    let danmaku: Int
    let created: Int
    let author: String
    let mid: Int

    var id: Int { aid }

    var card: VideoCard {
        VideoCard(
            id: aid, bvid: bvid, cid: nil, title: title, pic: pic, duration: duration,
            owner: Owner(mid: mid, name: author, face: nil),
            stat: VideoStat(view: play, danmaku: danmaku, like: nil, coin: nil, favorite: nil, share: nil, reply: nil)
        )
    }

    /// "12.6万播放 · 2026/10/28"
    var subtitle: String {
        "\(play.biliCount)播放 · \(Date(timeIntervalSince1970: TimeInterval(created)).formatted(date: .numeric, time: .omitted))"
    }

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, title, pic, length, play, created, author, mid
        case danmaku = "video_review"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = c.flexibleInt(.aid)
        bvid = try c.decodeIfPresent(String.self, forKey: .bvid) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pic = try c.decodeIfPresent(String.self, forKey: .pic) ?? ""
        duration = ((try? c.decode(String.self, forKey: .length)) ?? "").durationSeconds
        play = c.flexibleInt(.play)
        danmaku = c.flexibleInt(.danmaku)
        created = c.flexibleInt(.created)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        mid = c.flexibleInt(.mid)
    }
}

struct RelationInfo: Decodable, Sendable {
    let attribute: Int
}

/// 关注 / 粉丝列表里的一个人（/x/relation/followings、/x/relation/followers）
struct RelationUser: Decodable, Identifiable, Sendable {
    struct Vip: Decodable, Sendable {
        let vipStatus: Int?
    }

    struct Official: Decodable, Sendable {
        let type: Int?
        let desc: String?
    }

    let mid: Int
    /// 我对他：0 未关注 · 2 已关注 · 6 互相关注（1 悄悄关注、128 拉黑）
    let attribute: Int?
    let uname: String
    let face: String?
    let sign: String?
    let vip: Vip?
    let officialVerify: Official?

    var id: Int { mid }
    var isFollowing: Bool { attribute == 2 || attribute == 6 }
    var isMutual: Bool { attribute == 6 }
    var isVIP: Bool { vip?.vipStatus == 1 }

    /// 认证说明优先，其次签名
    var subtitle: String? {
        if let desc = officialVerify?.desc, !desc.isEmpty { return desc }
        if let sign, !sign.isEmpty { return sign }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case mid, attribute, uname, face, sign, vip
        case officialVerify = "official_verify"
    }
}

struct RelationPage: Decodable, Sendable {
    let list: [RelationUser]?
    let total: Int?
}

// MARK: 合集 / 系列

/// 合集或系列里的一个视频（两个接口字段一致）
struct SeasonArchive: Decodable, Identifiable, Hashable, Sendable {
    struct Stat: Decodable, Hashable, Sendable {
        let view: Int?
    }

    let aid: Int
    let bvid: String
    let title: String
    let pic: String
    let duration: Int
    let pubdate: Int?
    let stat: Stat?

    var id: Int { aid }

    func card(owner: Owner?) -> VideoCard {
        VideoCard(id: aid, bvid: bvid, cid: nil, title: title, pic: pic, duration: duration, owner: owner,
                  stat: VideoStat(view: stat?.view, danmaku: nil, like: nil, coin: nil, favorite: nil, share: nil, reply: nil))
    }
}

/// 空间页「合集」里的一项：合集（season）或系列（series）
struct SpaceSeason: Decodable, Identifiable, Hashable, Sendable {
    struct Meta: Decodable, Hashable, Sendable {
        let seasonID: Int?
        let seriesID: Int?
        let name: String
        let cover: String?
        let total: Int?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case name, cover, total, description
            case seasonID = "season_id"
            case seriesID = "series_id"
        }
    }

    let meta: Meta
    let archives: [SeasonArchive]?

    var isSeries: Bool { meta.seasonID == nil }
    var sourceID: Int { meta.seasonID ?? meta.seriesID ?? 0 }
    var id: String { (isSeries ? "series-" : "season-") + "\(sourceID)" }
}

struct SpaceSeasonsList: Decodable, Sendable {
    struct Items: Decodable, Sendable {
        let seasonsList: [SpaceSeason]?
        let seriesList: [SpaceSeason]?

        private enum CodingKeys: String, CodingKey {
            case seasonsList = "seasons_list"
            case seriesList = "series_list"
        }
    }

    struct Page: Decodable, Sendable {
        let total: Int?
    }

    let itemsLists: Items
    let page: Page?

    var all: [SpaceSeason] { (itemsLists.seasonsList ?? []) + (itemsLists.seriesList ?? []) }

    private enum CodingKeys: String, CodingKey {
        case page
        case itemsLists = "items_lists"
    }
}

/// 合集 / 系列的视频分页
struct SeasonArchivePage: Decodable, Sendable {
    struct Page: Decodable, Sendable {
        let total: Int?
    }

    let archives: [SeasonArchive]?
    let page: Page?
}

extension String {
    /// "1:02:33" / "12:08" → 秒
    var durationSeconds: Int {
        split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
}
