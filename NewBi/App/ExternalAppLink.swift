import Foundation

/// 外部唤起独立于正文富文本路由；只解释支持的目的地，不执行任意 URL。
enum ExternalAppLink: Equatable, Sendable {
    enum VideoID: Equatable, Sendable {
        case bv(String)
        case av(Int)
    }
    case home
    case video(VideoID, cid: Int?, page: Int?)
    case space(Int)
    case live(Int)
    case search

    static func parse(_ url: URL) -> Self? { parse(url, depth: 0) }

    private static func parse(_ url: URL, depth: Int) -> Self? {
        guard depth <= 2, url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let host = parts.host?.lowercased() ?? ""
        var query: [String: String] = [:]
        let keys: Set<String> = ["bvid", "aid", "avid", "cid", "p", "page", "url"]
        for item in parts.queryItems ?? [] where keys.contains(item.name) {
            // 不使用 uniqueKeysWithValues：重复参数属于无效输入，不能导致崩溃。
            guard query[item.name] == nil, let value = item.value else { return nil }
            query[item.name] = value
        }
        let path = parts.path.split(separator: "/").map(String.init)
        if scheme == "https" || scheme == "http" {
            // 仅供 browser?url= 包装链接解析；注册 Scheme 不会接管 HTTPS 通用链接。
            if ["www.bilibili.com", "m.bilibili.com", "bilibili.com"].contains(host),
               path.count == 2, path[0] == "video" {
                return video(path[1], query: query)
            }
            if host == "space.bilibili.com", path.count == 1, let id = positive(path[0]) { return .space(id) }
            if host == "live.bilibili.com", path.count == 1, let id = positive(path[0]) { return .live(id) }
            return nil
        }
        guard scheme == "bilibili" || scheme == "newbi" else { return nil }
        switch host {
        case "", "root", "home": return path.isEmpty ? .home : nil
        case "video":
            guard path.count <= 1 else { return nil }
            return video(path.first ?? query["bvid"] ?? query["aid"] ?? query["avid"] ?? "", query: query)
        case "space":
            guard path.count == 1, let id = positive(path[0]) else { return nil }
            return .space(id)
        case "live":
            guard path.count == 1, let id = positive(path[0]) else { return nil }
            return .live(id)
        case "search": return path.isEmpty ? .search : nil
        case "browser":
            guard path.isEmpty, let raw = query["url"], let nested = URL(string: raw) else { return nil }
            return parse(nested, depth: depth + 1)
        default: return nil
        }
    }

    private static func video(_ raw: String, query: [String: String]) -> Self? {
        let id: VideoID
        if raw.utf8.count == 12, raw.hasPrefix("BV"),
           raw.utf8.dropFirst(2).allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            id = .bv(raw)
        } else if let aid = positive(raw.lowercased().hasPrefix("av") ? String(raw.dropFirst(2)) : raw) {
            id = .av(aid)
        } else { return nil }
        let cid = query["cid"].flatMap(positive)
        let page = (query["p"] ?? query["page"]).flatMap(positive)
        if query["cid"] != nil && cid == nil { return nil }
        if (query["p"] != nil || query["page"] != nil) && page == nil { return nil }
        if let p = query["p"], let other = query["page"], positive(p) != positive(other) { return nil }
        return .video(id, cid: cid, page: page)
    }

    private static func positive(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(raw), value > 0 else { return nil }
        return value
    }
}

struct ExternalLinkRequest {
    let id = UUID()
    let url: URL
}
