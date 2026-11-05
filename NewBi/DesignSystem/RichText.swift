import SwiftUI

/// 评论正文：文字与 B 站表情（`[doge]`）图文混排。
/// 表情图走 ImagePipeline（服务端缩放 + 内存缓存），同一表情全局只下载一次。
/// 另外把 @提及、B 站识别的关键词、网址、BV 号、时间点（05:12）做成可点的强调色链接，
/// 点击走 `AppLink` 的内部地址，由上层的 openURL 处理（进空间、打开视频、跳到时间点）。
struct RichText: View {
    /// 正文里的可点内容
    struct Links: Sendable {
        /// "@名字" 里的名字 → mid
        var mentions: [String: Int] = [:]
        /// 关键词 → 网址
        var jumps: [String: String] = [:]
        /// 视频评论里把 05:12 这样的时间点做成「跳到该位置」
        var timestamps = false
    }

    private enum Segment {
        case text(String)
        case emote(String)
    }

    private let segments: [Segment]
    private let emotes: [String: String]
    private let links: Links
    private let size: CGFloat
    @State private var images: [String: UIImage] = [:]
    @Environment(\.displayScale) private var scale
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme

    init(_ message: String, emotes: [String: String], links: Links = Links(), size: CGFloat = 15) {
        self.emotes = emotes
        self.links = links
        self.size = size
        segments = Self.parse(message, keys: Set(emotes.keys))
    }

    var body: some View {
        let linkColor = accent.accentText(scheme)
        return segments.reduce(Text(verbatim: "")) { (partial: Text, segment: Segment) -> Text in
            switch segment {
            case .text(let text):
                Text("\(partial)\(Text(Self.linkify(text, links: links, color: linkColor)))")
            case .emote(let key):
                // 内存里已有的表情直接用：不必先显示文字占位、等异步回填后再排一次版
                if let image = images[key] ?? cachedEmote(key) {
                    Text("\(partial)\(Text(Image(uiImage: image)).baselineOffset(-size * 0.22))")
                } else {
                    Text("\(partial)\(Text(verbatim: key))")
                }
            }
        }
        .font(.system(size: size))
        .lineSpacing(3)
        .task(id: emotes.keys.sorted()) { await loadEmotes() }
    }

    private var emotePoint: CGFloat { size * 1.35 }

    private func emoteRequest(_ key: String) -> URL? {
        let pixel = emotePoint * scale
        return emotes[key]?.biliResized(CGSize(width: pixel, height: pixel))
    }

    /// 以像素宽度换算 scale，让表情在文字里正好是 point 大小
    private func sized(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: CGFloat(cg.width) / emotePoint, orientation: .up)
    }

    private func cachedEmote(_ key: String) -> UIImage? {
        emoteRequest(key).flatMap { ImageMemory.shared.image(for: $0) }.flatMap { sized($0) }
    }

    /// 没缓存的表情并发取回，全部到齐后一次写入（每回来一张就写一次会让整段正文重算好几遍）
    private func loadEmotes() async {
        let needed = emotes.keys.filter { images[$0] == nil && cachedEmote($0) == nil }
        guard !needed.isEmpty else { return }
        let pixel = emotePoint * scale
        let requests = needed.compactMap { key in emoteRequest(key).map { (key, $0) } }
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (key, url) in requests {
                group.addTask { (key, await ImagePipeline.shared.image(for: url, maxPixel: pixel)) }
            }
            for await (key, image) in group {
                if let image, let fitted = sized(image) { loaded[key] = fitted }
            }
        }
        guard !loaded.isEmpty, !Task.isCancelled else { return }
        images.merge(loaded) { _, new in new }
    }

    // MARK: 链接

    private final class Linked {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// 解析结果按「文字 + 链接信息」缓存（不含颜色，颜色显示时再上）：评论重绘、表情回填时不再重新扫描正则
    private static let linkCache: NSCache<NSString, Linked> = {
        let cache = NSCache<NSString, Linked>()
        cache.countLimit = 600
        return cache
    }()

    /// 把一段纯文字里的可点内容变成带 link 的 AttributedString，链接上强调色
    static func linkify(_ text: String, links: Links, color: Color) -> AttributedString {
        let mentions = links.mentions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let jumps = links.jumps.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let key = "\(links.timestamps ? 1 : 0)|\(mentions)|\(jumps)|\(text)" as NSString
        var result: AttributedString
        if let hit = linkCache.object(forKey: key) {
            result = hit.value
        } else {
            result = scan(text, links: links)
            linkCache.setObject(Linked(result), forKey: key)
        }
        let linkRanges = result.runs.filter { $0.link != nil }.map(\.range)
        for range in linkRanges { result[range].foregroundColor = color }
        return result
    }

    /// 按出现位置从左到右找出可点内容（不重叠），不上颜色
    private static func scan(_ text: String, links: Links) -> AttributedString {
        var matches: [(range: Range<String.Index>, url: URL)] = []
        func add(_ range: Range<String.Index>, _ url: URL?) {
            guard let url, !matches.contains(where: { $0.range.overlaps(range) }) else { return }
            matches.append((range, url))
        }
        // @提及：只认服务器给了 mid 的名字
        for (name, mid) in links.mentions {
            var start = text.startIndex
            while let range = text.range(of: "@" + name, range: start..<text.endIndex) {
                add(range, AppLink.space(mid))
                start = range.upperBound
            }
        }
        // 网址到空白或中文标点为止
        for match in text.matches(of: /https?:\/\/[^\s，。！？、；）)】」]+/) {
            add(match.range, AppLink.web(String(text[match.range])))
        }
        for match in text.matches(of: /BV[0-9A-Za-z]{10}/) {
            add(match.range, AppLink.video(String(text[match.range])))
        }
        if links.timestamps {
            for match in text.matches(of: /\b(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)\b/) {
                let hours = match.output.1.flatMap { Int($0) } ?? 0
                let seconds = hours * 3600 + (Int(match.output.2) ?? 0) * 60 + (Int(match.output.3) ?? 0)
                add(match.range, AppLink.seek(seconds))
            }
        }
        // B 站识别的关键词放最后：与上面重叠时让位
        for (keyword, target) in links.jumps where !keyword.isEmpty {
            if let range = text.range(of: keyword) { add(range, AppLink.web(target)) }
        }

        guard !matches.isEmpty else { return AttributedString(text) }
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result = AttributedString()
        var cursor = text.startIndex
        for (range, url) in matches {
            if cursor < range.lowerBound { result += AttributedString(String(text[cursor..<range.lowerBound])) }
            var piece = AttributedString(String(text[range]))
            piece.link = url
            result += piece
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result += AttributedString(String(text[cursor...])) }
        return result
    }

    private static func parse(_ message: String, keys: Set<String>) -> [Segment] {
        guard !keys.isEmpty else { return [.text(message)] }
        var result: [Segment] = []
        var rest = message[...]
        while let range = rest.firstRange(of: /\[[^\[\]]{1,24}\]/) {
            let key = String(rest[range])
            if keys.contains(key) {
                if range.lowerBound > rest.startIndex { result.append(.text(String(rest[..<range.lowerBound]))) }
                result.append(.emote(key))
            } else {
                result.append(.text(String(rest[..<range.upperBound])))
            }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { result.append(.text(String(rest))) }
        return result
    }
}

/// App 内部链接：评论 / 动态正文里的可点内容统一编码成 newbi:// 地址，
/// RootView 的 openURL 解析后导航；外部网址里的 B 站视频链接也转成站内打开
enum AppLink {
    enum Target: Equatable {
        case space(Int)
        case video(String)
        case seek(Int)
        case external(URL)
    }

    static func space(_ mid: Int) -> URL? { URL(string: "newbi://space/\(mid)") }
    static func video(_ bvid: String) -> URL? { URL(string: "newbi://video/\(bvid)") }
    static func seek(_ seconds: Int) -> URL? { URL(string: "newbi://seek/\(seconds)") }

    static func web(_ raw: String) -> URL? {
        guard let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw) else { return nil }
        // bilibili.com/video/BVxxxx、b23.tv 之外的链接照常交给 Safari
        if let host = url.host(), host.hasSuffix("bilibili.com"),
           let bvid = url.path().firstMatch(of: /BV[0-9A-Za-z]{10}/) {
            return video(String(bvid.output))
        }
        return url
    }

    static func parse(_ url: URL) -> Target {
        guard url.scheme == "newbi", let host = url.host() else { return .external(url) }
        let value = url.lastPathComponent
        switch host {
        case "space": return Int(value).map(Target.space) ?? .external(url)
        case "video": return .video(value)
        case "seek": return Int(value).map(Target.seek) ?? .external(url)
        default: return .external(url)
        }
    }
}

/// 搜索结果里的 `<em class="keyword">` 高亮与 HTML 实体
enum BiliHTML {
    static func highlighted(_ html: String, color: Color) -> AttributedString {
        var result = AttributedString()
        var rest = html[...]
        while let open = rest.range(of: "<em class=\"keyword\">") {
            result += AttributedString(decode(String(rest[..<open.lowerBound])))
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "</em>") else { break }
            var keyword = AttributedString(decode(String(rest[..<close.lowerBound])))
            keyword.foregroundColor = color
            result += keyword
            rest = rest[close.upperBound...]
        }
        result += AttributedString(decode(String(rest)))
        return result
    }

    static func plain(_ html: String) -> String {
        decode(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
