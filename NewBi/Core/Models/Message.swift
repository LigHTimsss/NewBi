import Foundation

// MARK: - 未读数

/// /x/msgfeed/unread
struct MsgUnread: Decodable, Sendable {
    let at: Int?
    let like: Int?
    let reply: Int?
    let sysMsg: Int?

    private enum CodingKeys: String, CodingKey {
        case at, like, reply
        case sysMsg = "sys_msg"
    }
}

/// /session_svr/v1/session_svr/single_unread
struct DMUnread: Decodable, Sendable {
    let followUnread: Int?
    let unfollowUnread: Int?
    let bizMsgFollowUnread: Int?
    let bizMsgUnfollowUnread: Int?

    var total: Int { (followUnread ?? 0) + (unfollowUnread ?? 0) + (bizMsgFollowUnread ?? 0) + (bizMsgUnfollowUnread ?? 0) }

    private enum CodingKeys: String, CodingKey {
        case followUnread = "follow_unread"
        case unfollowUnread = "unfollow_unread"
        case bizMsgFollowUnread = "biz_msg_follow_unread"
        case bizMsgUnfollowUnread = "biz_msg_unfollow_unread"
    }
}

// MARK: - 回复 / @ / 赞 / 系统通知

enum NoticeKind: String, Hashable, Sendable, CaseIterable, Identifiable {
    case reply, at, like, system

    var id: Self { self }

    var title: String {
        switch self {
        case .reply: "回复我的"
        case .at: "@ 我的"
        case .like: "收到的赞"
        case .system: "系统通知"
        }
    }

    var icon: String {
        switch self {
        case .reply: "bubble.left.and.text.bubble.right.fill"
        case .at: "at"
        case .like: "hand.thumbsup.fill"
        case .system: "bell.fill"
        }
    }

    /// 游标里「时间」参数的名字
    var timeKey: String {
        switch self {
        case .reply: "reply_time"
        case .at: "at_time"
        case .like: "like_time"
        case .system: "cursor"
        }
    }
}

struct NoticeUser: Decodable, Hashable, Sendable {
    let mid: Int
    let nickname: String
    let avatar: String?
}

struct NoticeCursor: Decodable, Sendable {
    let isEnd: Bool
    let id: Int
    let time: Int

    private enum CodingKeys: String, CodingKey {
        case isEnd = "is_end"
        case id, time
    }
}

/// 三种互动通知共用的「被互动对象」
struct NoticeTarget: Decodable, Sendable {
    let business: String?
    let title: String?
    let desc: String?
    let image: String?
    let uri: String?
    /// 回复 / @：对方说的话
    let sourceContent: String?
    /// 回复：被回复的我的那条评论
    let targetReplyContent: String?

    private enum CodingKeys: String, CodingKey {
        case business, title, desc, image, uri
        case sourceContent = "source_content"
        case targetReplyContent = "target_reply_content"
    }
}

/// /x/msgfeed/reply 和 /x/msgfeed/at
struct InteractionPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: Int
        let user: NoticeUser?
        let item: NoticeTarget
        let replyTime: Int?
        let atTime: Int?

        private enum CodingKeys: String, CodingKey {
            case id, user, item
            case replyTime = "reply_time"
            case atTime = "at_time"
        }
    }

    let cursor: NoticeCursor?
    let items: [Item]?
}

/// /x/msgfeed/like（列表在 total 里）
struct LikePage: Decodable, Sendable {
    struct Total: Decodable, Sendable {
        let cursor: NoticeCursor?
        let items: [Item]?
    }

    struct Item: Decodable, Sendable {
        let id: Int
        let users: [NoticeUser]?
        let item: NoticeTarget
        let counts: Int?
        let likeTime: Int?

        private enum CodingKeys: String, CodingKey {
            case id, users, item, counts
            case likeTime = "like_time"
        }
    }

    let total: Total?
}

/// 系统通知。首页 data 是 `{system_notify_list: [...]}`，后续页 data 直接是数组，两种都认
struct SystemNoticePage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: Int
        let cursor: Int?
        let title: String?
        let content: String?
        let timeAt: String?

        private enum CodingKeys: String, CodingKey {
            case id, cursor, title, content
            case timeAt = "time_at"
        }
    }

    let items: [Item]

    private enum CodingKeys: String, CodingKey {
        case list = "system_notify_list"
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            items = try keyed.decodeIfPresent([Item].self, forKey: .list) ?? []
        } else {
            items = try decoder.singleValueContainer().decode([Item].self)
        }
    }
}

/// 列表里显示的一条通知（四种来源统一成这个）
struct Notice: Identifiable, Sendable {
    let id: Int
    /// 点赞可能是多人
    let users: [NoticeUser]
    let userCount: Int
    /// 「回复了我的评论」「赞了我的视频」…
    let action: String
    /// 对方说的话（回复 / @）；系统通知的正文
    let content: String?
    /// 被互动的我的内容（评论原文或稿件标题）
    let quote: String?
    let image: String?
    let link: URL?
    let date: Date?
    /// 系统通知的标题
    let title: String?

    init(reply item: InteractionPage.Item) {
        let target = item.item
        let quoted = target.targetReplyContent.nonEmpty
        id = item.id
        users = item.user.map { [$0] } ?? []
        userCount = users.count
        action = quoted != nil ? "回复了我的评论" : "评论了我的\(target.business.nonEmpty ?? "内容")"
        content = target.sourceContent.nonEmpty
        quote = quoted ?? target.title.nonEmpty
        image = target.image.nonEmpty
        link = target.uri.nonEmpty.flatMap(AppLink.web)
        date = item.replyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        title = nil
    }

    init(at item: InteractionPage.Item) {
        let target = item.item
        id = item.id
        users = item.user.map { [$0] } ?? []
        userCount = users.count
        action = "在\(target.business.nonEmpty ?? "评论")中 @ 了我"
        content = target.sourceContent.nonEmpty
        quote = target.title.nonEmpty
        image = target.image.nonEmpty
        link = target.uri.nonEmpty.flatMap(AppLink.web)
        date = item.atTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        title = nil
    }

    init(like item: LikePage.Item) {
        let target = item.item
        let business = target.business.nonEmpty ?? "内容"
        id = item.id
        users = item.users ?? []
        userCount = max(item.counts ?? users.count, users.count)
        action = userCount > 1 ? "等 \(userCount) 人赞了我的\(business)" : "赞了我的\(business)"
        content = nil
        quote = target.title.nonEmpty ?? target.desc.nonEmpty
        image = target.image.nonEmpty
        link = target.uri.nonEmpty.flatMap(AppLink.web)
        date = item.likeTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        title = nil
    }

    init(system item: SystemNoticePage.Item) {
        id = item.id
        users = []
        userCount = 0
        action = ""
        content = item.content.nonEmpty
        quote = nil
        image = nil
        link = nil
        date = item.timeAt.flatMap(Self.parseTime)
        title = item.title.nonEmpty
    }

    private static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

// MARK: - 私信

/// 私信会话的对象（用户或系统账号）
struct ChatPeer: Hashable, Sendable {
    let id: Int
    let name: String
    let face: String?
    var sessionType = 1
    /// 系统会话（UP 主小助手等）只能看不能回
    var isSystem = false
}

struct ChatSessionList: Decodable, Sendable {
    let sessionList: [ChatSession]?
    let hasMore: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionList = "session_list"
        case hasMore = "has_more"
    }
}

struct ChatSession: Decodable, Identifiable, Sendable {
    struct AccountInfo: Decodable, Sendable {
        let name: String?
        let picURL: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case picURL = "pic_url"
        }
    }

    let talkerID: Int
    let sessionType: Int
    let unreadCount: Int?
    /// 微秒
    let sessionTs: Int?
    let topTs: Int?
    let systemMsgType: Int?
    let accountInfo: AccountInfo?
    let groupName: String?
    let groupCover: String?
    let lastMsg: ChatMessage?

    var id: String { "\(sessionType)-\(talkerID)" }
    var isPinned: Bool { (topTs ?? 0) > 0 }
    var isSystem: Bool { (systemMsgType ?? 0) != 0 }
    var date: Date? { sessionTs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) } }

    private enum CodingKeys: String, CodingKey {
        case talkerID = "talker_id"
        case sessionType = "session_type"
        case unreadCount = "unread_count"
        case sessionTs = "session_ts"
        case topTs = "top_ts"
        case systemMsgType = "system_msg_type"
        case accountInfo = "account_info"
        case groupName = "group_name"
        case groupCover = "group_cover"
        case lastMsg = "last_msg"
    }
}

/// /account/v1/user/cards
struct UserCardLite: Decodable, Sendable {
    let mid: Int
    let name: String
    let face: String?
}

struct ChatMessagePage: Decodable, Sendable {
    let messages: [ChatMessage]?
    let hasMore: Int?

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

struct ChatMessage: Decodable, Identifiable, Sendable {
    let senderUID: Int
    let msgType: Int
    /// JSON 字符串，结构随 msg_type 变化
    let content: String
    let seqno: Int
    let timestamp: Int
    /// 1 为已撤回。收到撤回指令时在本地改写
    var msgStatus: Int?
    /// 消息的全局 key：撤回指令的 content 就是被撤回那条的 key
    let msgKey: Int?

    var id: Int { seqno }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    /// 被撤回
    var isRecalled: Bool { msgStatus == 1 }
    /// 撤回指令本身（content 是被撤回消息的 key），不显示
    var isRecallCommand: Bool { msgType == 5 }

    /// 撤回指令要撤回的那条消息的 key（content 可能是裸数字，也可能带引号）
    var recalledKey: Int? {
        guard isRecallCommand else { return nil }
        return Int(content.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")))
    }

    private enum CodingKeys: String, CodingKey {
        case senderUID = "sender_uid"
        case msgType = "msg_type"
        case content
        case seqno = "msg_seqno"
        case timestamp
        case msgStatus = "msg_status"
        case msgKey = "msg_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        senderUID = try container.decode(Int.self, forKey: .senderUID)
        msgType = try container.decode(Int.self, forKey: .msgType)
        content = try container.decode(String.self, forKey: .content)
        seqno = try container.decode(Int.self, forKey: .seqno)
        timestamp = try container.decode(Int.self, forKey: .timestamp)
        msgStatus = try container.decodeIfPresent(Int.self, forKey: .msgStatus)
        // 数字或字符串都接受；解不出来也不影响这条消息本身
        if let number = try? container.decodeIfPresent(Int.self, forKey: .msgKey) {
            msgKey = number
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .msgKey) {
            msgKey = Int(text)
        } else {
            msgKey = nil
        }
    }

    init(senderUID: Int, text: String, seqno: Int, timestamp: Int) {
        self.senderUID = senderUID
        self.msgType = 1
        self.content = Self.encodeText(text)
        self.seqno = seqno
        self.timestamp = timestamp
        self.msgStatus = 0
        self.msgKey = nil
    }

    static func encodeText(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["content": text])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private var fields: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
    }

    /// 解析后的消息内容
    var body: Body {
        let json = fields
        func string(_ key: String) -> String? { (json[key] as? String).nonEmpty }
        switch msgType {
        case 1:
            return .text(string("content") ?? content)
        case 2, 6:
            return .image(url: string("url"), width: json["width"] as? Double, height: json["height"] as? Double)
        case 7, 11, 12, 14:
            // 分享 / 视频推送 / 专栏推送
            let bvid = string("bvid")
            let link = bvid.flatMap(AppLink.video) ?? string("url").flatMap(AppLink.web) ?? string("jump_url").flatMap(AppLink.web)
            return .card(title: string("title") ?? "分享", text: string("desc") ?? string("author"), cover: string("thumb") ?? string("cover"), link: link)
        case 10:
            // 通知（UP 主小助手、系统消息）
            let link = string("jump_uri").flatMap(AppLink.web) ?? string("jump_uri_config").flatMap(AppLink.web)
            return .notice(title: string("title") ?? "通知", text: string("text") ?? "", action: string("jump_text"), link: link)
        default:
            return .text(string("content") ?? string("title") ?? string("text") ?? "[暂不支持的消息类型]")
        }
    }

    enum Body {
        case text(String)
        case image(url: String?, width: Double?, height: Double?)
        case card(title: String, text: String?, cover: String?, link: URL?)
        case notice(title: String, text: String, action: String?, link: URL?)
    }

    /// 会话列表里的一行预览
    var preview: String {
        if isRecalled { return "撤回了一条消息" }
        switch body {
        case .text(let text): return text
        case .image: return "[图片]"
        case .card(let title, _, _, _): return "[分享] \(title)"
        case .notice(let title, let text, _, _): return text.isEmpty ? title : "\(title)：\(text)"
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
