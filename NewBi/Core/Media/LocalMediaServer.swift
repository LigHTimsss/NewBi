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
///
/// 大响应（在线分段、本地文件）都分块转发：内存里只留还没发出去的几块，下游断开即停止读取 / 取消上游
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
        /// 已有调用方在创建 listener：其他调用只排队等结果，不再创建第二个
        var starting = false
        var port: UInt16?
        var routes: [String: Route] = [:]
        var waiters: [CheckedContinuation<UInt16, Error>] = []
    }

    private enum StartAction {
        case ready(UInt16)
        case wait
        case launch
    }

    /// listener、所有连接和上游转发的回调都在这一条串行队列上
    private let queue: DispatchQueue
    private let relay: UpstreamRelay
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {
        let queue = DispatchQueue(label: "newbi.local-media-server")
        self.queue = queue
        relay = UpstreamRelay(queue: queue)
    }

    /// 启动（已启动则直接返回端口）。并发调用只会创建一个 listener，就绪或失败时全部返回
    func start() async throws -> UInt16 {
        if let port = state.withLock({ $0.port }) { return port }
        return try await withCheckedThrowingContinuation { continuation in
            // 看状态、入队、抢启动权放在同一个临界区：不会漏掉恰好在中间到达的就绪通知，也不会启动两次
            let action = state.withLock { state -> StartAction in
                if let port = state.port { return .ready(port) }
                state.waiters.append(continuation)
                if state.listener != nil || state.starting { return .wait }
                state.starting = true
                return .launch
            }
            switch action {
            case .ready(let port): continuation.resume(returning: port)
            case .wait: break
            case .launch: launchListener()
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

    private func launchListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] newState in self?.listenerChanged(newState, listener) }
            state.withLock {
                $0.listener = listener
                $0.starting = false
            }
            listener.start(queue: queue)
        } catch {
            state.withLock { $0.starting = false }
            finishWaiters(.failure(error))
        }
    }

    private func listenerChanged(_ newState: NWListener.State, _ listener: NWListener) {
        switch newState {
        case .ready:
            guard let port = listener.port?.rawValue else {
                stop(listener, error: URLError(.cannotConnectToHost))
                return
            }
            state.withLock { $0.port = port }
            finishWaiters(.success(port))
        case .failed(let error), .waiting(let error):
            // 只监听本机回环地址，waiting 不会自己好转：当作失败，下次 start() 重新创建
            stop(listener, error: error)
        default:
            break
        }
    }

    private func stop(_ listener: NWListener, error: Error) {
        listener.cancel()
        state.withLock {
            if $0.listener === listener {
                $0.listener = nil
                $0.port = nil
            }
        }
        finishWaiters(.failure(error))
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
            serveData(data, range: range, contentType: contentType, isHead: isHead, on: connection)
        case .upstream(let source, let contentType):
            Task { await self.proxy(source, range: range, contentType: contentType, isHead: isHead, on: connection) }
        case .file(let url, let contentType):
            Task.detached(priority: .userInitiated) { self.serveFile(url, range: range, contentType: contentType, isHead: isHead, on: connection) }
        }
    }

    // MARK: - 内存数据与本地文件

    private func serveData(_ data: Data, range: String?, contentType: String, isHead: Bool, on connection: NWConnection) {
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        switch ByteRange(range, total: data.count) {
        case .unsatisfiable:
            send(connection, status: 416, headers: ["Content-Range": "bytes */\(data.count)"])
        case .full:
            headers["Content-Length"] = "\(data.count)"
            send(connection, status: 200, headers: headers, body: isHead ? Data() : data)
        case .partial(let bounds):
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(data.count)"
            headers["Content-Length"] = "\(bounds.count)"
            let body = isHead ? Data() : data.subdata(in: (data.startIndex + bounds.lowerBound)..<(data.startIndex + bounds.upperBound + 1))
            send(connection, status: 206, headers: headers, body: body)
        }
    }

    /// 只读请求的那一段，按块发出（不把整个文件或整段读进内存）
    private func serveFile(_ url: URL, range: String?, contentType: String, isHead: Bool, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd(), size > 0 else {
            send(connection, status: 404)
            return
        }
        let total = Int(size)
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        let status: Int
        let bounds: ClosedRange<Int>
        switch ByteRange(range, total: total) {
        case .unsatisfiable:
            try? handle.close()
            send(connection, status: 416, headers: ["Content-Range": "bytes */\(total)"])
            return
        case .full:
            status = 200
            bounds = 0...(total - 1)
        case .partial(let partial):
            status = 206
            bounds = partial
            headers["Content-Range"] = "bytes \(partial.lowerBound)-\(partial.upperBound)/\(total)"
        }
        headers["Content-Length"] = "\(bounds.count)"
        guard !isHead else {
            try? handle.close()
            send(connection, status: status, headers: headers)
            return
        }
        do {
            try handle.seek(toOffset: UInt64(bounds.lowerBound))
        } catch {
            try? handle.close()
            send(connection, status: 500)
            return
        }
        sendHead(connection, status: status, headers: headers)
        FileStream(handle: handle, connection: connection, length: bounds.count).next()
    }

    // MARK: - 在线分段

    /// 地址已过 deadline 时先换地址；CDN 拒绝时换地址再试一次。接受后由 UpstreamRelay 边收边转发
    private func proxy(_ source: UpstreamSource, range: String?, contentType: String, isHead: Bool, on connection: NWConnection) async {
        if source.isExpired { _ = try? await source.refresh() }
        var outcome = await open(source.urls, range: range, contentType: contentType, isHead: isHead, on: connection)
        if outcome == .expired, (try? await source.refresh()) != nil {
            outcome = await open(source.urls, range: range, contentType: contentType, isHead: isHead, on: connection)
        }
        if outcome != .streaming { send(connection, status: 502) }
    }

    private func open(_ urls: [URL], range: String?, contentType: String, isHead: Bool, on connection: NWConnection) async -> UpstreamRelay.Outcome {
        var sawRejection = false
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = isHead ? "HEAD" : "GET"
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            switch await relay.open(request, rangeRequested: range != nil, contentType: contentType, on: connection) {
            case .streaming: return .streaming
            case .expired: sawRejection = true
            case .failed: continue
            }
        }
        return sawRejection ? .expired : .failed
    }

    // MARK: - 发送

    static func head(status: Int, headers: [String: String]) -> Data {
        var headers = headers
        headers["Connection"] = "close"
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }

    /// 只发响应头，正文随后分块发
    private func sendHead(_ connection: NWConnection, status: Int, headers: [String: String]) {
        connection.send(content: Self.head(status: status, headers: headers), contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })
    }

    /// 一次发完整个响应并关闭连接
    private func send(_ connection: NWConnection, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(body.count)" }
        var payload = Self.head(status: status, headers: headers)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// 请求头里的 Range（只支持单个区间）
enum ByteRange: Equatable {
    /// 没有 Range、单位不是 bytes、格式不合法或多区间：按完整响应 200 处理（RFC 9110 允许忽略）
    case full
    /// 206：闭区间，已裁到文件范围内
    case partial(ClosedRange<Int>)
    /// 416：起点越过文件末尾，或后缀长度为 0
    case unsatisfiable

    init(_ header: String?, total: Int) {
        // 空内容没有可选的区间：整份（空）返回
        guard let header, total > 0 else {
            self = .full
            return
        }
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else {
            self = .full
            return
        }
        let value = spec.dropFirst(6)
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !value.contains(","), parts.count == 2 else {
            self = .full
            return
        }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            // 后缀：最后 N 字节（N 大于文件长度时就是整个文件）
            guard let suffix = Int(last), suffix >= 0 else {
                self = .full
                return
            }
            self = suffix == 0 ? .unsatisfiable : .partial(max(total - suffix, 0)...(total - 1))
            return
        }
        guard let start = Int(first), start >= 0 else {
            self = .full
            return
        }
        guard start < total else {
            self = .unsatisfiable
            return
        }
        guard !last.isEmpty else {
            self = .partial(start...(total - 1))
            return
        }
        guard let end = Int(last), end >= start else {
            self = .full
            return
        }
        self = .partial(start...min(end, total - 1))
    }
}

/// 把本地文件的一段按块发给下游：上一块发完再读下一块，内存里最多一块；下游断开即停。
/// 所有回调都在连接所在的串行队列上
private final class FileStream: @unchecked Sendable {
    private static let chunk = 1 << 20

    private let handle: FileHandle
    private let connection: NWConnection
    private var remaining: Int

    init(handle: FileHandle, connection: NWConnection, length: Int) {
        self.handle = handle
        self.connection = connection
        remaining = length
    }

    func next() {
        let count = min(remaining, Self.chunk)
        guard count > 0, let data = try? handle.read(upToCount: count), !data.isEmpty else {
            // 文件中途变短（被删除 / 截断）：直接断开，让播放器按失败处理
            close()
            return
        }
        remaining -= data.count
        let isLast = remaining == 0
        connection.send(content: data, contentContext: isLast ? .finalMessage : .defaultMessage, isComplete: isLast, completion: .contentProcessed { error in
            if error != nil || isLast {
                self.close()
            } else {
                self.next()
            }
        })
    }

    private func close() {
        try? handle.close()
        connection.cancel()
    }
}

/// 在线分段的上游转发：收到一块转发一块，不先把整段攒在内存里。
/// - 看到第一块数据（或请求结束）时检查响应：请求了区间却回 200（CDN 忽略 Range、正文是整份文件）立刻取消，
///   读进来的最多是第一块；403 / 404 / 410 报告地址过期，由上层换地址
/// - 下游积压超过 highWater 暂停上游，降到 lowWater 再继续
/// - 下游断开（发送失败 / 连接取消）时取消上游
final class UpstreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        /// 已接受，响应头已发给下游，后续自动转发到结束
        case streaming
        case expired
        case failed
    }

    private static let highWater = 4 << 20
    private static let lowWater = 1 << 20

    /// 每个上游请求的状态；只在 queue 上读写（登记发生在 resume 之前）
    private final class Relay: @unchecked Sendable {
        let connection: NWConnection
        let contentType: String
        let rangeRequested: Bool
        let task: URLSessionDataTask
        var continuation: CheckedContinuation<Outcome, Never>?
        var streaming = false
        var pending = 0
        var paused = false

        init(connection: NWConnection, contentType: String, rangeRequested: Bool, task: URLSessionDataTask, continuation: CheckedContinuation<Outcome, Never>) {
            self.connection = connection
            self.contentType = contentType
            self.rangeRequested = rangeRequested
            self.task = task
            self.continuation = continuation
        }

        func decide(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private var session: URLSession!
    private let relays = OSAllocatedUnfairLock(initialState: [Int: Relay]())

    /// - Parameter queue: 和下游连接同一条串行队列，转发状态不用另外加锁
    init(queue: DispatchQueue) {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = BiliClient.mediaHeaders
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil // 媒体数据不进 URLCache，避免占用磁盘
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func open(_ request: URLRequest, rangeRequested: Bool, contentType: String, on connection: NWConnection) async -> Outcome {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            let relay = Relay(connection: connection, contentType: contentType, rangeRequested: rangeRequested, task: task, continuation: continuation)
            relays.withLock { $0[task.taskIdentifier] = relay }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let relay = relays.withLock({ $0[dataTask.taskIdentifier] }) else { return }
        if !relay.streaming, !begin(relay, response: dataTask.response) {
            dataTask.cancel()
            return
        }
        forward(data, relay)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let relay = relays.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if relay.streaming {
            // 正文中途断了：直接断开下游，播放器按失败走恢复链
            error == nil ? finish(relay) : relay.connection.cancel()
        } else if error == nil, begin(relay, response: task.response) {
            // HEAD 或空正文
            finish(relay)
        } else {
            relay.decide(.failed) // 已经判过（过期 / 拒绝）时不会重复
        }
    }

    /// 检查响应头；接受时把响应头发给下游
    private func begin(_ relay: Relay, response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            relay.decide(.failed)
            return false
        }
        let status = http.statusCode
        if [403, 404, 410].contains(status) {
            relay.decide(.expired)
            return false
        }
        guard (200..<300).contains(status), !relay.rangeRequested || status == 206 else {
            relay.decide(.failed)
            return false
        }
        var headers = ["Content-Type": relay.contentType, "Accept-Ranges": "bytes"]
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") { headers["Content-Range"] = contentRange }
        // 上游压缩过时 URLSession 已解压，原长度对不上：不写长度，由关闭连接界定正文
        if http.value(forHTTPHeaderField: "Content-Encoding") == nil, let length = http.value(forHTTPHeaderField: "Content-Length") {
            headers["Content-Length"] = length
        }
        relay.streaming = true
        relay.decide(.streaming)
        let task = relay.task
        relay.connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: task.cancel()
            default: break
            }
        }
        relay.connection.send(content: LocalMediaServer.head(status: status, headers: headers), contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })
        return true
    }

    private func forward(_ data: Data, _ relay: Relay) {
        let count = data.count
        relay.pending += count
        relay.connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
            relay.pending -= count
            if error != nil {
                relay.task.cancel()
                relay.connection.cancel()
            } else if relay.paused, relay.pending < Self.lowWater {
                relay.paused = false
                relay.task.resume()
            }
        })
        if !relay.paused, relay.pending > Self.highWater {
            relay.paused = true
            relay.task.suspend()
        }
    }

    private func finish(_ relay: Relay) {
        let connection = relay.connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
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

    /// 读一小段（索引头）。只接受 206：CDN 忽略 Range 回 200 时正文是整份文件，读正文之前就放弃；
    /// 上游多给也最多读到区间长度
    static func range(_ urls: [URL], _ range: ClosedRange<Int>) async throws -> Data {
        var lastError: Error = BiliError.emptyData
        let expected = range.count
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                // 文件本身比区间还短时 CDN 可能回 200 + 整个（很小的）文件，这种可以接受
                let wholeSmallFile = status == 200 && range.lowerBound == 0 && (0...Int64(expected)).contains(response.expectedContentLength)
                guard status == 206 || wholeSmallFile else {
                    bytes.task.cancel()
                    lastError = BiliError.http(status)
                    continue
                }
                var data = Data()
                data.reserveCapacity(expected)
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= expected { break }
                }
                bytes.task.cancel()
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
