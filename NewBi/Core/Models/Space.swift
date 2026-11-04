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

extension String {
    /// "1:02:33" / "12:08" → 秒
    var durationSeconds: Int {
        split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
}
