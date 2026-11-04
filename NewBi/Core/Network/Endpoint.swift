import Foundation

struct Endpoint: Sendable {
    var host = "https://api.bilibili.com"
    var path: String
    var query: [String: String] = [:]
    /// 是否需要 WBI 签名
    var signed = false
}

extension Endpoint {
    static let passport = "https://passport.bilibili.com"

    // MARK: 基础

    static let nav = Endpoint(path: "/x/web-interface/nav")
    static let navStat = Endpoint(path: "/x/web-interface/nav/stat")
    static let fingerSpi = Endpoint(path: "/x/frontend/finger/spi")

    // MARK: 登录

    static let qrGenerate = Endpoint(host: passport, path: "/x/passport-login/web/qrcode/generate")
    static func qrPoll(key: String) -> Endpoint {
        Endpoint(host: passport, path: "/x/passport-login/web/qrcode/poll", query: ["qrcode_key": key])
    }

    // MARK: 首页

    static func recommend(page: Int) -> Endpoint {
        Endpoint(
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            query: ["fresh_type": "4", "ps": "12", "fresh_idx": "\(page)", "fresh_idx_1h": "\(page)", "brush": "\(page)"],
            signed: true
        )
    }

    static func popular(page: Int) -> Endpoint {
        Endpoint(path: "/x/web-interface/popular", query: ["pn": "\(page)", "ps": "20"])
    }

    // MARK: 视频

    static func view(bvid: String) -> Endpoint {
        Endpoint(path: "/x/web-interface/view", query: ["bvid": bvid])
    }

    static func related(bvid: String) -> Endpoint {
        Endpoint(path: "/x/web-interface/archive/related", query: ["bvid": bvid])
    }

    /// - Parameter dash: true 取 DASH（fnval=4048 = DASH|HDR|4K|杜比音频|杜比视界|8K|AV1）；
    ///   false 取 MP4 单文件（fnval=1，兜底用，画质较低）
    static func playURL(bvid: String, cid: Int, qn: Int, dash: Bool) -> Endpoint {
        var query = ["bvid": bvid, "cid": "\(cid)", "qn": "\(qn)", "fourk": "1"]
        if dash {
            query["fnval"] = "4048"
            query["fnver"] = "0"
        } else {
            query["fnval"] = "1"
            query["platform"] = "html5"
            query["high_quality"] = "1"
        }
        return Endpoint(path: "/x/player/wbi/playurl", query: query, signed: true)
    }

    /// 在线人数（全屏标题下「N 人正在观看」）
    static func onlineTotal(bvid: String, cid: Int) -> Endpoint {
        Endpoint(path: "/x/player/online/total", query: ["bvid": bvid, "cid": "\(cid)"])
    }

    /// 发送弹幕（POST，需 csrf = bili_jct）
    static let postDanmaku = Endpoint(path: "/x/v2/dm/post")

    // MARK: 搜索

    static let searchSquare = Endpoint(path: "/x/web-interface/wbi/search/square", query: ["limit": "10"], signed: true)

    static func searchSuggest(_ term: String) -> Endpoint {
        Endpoint(host: "https://s.search.bilibili.com", path: "/main/suggest", query: ["term": term, "main_ver": "v1"])
    }

    /// - Parameters:
    ///   - type: video / bili_user
    ///   - order: 仅视频：totalrank 综合 · click 播放 · pubdate 最新 · dm 弹幕
    static func search(keyword: String, type: String, page: Int, order: String?) -> Endpoint {
        var query = ["keyword": keyword, "search_type": type, "page": "\(page)"]
        if let order { query["order"] = order }
        return Endpoint(path: "/x/web-interface/wbi/search/type", query: query, signed: true)
    }

    // MARK: 历史记录（需登录）

    /// 游标分页：首页三个游标都传 0；type=archive 只取视频
    static func history(max: Int, viewAt: Int, business: String) -> Endpoint {
        Endpoint(path: "/x/web-interface/history/cursor", query: [
            "ps": "20", "type": "archive", "max": "\(max)", "view_at": "\(viewAt)", "business": business,
        ])
    }

    /// 删除一条（POST，kid = "archive_<aid>"）
    static let historyDelete = Endpoint(path: "/x/v2/history/delete")
    /// 清空（POST）
    static let historyClear = Endpoint(path: "/x/v2/history/clear")
    /// 上报播放进度（POST，progress 为秒）
    static let historyReport = Endpoint(path: "/x/v2/history/report")

    /// 播放器信息：含上次看到的位置，用于续播
    static func playerInfo(bvid: String, cid: Int) -> Endpoint {
        Endpoint(path: "/x/player/wbi/v2", query: ["bvid": bvid, "cid": "\(cid)"], signed: true)
    }

    // MARK: 动态（需登录）

    /// - Parameters:
    ///   - type: all 全部 · video 视频投稿
    ///   - offset: 上一页返回的 offset，首页为空
    static func dynamicFeed(type: String, offset: String) -> Endpoint {
        Endpoint(path: "/x/polymer/web-dynamic/v1/feed/all", query: [
            "type": type, "offset": offset, "features": "itemOpusStyle", "timezone_offset": "-480",
        ])
    }

    /// 最近有更新的关注 UP 主（头像条）
    static let dynamicPortal = Endpoint(path: "/x/polymer/web-dynamic/v1/portal")

    /// 自 baseline 以来的新动态数（底栏红点）
    static func dynamicUpdate(baseline: String) -> Endpoint {
        Endpoint(path: "/x/polymer/web-dynamic/v1/feed/all/update", query: ["type": "all", "update_baseline": baseline])
    }

    /// 点赞动态（POST JSON，csrf 放在 query）
    static func dynamicThumb(csrf: String) -> Endpoint {
        Endpoint(path: "/x/dynamic/feed/dyn/thumb", query: ["csrf": csrf])
    }

    // MARK: 点赞 / 投币（需登录）

    /// 我和这个视频的关系：是否已赞、已投几枚币、是否已收藏
    static func archiveRelation(aid: Int) -> Endpoint {
        Endpoint(path: "/x/web-interface/archive/relation", query: ["aid": "\(aid)"])
    }

    /// 点赞 / 取消点赞（POST，aid、like=1 赞 / 2 取消）
    static let archiveLike = Endpoint(path: "/x/web-interface/archive/like")
    /// 投币（POST，aid、multiply=1/2、select_like=0/1 同时点赞）
    static let coinAdd = Endpoint(path: "/x/web-interface/coin/add")
    /// 一键三连：点赞 + 投 2 币 + 收藏到默认收藏夹（POST，aid）
    static let archiveTriple = Endpoint(path: "/x/web-interface/archive/like/triple")

    // MARK: 稍后再看（需登录）

    static let watchLater = Endpoint(path: "/x/v2/history/toview")
    /// 添加（POST，aid）
    static let watchLaterAdd = Endpoint(path: "/x/v2/history/toview/add")
    /// 删除（POST，aid；或 viewed=true 删除全部已看完）
    static let watchLaterDelete = Endpoint(path: "/x/v2/history/toview/del")
    /// 清空（POST）
    static let watchLaterClear = Endpoint(path: "/x/v2/history/toview/clear")

    // MARK: 收藏（需登录）

    /// 我创建的收藏夹（带封面，分页）
    static func favFolders(mid: Int, page: Int) -> Endpoint {
        Endpoint(path: "/x/v3/fav/folder/created/list", query: ["up_mid": "\(mid)", "pn": "\(page)", "ps": "20"])
    }

    /// 全部收藏夹 + 某视频是否已在其中（fav_state）
    static func favFoldersForVideo(mid: Int, aid: Int) -> Endpoint {
        Endpoint(path: "/x/v3/fav/folder/created/list-all", query: ["up_mid": "\(mid)", "type": "2", "rid": "\(aid)"])
    }

    /// 收藏夹内容
    /// - Parameter order: mtime 最近收藏 · view 最多播放 · pubtime 最新投稿
    static func favResources(mediaID: Int, page: Int, order: String) -> Endpoint {
        Endpoint(path: "/x/v3/fav/resource/list", query: [
            "media_id": "\(mediaID)", "pn": "\(page)", "ps": "20", "order": order, "type": "0", "tid": "0", "platform": "web",
        ])
    }

    /// 某视频是否已收藏
    static func favoured(aid: Int) -> Endpoint {
        Endpoint(path: "/x/v2/fav/video/favoured", query: ["aid": "\(aid)"])
    }

    /// 加入 / 移出收藏夹（POST，add_media_ids / del_media_ids 逗号分隔）
    static let favDeal = Endpoint(path: "/x/v3/fav/resource/deal")

    // MARK: UP 主空间

    /// 名片：头像、签名、认证、粉丝 / 关注 / 获赞、头图、是否已关注（不需要 WBI，风控较松）
    static func spaceCard(mid: Int) -> Endpoint {
        Endpoint(path: "/x/web-interface/card", query: ["mid": "\(mid)", "photo": "true"])
    }

    /// 置顶视频（没有时返回 code 53016）
    static func spaceTop(mid: Int) -> Endpoint {
        Endpoint(path: "/x/space/top/arc", query: ["vmid": "\(mid)"])
    }

    /// 代表作
    static func masterpiece(mid: Int) -> Endpoint {
        Endpoint(path: "/x/space/masterpiece", query: ["vmid": "\(mid)"])
    }

    /// 投稿列表
    /// - Parameter order: pubdate 最新发布 · click 最多播放 · stow 最多收藏
    static func spaceVideos(mid: Int, page: Int, order: String) -> Endpoint {
        var query = ["mid": "\(mid)", "ps": "30", "pn": "\(page)", "order": order, "platform": "web", "web_location": "1550101"]
        query.merge(riskParams) { $1 }
        return Endpoint(path: "/x/space/wbi/arc/search", query: query, signed: true)
    }

    /// 与某人的关系（需登录）：attribute 0 未关注 · 2 已关注 · 6 互相关注 · 128 已拉黑
    static func relation(fid: Int) -> Endpoint {
        Endpoint(path: "/x/relation", query: ["fid": "\(fid)"])
    }

    /// 关注 / 取消关注（POST，act 1 关注 · 2 取消）
    static let relationModify = Endpoint(path: "/x/relation/modify")

    /// 空间投稿接口校验浏览器指纹参数，缺少时常见 -352
    private static let riskParams: [String: String] = [
        "dm_img_list": "[]",
        "dm_img_str": String(Data("WebGL 1.0 (OpenGL ES 2.0 Chromium)".utf8).base64EncodedString().dropLast(2)),
        "dm_cover_img_str": String(Data("ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)Google Inc. (Apple)".utf8).base64EncodedString().dropLast(2)),
        "dm_img_inter": #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#,
    ]

    // MARK: 评论

    /// - Parameters:
    ///   - mode: 3 按热度 · 2 按时间
    ///   - offset: 上一页返回的 next_offset，首页为空
    ///   - type: 评论区类型：1 视频 · 11 图文动态 · 17 文字 / 转发动态 · 12 专栏
    static func replies(oid: Int, type: Int = 1, mode: Int, offset: String) -> Endpoint {
        let pagination = "{\"offset\":\"\(offset.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        return Endpoint(
            path: "/x/v2/reply/wbi/main",
            query: ["oid": "\(oid)", "type": "\(type)", "mode": "\(mode)", "pagination_str": pagination, "plat": "1", "web_location": "1315875"],
            signed: true
        )
    }

    /// 楼中楼
    static func subReplies(oid: Int, type: Int = 1, root: Int, page: Int) -> Endpoint {
        Endpoint(path: "/x/v2/reply/reply", query: ["oid": "\(oid)", "type": "\(type)", "root": "\(root)", "ps": "20", "pn": "\(page)"])
    }

    /// 点赞评论（POST）
    static let replyAction = Endpoint(path: "/x/v2/reply/action")
    /// 发评论（POST）
    static let replyAdd = Endpoint(path: "/x/v2/reply/add")

    /// 弹幕分段（Protobuf，每段 6 分钟）
    static func danmakuSegment(cid: Int, index: Int) -> Endpoint {
        Endpoint(path: "/x/v2/dm/web/seg.so", query: ["type": "1", "oid": "\(cid)", "segment_index": "\(index)"])
    }
}
