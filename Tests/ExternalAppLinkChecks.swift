import Foundation

// swiftc NewBi/App/ExternalAppLink.swift Tests/ExternalAppLinkChecks.swift -o /tmp/newbi-link-checks
@main
struct ExternalAppLinkChecks {
    static func main() {
        let checks: [(String, ExternalAppLink?)] = [
            ("bilibili://", .home), ("bilibili://root", .home), ("bilibili://home", .home),
            ("newbi://home", .home), ("BILIBILI://root", .home),
            ("bilibili://video/170001", .video(.av(170001), cid: nil, page: nil)),
            ("bilibili://video/av170001", .video(.av(170001), cid: nil, page: nil)),
            ("bilibili://video/BV17x411w7KC", .video(.bv("BV17x411w7KC"), cid: nil, page: nil)),
            ("newbi://video/BV17x411w7KC?p=2", .video(.bv("BV17x411w7KC"), cid: nil, page: 2)),
            ("bilibili://video?bvid=BV17x411w7KC", .video(.bv("BV17x411w7KC"), cid: nil, page: nil)),
            ("bilibili://video?aid=170001&cid=123&page=0", .video(.av(170001), cid: 123, page: 1)),
            ("bilibili://video?avid=170001", .video(.av(170001), cid: nil, page: nil)),
            ("bilibili://video/170001?p=2&page=1", .video(.av(170001), cid: nil, page: 2)),
            ("bilibili://space/123", .space(123)), ("newbi://space/123", .space(123)),
            ("bilibili://live/123", .live(123)), ("bilibili://search", .search),
            ("bilibili://browser?url=https%3A%2F%2Fwww.bilibili.com%2Fvideo%2Fav170001", .video(.av(170001), cid: nil, page: nil)),
            ("https://m.bilibili.com/video/av170001?p=2", .video(.av(170001), cid: nil, page: 2)),
            ("https://space.bilibili.com/123", .space(123)), ("https://live.bilibili.com/123", .live(123)),
            ("https://www.bilibili.com/video/BV1UAn36aED3/", .video(.bv("BV1UAn36aED3"), cid: nil, page: nil)),
            ("bilibili://video/BV1UAn36aED3?page=0", .video(.bv("BV1UAn36aED3"), cid: nil, page: 1)),
            ("bilibili://video/170001?page=1", .video(.av(170001), cid: nil, page: 2)),
            ("newbi://video/170001?page=1", .video(.av(170001), cid: nil, page: 1)),
            ("bilibili://video/170001?page=-1", nil),
            ("bilibili://video/170001?page=9223372036854775807", nil),
            ("bilibili://video/0", nil), ("bilibili://video/-1", nil),
            ("bilibili://video/999999999999999999999999", nil),
            ("bilibili://video/BVshort", nil), ("bilibili://video/BV17x411w7K!", nil),
            ("bilibili://video/170001/extra", nil), ("bilibili://video", nil),
            ("bilibili://space/0", nil), ("bilibili://space/abc", nil), ("bilibili://live/-1", nil),
            ("bilibili://video/170001?cid=abc", nil), ("bilibili://video/170001?p=0", nil),
            ("bilibili://video/170001?p=1&p=2", nil), ("bilibili://video/170001?p=1&page=1", nil),
            ("bilibili://video?aid=1&aid=2", nil),
            ("bilibili://browser?url=file%3A%2F%2F%2Fetc%2Fpasswd", nil),
            ("bilibili://browser?url=https%3A%2F%2Fbilibili.com.evil.test%2Fvideo%2Fav170001", nil),
            ("https://evilbilibili.com/video/av170001", nil),
            ("https://www.bilibili.com@evil.test/video/av170001", nil),
            ("bilibili://user:pass@video/170001", nil), ("bilibili://video:80/170001", nil),
            ("bilibili://pgc/season/ep1", nil), ("newbi://seek/30", nil),
        ]
        for (raw, expected) in checks {
            let actual = URL(string: raw).flatMap(ExternalAppLink.parse)
            precondition(actual == expected, "Unexpected target for \(raw): \(String(describing: actual))")
        }
        var nested = "bilibili://video/170001"
        for _ in 0..<3 {
            var wrapper = URLComponents()
            wrapper.scheme = "bilibili"; wrapper.host = "browser"
            wrapper.queryItems = [URLQueryItem(name: "url", value: nested)]
            nested = wrapper.url!.absoluteString
        }
        precondition(ExternalAppLink.parse(URL(string: nested)!) == nil, "Bound wrapper recursion")
        let oversized = URL(string: "bilibili://root?unused=" + String(repeating: "x", count: 5000))!
        precondition(ExternalAppLink.parse(oversized) == nil, "Bound URL size")
        print("\(checks.count + 2) external-link checks passed (no network).")
    }
}
