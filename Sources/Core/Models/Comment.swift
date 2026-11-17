import Foundation

struct Reply: Decodable, Identifiable, Sendable {
    struct Member: Decodable, Sendable {
        struct Level: Decodable, Sendable {
            let currentLevel: Int

            private enum CodingKeys: String, CodingKey {
                case currentLevel = "current_level"
            }
        }

        struct Vip: Decodable, Sendable {
            let vipStatus: Int
        }

        /// 接口里是字符串
        let mid: String?
        let uname: String
        let avatar: String
        let levelInfo: Level?
        let vip: Vip?

        var midValue: Int? { mid.flatMap(Int.init) }

        private enum CodingKeys: String, CodingKey {
            case mid, uname, avatar, vip
            case levelInfo = "level_info"
        }
    }

    struct Content: Decodable, Sendable {
        struct Emote: Decodable, Sendable {
            let url: String
        }

        struct Picture: Decodable, Sendable {
            let imgSrc: String

            private enum CodingKeys: String, CodingKey {
                case imgSrc = "img_src"
            }
        }

        /// 正文里被 B 站识别成链接的关键词（视频标题、搜索词等）
        struct Jump: Decodable, Sendable {
            let title: String?
            let pcURL: String?

            private enum CodingKeys: String, CodingKey {
                case title
                case pcURL = "pc_url"
            }
        }

        let message: String
        let emote: [String: Emote]?
        let pictures: [Picture]?
        /// "@名字" 里的名字 → mid
        let atNameToMid: [String: Int]?
        let jumpURL: [String: Jump]?

        private enum CodingKeys: String, CodingKey {
            case message, emote, pictures
            case atNameToMid = "at_name_to_mid"
            case jumpURL = "jump_url"
        }

        /// "[doge]" → 图片地址
        var emoteURLs: [String: String] { emote?.mapValues(\.url) ?? [:] }

        var links: RichText.Links {
            RichText.Links(mentions: atNameToMid ?? [:], jumps: jumpURL?.compactMapValues(\.pcURL) ?? [:])
        }
    }

    struct Control: Decodable, Sendable {
        let location: String?
        let timeDesc: String?
        let subReplyEntryText: String?

        private enum CodingKeys: String, CodingKey {
            case location
            case timeDesc = "time_desc"
            case subReplyEntryText = "sub_reply_entry_text"
        }
    }

    let rpid: Int
    let ctime: Int
    let like: Int
    /// 楼中楼回复数
    let rcount: Int
    /// 1 = 我已点赞
    let action: Int?
    let member: Member
    let content: Content
    /// 楼中楼预览（最多 3 条）
    let replies: [Reply]?
    let replyControl: Control?

    var id: Int { rpid }
    var isVIP: Bool { member.vip?.vipStatus == 1 }

    /// "3天前 · 广东"
    var metaText: String {
        let time = replyControl?.timeDesc?.replacingOccurrences(of: "发布", with: "")
            ?? Date(timeIntervalSince1970: TimeInterval(ctime)).formatted(.relative(presentation: .named))
        guard let location = replyControl?.location?.replacingOccurrences(of: "IP属地：", with: ""), !location.isEmpty else { return time }
        return "\(time) · \(location)"
    }

    private enum CodingKeys: String, CodingKey {
        case rpid, ctime, like, rcount, action, member, content, replies
        case replyControl = "reply_control"
    }
}

struct ReplyPage: Decodable, Sendable {
    struct Cursor: Decodable, Sendable {
        struct Pagination: Decodable, Sendable {
            let nextOffset: String?

            private enum CodingKeys: String, CodingKey {
                case nextOffset = "next_offset"
            }
        }

        let isEnd: Bool
        let allCount: Int?
        let paginationReply: Pagination?

        private enum CodingKeys: String, CodingKey {
            case isEnd = "is_end"
            case allCount = "all_count"
            case paginationReply = "pagination_reply"
        }
    }

    let cursor: Cursor
    let replies: [Reply]?
    /// 置顶（UP 主置顶等）
    let topReplies: [Reply]?

    private enum CodingKeys: String, CodingKey {
        case cursor, replies
        case topReplies = "top_replies"
    }
}

struct SubReplyPage: Decodable, Sendable {
    struct Page: Decodable, Sendable {
        let count: Int
        let num: Int
        let size: Int
    }

    let page: Page
    let replies: [Reply]?
}

struct ReplyAddResult: Decodable, Sendable {
    let reply: Reply?
}
