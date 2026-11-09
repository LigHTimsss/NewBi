import Foundation

// swiftc NewBi/App/ExternalAppLink.swift NewBi/App/ClipboardVideoLink.swift Tests/ClipboardVideoLinkChecks.swift -o /tmp/newbi-clipboard-checks
@main
struct ClipboardVideoLinkChecks {
    static func main() {
        let video = "https://www.bilibili.com/video/BV1UAn36aED3/"
        let checks: [(String, String?)] = [
            (video, video),
            ("分享视频 \(video) 一起来看", video),
            ("【分享】https://b23.tv/abc123", "https://b23.tv/abc123"),
            ("bilibili://video/170001", "bilibili://video/170001"),
            ("https://space.bilibili.com/123", nil),
            ("https://live.bilibili.com/123", nil),
            ("https://b23.tv.evil.test/abc", nil),
            ("https://b23.tv@evil.test/abc", nil),
            ("https://user:pass@b23.tv/abc", nil),
            ("https://b23.tv:443/abc", nil),
            ("https://b23.tv/", nil),
            ("普通文字", nil),
            (String(repeating: "a", count: 16385) + video, nil)
        ]
        for (input, expected) in checks {
            precondition(ClipboardVideoLink.candidate(in: input)?.absoluteString == expected, input)
        }
        print("ClipboardVideoLink: \(checks.count) checks passed")
    }
}
