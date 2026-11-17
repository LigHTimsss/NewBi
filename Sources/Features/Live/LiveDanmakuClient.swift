import Compression
import Foundation

/// 直播弹幕服务器地址和进房凭证（getDanmuInfo，WBI 签名）
struct LiveDanmuInfo: Decodable, Sendable {
    struct Host: Decodable, Sendable {
        let host: String
        let wssPort: Int

        private enum CodingKeys: String, CodingKey {
            case host
            case wssPort = "wss_port"
        }
    }

    let token: String
    let hostList: [Host]

    private enum CodingKeys: String, CodingKey {
        case token
        case hostList = "host_list"
    }
}

extension Endpoint {
    static func liveDanmuInfo(roomID: Int) -> Endpoint {
        Endpoint(
            host: "https://api.live.bilibili.com",
            path: "/xlive/web-room/v1/index/getDanmuInfo",
            query: ["id": "\(roomID)", "type": "0", "web_location": "444.8"],
            signed: true
        )
    }
}

/// 收到的一条直播弹幕
struct LiveDanmaku: Sendable {
    let item: Danmaku
    /// 表情弹幕（整条是一个表情包）
    let isEmoticon: Bool
    /// 抽奖、节奏风暴这类活动自动发的弹幕
    let isLottery: Bool

    /// 弹幕设置抽屉里两项直播专有的屏蔽（UserDefaults 键）
    static let hideEmoticonKey = "liveDanmakuHideEmoticon"
    static let hideLotteryKey = "liveDanmakuHideLottery"
}

/// 直播弹幕长连接：wss://…/sub，B 站直播的二进制包协议（16 字节头 + 正文）。
/// 进房（op 7）带上 token，之后每 30 秒心跳（op 2）；弹幕在 op 5 里，按 protover 2 要 zlib 压缩的包，
/// 解开后里面又是一串同样格式的小包。只取 DANMU_MSG，礼物、进场、醒目留言这些都不要
@MainActor
final class LiveDanmakuClient {
    var onDanmaku: (@MainActor (LiveDanmaku) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var parsingTask: Task<[Event], Never>?
    private var infoTask: Task<Void, Never>?
    private var roomID = 0
    private var hosts: [LiveDanmuInfo.Host] = []
    private var token = ""
    private var hostIndex = 0
    private var failures = 0
    /// stop() 之后为 true：断线回调不再重连
    private var stopped = true
    /// 每次连接加一：旧连接晚到的回调不再处理
    private var generation = 0

    private static let session = URLSession(configuration: .default)
    private static let fallbackHost = LiveDanmuInfo.Host(host: "broadcastlv.chat.bilibili.com", wssPort: 443)

    func start(roomID: Int) {
        guard stopped || self.roomID != roomID else { return }
        stop()
        stopped = false
        self.roomID = roomID
        failures = 0
        infoTask = Task { await fetchInfoAndConnect() }
    }

    func stop() {
        stopped = true
        parsingTask?.cancel()
        parsingTask = nil
        generation += 1
        infoTask?.cancel()
        infoTask = nil
        heartbeat?.cancel()
        receiver?.cancel()
        reconnect?.cancel()
        heartbeat = nil
        receiver = nil
        reconnect = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: 连接

    private func fetchInfoAndConnect() async {
        let roomID = roomID
        let generation = generation
        if let info = try? await BiliClient.shared.get(.liveDanmuInfo(roomID: roomID), as: LiveDanmuInfo.self) {
            guard !Task.isCancelled, !stopped, generation == self.generation, roomID == self.roomID else { return }
            token = info.token
            hosts = info.hostList.isEmpty ? [Self.fallbackHost] : info.hostList
        } else {
            guard !Task.isCancelled, !stopped, generation == self.generation, roomID == self.roomID else { return }
            // 拿不到凭证（风控）：用公共地址匿名进房，能收到弹幕，只是用户名会被打码
            token = ""
            hosts = [Self.fallbackHost]
        }
        hostIndex = 0
        connect()
    }

    private func connect() {
        guard !stopped, !hosts.isEmpty else { return }
        generation += 1
        let generation = generation
        let host = hosts[hostIndex % hosts.count]
        guard let url = URL(string: "wss://\(host.host):\(host.wssPort)/sub") else { return }
        var request = URLRequest(url: url)
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let task = Self.session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let auth = Self.authBody(roomID: roomID, token: token)
        Task {
            do {
                try await task.send(.data(Self.packet(op: 7, body: auth)))
            } catch {
                self.dropped(generation)
            }
        }

        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                try? await task.send(.data(Self.packet(op: 2, body: Data("[object Object]".utf8))))
            }
        }

        receiver?.cancel()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.generation == generation else { return }
                    // 不在这里清零失败次数：握手被拒时服务器也会先回一个包再断开。
                    // 只有进房成功（op 8 code 0）或收到心跳回复（op 3）才算连上了
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    let worker = Task.detached(priority: .utility) { Self.events(in: data) }
                    self.parsingTask = worker
                    let events = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.parsingTask = nil
                    for (index, event) in events.enumerated() {
                        guard !Task.isCancelled, self.generation == generation else { return }
                        switch event {
                        case .danmaku(let item): self.onDanmaku?(item)
                        case .authenticated(let code):
                            if code != 0 { self.dropped(generation, rejected: true); return }
                            self.failures = 0
                        case .heartbeat: self.failures = 0
                        }
                        if index % 32 == 31 { await Task.yield() }
                    }
                } catch {
                    self?.dropped(generation)
                    return
                }
            }
        }
    }

    /// 断线：换下一个服务器，等一会儿再连（1、2、4…最多 30 秒）。
    /// - Parameter rejected: 服务器明确拒绝了进房（凭证失效 / 风控）：不再换服务器硬试，直接重新拿凭证
    private func dropped(_ generation: Int, rejected: Bool = false) {
        guard !stopped, generation == self.generation else { return }
        // 让这一轮连接的接收 / 心跳回调全部作废，断开时不会再进来一次
        self.generation += 1
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        heartbeat?.cancel()
        receiver?.cancel()
        failures += 1
        hostIndex += 1
        let delay = min(30, pow(2, Double(min(failures, 5)) - 1))
        let refetch = rejected || failures >= 3
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            // 被拒或连续失败多次，凭证可能过期了：重新拿一次
            if refetch {
                await self.fetchInfoAndConnect()
            } else {
                self.connect()
            }
        }
    }

    // MARK: 协议

    private static func authBody(roomID: Int, token: String) -> Data {
        let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.bilibili.com")!) ?? []
        let uid = Int(cookies.first(where: { $0.name == "DedeUserID" })?.value ?? "") ?? 0
        let buvid = cookies.first(where: { $0.name == "buvid3" })?.value ?? ""
        let body: [String: Any] = [
            "uid": uid, "roomid": roomID, "protover": 2, "buvid": buvid,
            "platform": "web", "type": 2, "key": token,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// 包头：总长 u32 · 头长 u16（16）· 协议版本 u16 · 操作码 u32 · 序号 u32，都是大端
    private static func packet(op: UInt32, body: Data) -> Data {
        var data = Data(capacity: 16 + body.count)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(16 + body.count))
        append(UInt16(16))
        append(UInt16(1))
        append(op)
        append(UInt32(1))
        data.append(body)
        return data
    }

    private enum Event: Sendable {
        case danmaku(LiveDanmaku), authenticated(Int), heartbeat
    }

    nonisolated private static func events(in data: Data) -> [Event] {
        var events: [Event] = []
        for packet in messages(in: data) {
            guard !Task.isCancelled else { return [] }
            switch packet {
            case .message(let body):
                if let item = parseDanmaku(body) { events.append(.danmaku(item)) }
            case .authReply(let body):
                let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? Int ?? -1
                events.append(.authenticated(code))
            case .heartbeatReply: events.append(.heartbeat)
            }
        }
        return events
    }

    private enum Packet: Sendable {
        /// op 5：一条通知（JSON）
        case message(Data)
        /// op 8：进房回复
        case authReply(Data)
        /// op 3：心跳回复（正文是人气值）
        case heartbeatReply
    }

    /// 把一个（可能是压缩的）包拆成一条条消息
    nonisolated private static func messages(in data: Data, depth: Int = 0) -> [Packet] {
        guard !Task.isCancelled, depth < 8, data.count <= 8 * 1024 * 1024 else { return [] }
        let bytes = [UInt8](data)
        var result: [Packet] = []
        var offset = 0
        func read32(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func read16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

        while offset + 16 <= bytes.count {
            guard !Task.isCancelled else { return [] }
            let length = read32(offset)
            let headerLength = read16(offset + 4)
            let version = read16(offset + 6)
            let op = read32(offset + 8)
            guard length >= headerLength, headerLength >= 16, offset + length <= bytes.count else { break }
            let body = Data(bytes[(offset + headerLength)..<(offset + length)])
            offset += length
            switch op {
            case 8:
                result.append(.authReply(body))
                continue
            case 3:
                result.append(.heartbeatReply)
                continue
            case 5:
                break
            default:
                continue
            }
            switch version {
            case 2:
                // zlib：2 字节头 + 原始 deflate + 4 字节校验和
                guard body.count > 2, let inflated = inflate(body.dropFirst(2)) else { continue }
                result.append(contentsOf: messages(in: inflated, depth: depth + 1))
            case 0, 1:
                result.append(.message(body))
            default:
                continue // 没有请求 brotli（protover 3），收到也跳过
            }
        }
        return result
    }

    /// 解原始 deflate。用流式解码：读到 deflate 的结束块就停，末尾的 adler32 校验和不会让整包解压失败
    nonisolated private static func inflate(_ input: Data) -> Data? {
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        return Data(input).withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            var output = Data()
            while true {
                guard !Task.isCancelled, output.count < 8 * 1024 * 1024 else { return nil }
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: capacity - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK:
                    // 输入已经读完却还没到结束块：数据被截断，按已解出的部分处理
                    if stream.pointee.src_size == 0, stream.pointee.dst_size == capacity { return output.isEmpty ? nil : output }
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return output.isEmpty ? nil : output
                }
            }
        }
    }

    /// DANMU_MSG：info[0] = [_, 模式, 字号, 颜色, 时间戳, _, _, _, _, 抽奖类型, _, _, 是否表情, …]，info[1] = 内容
    nonisolated private static func parseDanmaku(_ body: Data) -> LiveDanmaku? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd = object["cmd"] as? String, cmd.hasPrefix("DANMU_MSG"),
              let info = object["info"] as? [Any], info.count > 1,
              let meta = info[0] as? [Any], let text = info[1] as? String, !text.isEmpty else { return nil }
        func int(_ index: Int) -> Int {
            guard index < meta.count else { return 0 }
            if let value = meta[index] as? Int { return value }
            if let value = meta[index] as? NSNumber { return value.intValue }
            return 0
        }
        let mode = int(1)
        let item = Danmaku(
            time: 0,
            mode: [1, 4, 5].contains(mode) ? mode : 1,
            fontSize: int(2) > 0 ? int(2) : 25,
            color: UInt32(truncatingIfNeeded: int(3) == 0 ? 0xFFFFFF : int(3)),
            content: text
        )
        return LiveDanmaku(item: item, isEmoticon: int(12) == 1, isLottery: int(9) != 0)
    }
}
