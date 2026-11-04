import Foundation

enum BiliError: LocalizedError {
    case badURL
    case http(Int)
    case api(code: Int, message: String)
    case decoding(Error)
    case emptyData

    var errorDescription: String? {
        switch self {
        case .badURL: "无效的请求地址"
        case .http(let status): "网络错误（HTTP \(status)）"
        case .api(let code, let message): "\(message)（\(code)）"
        case .decoding: "数据解析失败"
        case .emptyData: "服务器未返回数据"
        }
    }
}

struct BiliResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let code: Int
    let message: String
    let data: T?
}

actor BiliClient {
    static let shared = BiliClient()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let referer = "https://www.bilibili.com/"
    /// 视频 CDN 校验 Referer/UA，AVURLAsset 需带上
    static let mediaHeaders = ["User-Agent": userAgent, "Referer": referer]

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var signer: WBISigner?
    private var signerDate: Date?

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Referer": Self.referer]
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// 解出 data，code != 0 抛错
    func get<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let response: BiliResponse<T> = try await raw(endpoint)
        guard response.code == 0 else { throw BiliError.api(code: response.code, message: response.message) }
        guard let data = response.data else { throw BiliError.emptyData }
        return data
    }

    /// 表单 POST，需要返回的 data（如发评论后拿到新评论）
    func post<T: Decodable & Sendable>(_ endpoint: Endpoint, form: [String: String], as type: T.Type) async throws -> T {
        let decoded = try decoder.decode(BiliResponse<T>.self, from: await postData(endpoint, form: form))
        guard decoded.code == 0 else { throw BiliError.api(code: decoded.code, message: decoded.message) }
        guard let result = decoded.data else { throw BiliError.emptyData }
        return result
    }

    /// 表单 POST，只看 code（点赞、关注等接口成功时不返回 data）
    func post(_ endpoint: Endpoint, form: [String: String]) async throws {
        let status = try decoder.decode(Status.self, from: await postData(endpoint, form: form))
        guard status.code == 0 else { throw BiliError.api(code: status.code, message: status.message) }
    }

    /// JSON POST（动态点赞等新接口）
    func postJSON<Body: Encodable & Sendable>(_ endpoint: Endpoint, body: Body) async throws {
        var request = URLRequest(url: try await url(for: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        let status = try decoder.decode(Status.self, from: data)
        guard status.code == 0 else { throw BiliError.api(code: status.code, message: status.message) }
    }

    private struct Status: Decodable {
        let code: Int
        let message: String
    }

    private func postData(_ endpoint: Endpoint, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: try await url(for: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    /// 写操作需要的 csrf（登录后 Cookie 中的 bili_jct）
    static var csrfToken: String? {
        HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.bilibili.com")!)?
            .first { $0.name == "bili_jct" }?.value
    }

    /// 原始字节（弹幕 Protobuf 等）
    func data(_ endpoint: Endpoint) async throws -> Data {
        let (data, response) = try await session.data(from: url(for: endpoint))
        try Self.check(response)
        return data
    }

    /// 未登录时 nav 返回 -101，但 data 里仍有 wbi_img，所以不按 code 判错
    func nav() async throws -> NavInfo {
        let response: BiliResponse<NavInfo> = try await raw(.nav)
        guard let data = response.data else { throw BiliError.api(code: response.code, message: response.message) }
        return data
    }

    /// 首次启动写入 buvid3/buvid4，否则大量接口会触发 -352 风控
    func ensureBuvid() async {
        let storage = HTTPCookieStorage.shared
        let site = URL(string: "https://www.bilibili.com")!
        if storage.cookies(for: site)?.contains(where: { $0.name == "buvid3" }) == true { return }
        guard let spi = try? await get(.fingerSpi, as: FingerSPI.self) else { return }
        for (name, value) in [("buvid3", spi.b3), ("buvid4", spi.b4)] {
            let cookie = HTTPCookie(properties: [
                .domain: ".bilibili.com", .path: "/", .name: name, .value: value,
                .expires: Date.now.addingTimeInterval(365 * 86_400),
            ])
            if let cookie { storage.setCookie(cookie) }
        }
    }

    // MARK: - Private

    private func raw<T: Decodable & Sendable>(_ endpoint: Endpoint, retry: Bool = true) async throws -> BiliResponse<T> {
        let (data, response) = try await session.data(from: url(for: endpoint))
        try Self.check(response)
        let decoded: BiliResponse<T>
        do {
            decoded = try decoder.decode(BiliResponse<T>.self, from: data)
        } catch {
            throw BiliError.decoding(error)
        }
        // WBI key 失效：刷新后重试一次
        if decoded.code == -352, endpoint.signed, retry {
            signer = nil
            return try await raw(endpoint, retry: false)
        }
        return decoded
    }

    private func url(for endpoint: Endpoint) async throws -> URL {
        guard var components = URLComponents(string: endpoint.host + endpoint.path) else { throw BiliError.badURL }
        if endpoint.signed {
            components.percentEncodedQuery = try await currentSigner().signedQuery(endpoint.query)
        } else if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw BiliError.badURL }
        return url
    }

    /// WBI key 每天轮换，按自然日缓存
    private func currentSigner() async throws -> WBISigner {
        if let signer, let signerDate, Calendar.current.isDateInToday(signerDate) { return signer }
        let info = try await nav()
        guard let img = info.wbiImg?.imgKey, let sub = info.wbiImg?.subKey else { throw BiliError.emptyData }
        let fresh = WBISigner(imgKey: img, subKey: sub)
        signer = fresh
        signerDate = .now
        return fresh
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BiliError.http(http.statusCode)
        }
    }
}

private extension String {
    /// x-www-form-urlencoded：`+`、`&` 等都要编码
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .formAllowed) ?? self
    }
}

private extension CharacterSet {
    static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
}
