import CoreGraphics
import Foundation

/// /x/polymer/web-dynamic/v1/feed/all
struct DynamicFeed: Decodable, Sendable {
    let hasMore: Bool?
    let offset: String?
    let updateBaseline: String?
    let items: [DynamicItem]?

    private enum CodingKeys: String, CodingKey {
        case offset, items
        case hasMore = "has_more"
        case updateBaseline = "update_baseline"
    }
}

struct DynamicItem: Decodable, Identifiable, Sendable {
    struct Basic: Decodable, Sendable {
        /// 评论区 oid：视频为 aid，图文为 rid，纯文字为动态 id
        let commentIDStr: String?
        /// 评论区 type：1 视频 · 11 图文 · 17 纯文字 / 转发 · 12 专栏
        let commentType: Int?

        private enum CodingKeys: String, CodingKey {
            case commentIDStr = "comment_id_str"
            case commentType = "comment_type"
        }
    }

    let idStr: String
    /// DYNAMIC_TYPE_AV / DRAW / WORD / FORWARD / ARTICLE / LIVE_RCMD …
    let type: String
    let basic: Basic?
    let modules: DynamicModules
    /// 转发的原动态（接口不会再嵌套第二层）
    let orig: DynamicOrigin?

    var id: String { idStr }
    var isForward: Bool { type == "DYNAMIC_TYPE_FORWARD" }

    private enum CodingKeys: String, CodingKey {
        case type, basic, modules, orig
        case idStr = "id_str"
    }
}

struct DynamicOrigin: Decodable, Sendable {
    let type: String
    let modules: DynamicModules
}

struct DynamicModules: Decodable, Sendable {
    struct Author: Decodable, Sendable {
        struct Vip: Decodable, Sendable {
            let status: Int?
        }

        let mid: Int
        let name: String
        let face: String
        /// "2小时前"
        let pubTime: String?
        /// "投稿了视频"
        let pubAction: String?
        let vip: Vip?

        var isVIP: Bool { vip?.status == 1 }

        private enum CodingKeys: String, CodingKey {
            case mid, name, face, vip
            case pubTime = "pub_time"
            case pubAction = "pub_action"
        }
    }

    struct Stat: Decodable, Sendable {
        struct Count: Decodable, Sendable {
            let count: Int
        }

        struct Like: Decodable, Sendable {
            let count: Int
            let status: Bool?
        }

        let comment: Count?
        let forward: Count?
        let like: Like?
    }

    let author: Author?
    let dynamic: DynamicContent?
    let stat: Stat?

    private enum CodingKeys: String, CodingKey {
        case author = "module_author"
        case dynamic = "module_dynamic"
        case stat = "module_stat"
    }
}

struct DynamicContent: Decodable, Sendable {
    let desc: RichTextBlock?
    let major: Major?

    struct Major: Decodable, Sendable {
        struct Archive: Decodable, Sendable {
            struct Stat: Decodable, Sendable {
                /// "12.6万"
                let play: String?
                let danmaku: String?
            }

            let aid: String
            let bvid: String
            let title: String
            let cover: String
            /// "12:08"
            let durationText: String?
            let stat: Stat?

            private enum CodingKeys: String, CodingKey {
                case aid, bvid, title, cover, stat
                case durationText = "duration_text"
            }
        }

        struct Draw: Decodable, Sendable {
            struct Item: Decodable, Sendable {
                let src: String
                let width: Int?
                let height: Int?
            }

            let items: [Item]
        }

        /// 新版图文（features=itemOpusStyle）
        struct Opus: Decodable, Sendable {
            struct Pic: Decodable, Sendable {
                let url: String
                let width: Int?
                let height: Int?
            }

            let title: String?
            let summary: RichTextBlock?
            let pics: [Pic]?
        }

        struct Article: Decodable, Sendable {
            let title: String
            let desc: String?
            let covers: [String]?
        }

        let type: String
        let archive: Archive?
        let draw: Draw?
        let opus: Opus?
        let article: Article?
    }

    /// 正文：老格式在 desc，新版图文在 opus.summary
    var text: RichTextBlock? { desc ?? major?.opus?.summary }
    var title: String? { major?.opus?.title ?? major?.article?.title }

    var images: [DynamicImage] {
        if let items = major?.draw?.items { return items.map { DynamicImage(url: $0.src, width: $0.width, height: $0.height) } }
        if let pics = major?.opus?.pics { return pics.map { DynamicImage(url: $0.url, width: $0.width, height: $0.height) } }
        if let covers = major?.article?.covers { return covers.prefix(1).map { DynamicImage(url: $0, width: nil, height: nil) } }
        return []
    }

    func video(author: DynamicModules.Author?) -> VideoCard? {
        guard let archive = major?.archive else { return nil }
        return VideoCard(
            id: Int(archive.aid) ?? 0, bvid: archive.bvid, cid: nil, title: archive.title, pic: archive.cover,
            duration: archive.durationText?.durationSeconds ?? 0,
            owner: author.map { Owner(mid: $0.mid, name: $0.name, face: $0.face) },
            stat: VideoStat(view: archive.stat?.play?.biliNumber, danmaku: archive.stat?.danmaku?.biliNumber, like: nil, coin: nil, favorite: nil, share: nil, reply: nil)
        )
    }
}

struct DynamicImage: Hashable, Sendable {
    let url: String
    let width: Int?
    let height: Int?

    /// 宽高比，单图时限制在 3:4 ~ 16:9 之间
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return min(max(CGFloat(width) / CGFloat(height), 0.75), 1.78)
    }
}

/// 动态里的富文本：文字 + 表情（@、话题按普通文字显示）
struct RichTextBlock: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        struct Emoji: Decodable, Sendable {
            let iconURL: String

            private enum CodingKeys: String, CodingKey {
                case iconURL = "icon_url"
            }
        }

        let type: String
        let text: String
        let emoji: Emoji?
    }

    let text: String
    let richTextNodes: [Node]?

    /// "[doge]" → 图片地址，交给 RichText 混排
    var emotes: [String: String] {
        var map: [String: String] = [:]
        for node in richTextNodes ?? [] {
            if let url = node.emoji?.iconURL { map[node.text] = url }
        }
        return map
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case richTextNodes = "rich_text_nodes"
    }
}

/// /x/polymer/web-dynamic/v1/portal：最近有更新的关注 UP 主
struct DynamicPortal: Decodable, Sendable {
    struct UpList: Decodable, Sendable {
        let items: [DynamicUp]?
    }

    let upList: UpList?

    private enum CodingKeys: String, CodingKey {
        case upList = "up_list"
    }
}

struct DynamicUp: Decodable, Identifiable, Sendable {
    let mid: Int
    let uname: String
    let face: String
    let hasUpdate: Bool?

    var id: Int { mid }

    private enum CodingKeys: String, CodingKey {
        case mid, uname, face
        case hasUpdate = "has_update"
    }
}

struct DynamicUpdate: Decodable, Sendable {
    let updateNum: Int

    private enum CodingKeys: String, CodingKey {
        case updateNum = "update_num"
    }
}

extension String {
    /// "12.6万" / "1.2亿" / "3421" → 整数
    var biliNumber: Int {
        if hasSuffix("亿"), let value = Double(dropLast()) { return Int(value * 100_000_000) }
        if hasSuffix("万"), let value = Double(dropLast()) { return Int(value * 10_000) }
        return Int(self) ?? 0
    }
}
