import Foundation

/// 只接受视频链接和 b23 短链接，不把剪贴板中的任意网址交给浏览器。
enum ClipboardVideoLink {
    static func candidate(in text: String) -> URL? {
        guard text.utf8.count <= 16_384 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), accepts(url) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: accepts)
    }

    static func accepts(_ url: URL) -> Bool {
        if case .video = ExternalAppLink.parse(url) { return true }
        return isShortLink(url)
    }

    static func isShortLink(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.lowercased() == "b23.tv",
              parts.user == nil, parts.password == nil, parts.port == nil,
              url.absoluteString.utf8.count <= 4096 else { return false }
        return !parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }

    static func resolve(_ candidate: URL) async throws -> URL? {
        if case .video = ExternalAppLink.parse(candidate) { return candidate }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var current = candidate
        // 不自动跟随重定向。逐跳验证，仅访问 b23.tv；得到视频地址即停止请求。
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard isShortLink(current), var parts = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
            parts.scheme = "https"
            guard let secureURL = parts.url else { return nil }
            var request = URLRequest(url: secureURL)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: secureURL)?.absoluteURL else { return nil }
            if case .video = ExternalAppLink.parse(next) { return next }
            current = next
        }
        return nil
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
