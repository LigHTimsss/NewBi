import Foundation
import Network
import os

/// 只监听 127.0.0.1 的极简 HTTP 服务，给 AVPlayer 提供：
/// - 生成好的 HLS 播放列表（内存数据）
/// - 改过编码标记的 init 段（内存数据）
/// - 媒体分段：按 Range 转发到 B 站 CDN，并带上 Referer / UA
///
/// 为什么不用 AVAssetResourceLoaderDelegate：HLS 的媒体分段不会走自定义 scheme，
/// 而 CDN 要求 Referer，所以分段必须经过一个能加请求头的 http 地址。
final class LocalMediaServer: @unchecked Sendable {
    enum Route: Sendable {
        case data(Data, contentType: String)
        /// 依次尝试主备地址；地址过期时由 UpstreamSource 重新取流换地址
        case upstream(UpstreamSource, contentType: String)
        /// 离线缓存的本地文件，按 Range 读取
        case file(URL, contentType: String)
    }

    static let shared = LocalMediaServer()

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var routes: [String: Route] = [:]
        var waiters: [CheckedContinuation<UInt16, Error>] = []
    }

    private let queue = DispatchQueue(label: "newbi.local-media-server")
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 启动（已启动则直接返回端口）
    func start() async throws -> UInt16 {
        if let port = state.withLock({ $0.port }) { return port }
        return try await withCheckedThrowingContinuation { continuation in
            let needsListener = state.withLock { state -> Bool in
                state.waiters.append(continuation)
                return state.listener == nil
            }
            guard needsListener else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] newState in self?.listenerChanged(newState, listener) }
                state.withLock { $0.listener = listener }
                listener.start(queue: queue)
            } catch {
                finishWaiters(.failure(error))
            }
        }
    }

    func register(_ routes: [String: Route]) {
        state.withLock { $0.routes.merge(routes) { $1 } }
    }

    func unregister(prefix: String) {
        state.withLock { state in
            state.routes = state.routes.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    // MARK: - Listener

    private func listenerChanged(_ newState: NWListener.State, _ listener: NWListener) {
        switch newState {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            state.withLock { $0.port = port }
            finishWaiters(.success(port))
        case .failed(let error):
            listener.cancel()
            state.withLock {
                $0.listener = nil
                $0.port = nil
            }
            finishWaiters(.failure(error))
        default:
            break
        }
    }

    private func finishWaiters(_ result: Result<UInt16, Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<UInt16, Error>] in
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(with: result) }
    }

    // MARK: - 连接：一个连接处理一个请求，响应后关闭

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else {
            send(connection, status: 400)
            return
        }
        let isHead = requestLine[0] == "HEAD"
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        let range = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }

        switch state.withLock({ $0.routes[path] }) {
        case nil:
            send(connection, status: 404)
        case .data(let data, let contentType):
            let (status, body, contentRange) = Self.slice(data, range: range)
            var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes", "Content-Length": "\(body.count)"]
            if let contentRange { headers["Content-Range"] = contentRange }
            send(connection, status: status, headers: headers, body: isHead ? Data() : body)
        case .upstream(let source, let contentType):
            Task { await self.proxy(source, range: range, contentType: contentType, isHead: isHead, on: connection) }
        case .file(let url, let contentType):
            Task.detached(priority: .userInitiated) { self.serveFile(url, range: range, contentType: contentType, isHead: isHead, on: connection) }
        }
    }

    /// 只读请求的那一段，不把整个文件读进内存
    private func serveFile(_ url: URL, range: String?, contentType: String, isHead: Bool, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd(), size > 0 else {
            send(connection, status: 404)
            return
        }
        defer { try? handle.close() }
        let total = Int(size)
        let bounds = Self.byteRange(range, total: total)
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes", "Content-Length": "\(bounds.upperBound - bounds.lowerBound + 1)"]
        let partial = range != nil
        if partial { headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(total)" }
        guard !isHead else {
            send(connection, status: partial ? 206 : 200, headers: headers)
            return
        }
        try? handle.seek(toOffset: UInt64(bounds.lowerBound))
        let body = (try? handle.read(upToCount: bounds.upperBound - bounds.lowerBound + 1)) ?? Data()
        send(connection, status: partial ? 206 : 200, headers: headers, body: body)
    }

    /// "bytes=a-b" / "bytes=a-" → 闭区间；无效或缺省时为整个文件
    private static func byteRange(_ range: String?, total: Int) -> ClosedRange<Int> {
        guard let range, range.hasPrefix("bytes=") else { return 0...(total - 1) }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }), start < total else { return 0...(total - 1) }
        let end = parts.count > 1 ? (Int(parts[1]) ?? total - 1) : total - 1
        return start...min(max(end, start), total - 1)
    }

    private enum UpstreamResult {
        case success(Data, HTTPURLResponse)
        /// CDN 返回 403 / 404 / 410：B 站地址过期的典型表现
        case expired
        case failed
    }

    /// 整段下载后一次性返回：B 站 DASH 分段一般几 MB，实现简单且足够快。
    /// 地址已过 deadline 时先换地址；CDN 拒绝时换地址再试一次
    private func proxy(_ source: UpstreamSource, range: String?, contentType: String, isHead: Bool, on connection: NWConnection) async {
        if source.isExpired { _ = try? await source.refresh() }
        var result = await fetch(source.urls, range: range, isHead: isHead)
        if case .expired = result, (try? await source.refresh()) != nil {
            result = await fetch(source.urls, range: range, isHead: isHead)
        }
        guard case .success(let data, let http) = result else {
            send(connection, status: 502)
            return
        }
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") { headers["Content-Range"] = contentRange }
        headers["Content-Length"] = isHead ? (http.value(forHTTPHeaderField: "Content-Length") ?? "0") : "\(data.count)"
        send(connection, status: http.statusCode, headers: headers, body: isHead ? Data() : data)
    }

    private func fetch(_ urls: [URL], range: String?, isHead: Bool) async -> UpstreamResult {
        var sawRejection = false
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = isHead ? "HEAD" : "GET"
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            guard let (data, response) = try? await MediaFetch.session.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode < 400 { return .success(data, http) }
            if [403, 404, 410].contains(http.statusCode) { sawRejection = true }
        }
        return sawRejection ? .expired : .failed
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(body.count)" }
        headers["Connection"] = "close"
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 处理 "bytes=a-b" / "bytes=a-"
    private static func slice(_ data: Data, range: String?) -> (status: Int, body: Data, contentRange: String?) {
        guard range != nil, !data.isEmpty else { return (200, data, nil) }
        let bounds = byteRange(range, total: data.count)
        let body = data.subdata(in: bounds.lowerBound..<(bounds.upperBound + 1))
        return (206, body, "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(data.count)")
    }
}

/// 一路流的上游地址。B 站播放地址带 `deadline` 参数，大约 2 小时后失效：
/// - 快到 deadline（提前 60 秒）或 CDN 返回 403/404/410 时，调用 refresher 重新取流换上新地址
/// - 同一时刻多个分段请求同时发现过期，只发起一次刷新
/// - 15 秒内不重复刷新，防止地址本身有问题时反复请求
final class UpstreamSource: @unchecked Sendable {
    typealias Refresher = @Sendable () async throws -> [URL]

    private struct State {
        var urls: [URL]
        var deadline: Date?
        var refreshedAt: Date?
        var inflight: Task<[URL], Error>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let refresher: Refresher?

    /// - Parameter refresher: nil 表示无法刷新（只用初始地址）
    init(urls: [URL], refresher: Refresher?) {
        state = OSAllocatedUnfairLock(initialState: State(urls: urls, deadline: Self.deadline(of: urls.first)))
        self.refresher = refresher
    }

    var urls: [URL] { state.withLock { $0.urls } }

    var isExpired: Bool {
        guard let deadline = state.withLock({ $0.deadline }) else { return false }
        return deadline.timeIntervalSinceNow < 60
    }

    @discardableResult
    func refresh() async throws -> [URL] {
        guard let refresher else { return urls }
        let task = state.withLock { state -> Task<[URL], Error>? in
            if let inflight = state.inflight { return inflight }
            if let refreshedAt = state.refreshedAt, Date.now.timeIntervalSince(refreshedAt) < 15 { return nil }
            let task = Task { try await refresher() }
            state.inflight = task
            return task
        }
        guard let task else { return urls }
        do {
            let fresh = try await task.value
            state.withLock { state in
                if !fresh.isEmpty {
                    state.urls = fresh
                    state.deadline = Self.deadline(of: fresh.first)
                }
                state.refreshedAt = .now
                state.inflight = nil
            }
            return fresh
        } catch {
            state.withLock {
                $0.refreshedAt = .now
                $0.inflight = nil
            }
            throw error
        }
    }

    /// 地址里的 `deadline=<unix 秒>`
    static func deadline(of url: URL?) -> Date? {
        guard let url,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "deadline" })?.value,
              let seconds = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// 媒体请求：带 Referer / UA，按顺序尝试主备地址
enum MediaFetch {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = BiliClient.mediaHeaders
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil // 媒体数据不进 URLCache，避免占用磁盘
        return URLSession(configuration: config)
    }()

    static func range(_ urls: [URL], _ range: ClosedRange<Int>) async throws -> Data {
        var lastError: Error = BiliError.emptyData
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return data }
                lastError = BiliError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
