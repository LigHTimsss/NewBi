import SwiftUI

/// 评论正文：文字与 B 站表情（`[doge]`）图文混排。
/// 表情图走 ImagePipeline（服务端缩放 + 内存缓存），同一表情全局只下载一次。
struct RichText: View {
    private enum Segment {
        case text(String)
        case emote(String)
    }

    private let segments: [Segment]
    private let emotes: [String: String]
    private let size: CGFloat
    @State private var images: [String: UIImage] = [:]
    @Environment(\.displayScale) private var scale

    init(_ message: String, emotes: [String: String], size: CGFloat = 15) {
        self.emotes = emotes
        self.size = size
        segments = Self.parse(message, keys: Set(emotes.keys))
    }

    var body: some View {
        segments.reduce(Text(verbatim: "")) { (partial: Text, segment: Segment) -> Text in
            switch segment {
            case .text(let text):
                Text("\(partial)\(Text(verbatim: text))")
            case .emote(let key):
                if let image = images[key] {
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

    private func loadEmotes() async {
        let needed = emotes.filter { images[$0.key] == nil }
        guard !needed.isEmpty else { return }
        let point = size * 1.35
        let pixel = point * scale
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (key, url) in needed {
                group.addTask {
                    guard let resized = url.biliResized(CGSize(width: pixel, height: pixel)) else { return (key, nil) }
                    return (key, await ImagePipeline.shared.image(for: resized, maxPixel: pixel))
                }
            }
            for await (key, image) in group {
                guard let cg = image?.cgImage else { continue }
                // 以像素宽度换算 scale，让表情在文字里正好是 point 大小
                images[key] = UIImage(cgImage: cg, scale: CGFloat(cg.width) / point, orientation: .up)
            }
        }
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
