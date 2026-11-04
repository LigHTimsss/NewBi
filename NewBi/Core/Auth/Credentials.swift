import Foundation
import Security

/// 登录凭据放在哪：
/// - Cookie（SESSDATA、bili_jct、DedeUserID…）：系统 `HTTPCookieStorage.shared`，持久化在 App 沙盒里、受系统数据保护，
///   API 请求、媒体代理和后台下载共用这一份；不另存副本
/// - refresh_token：Keychain，仅本机、首次解锁后可读（后台唤醒也能读到），不进 iCloud 钥匙串、不随备份迁移到别的设备
/// - 退出登录时两边都清；不打印、不上传任何凭据
enum Credentials {
    static let refreshTokenAccount = "refresh_token"

    static var refreshToken: String? { Keychain.read(refreshTokenAccount) }

    static func saveRefreshToken(_ token: String) {
        guard !token.isEmpty else { return }
        Keychain.write(token, account: refreshTokenAccount)
    }

    /// 退出登录：删 B 站域下除设备标识（buvid*）以外的 Cookie，删 refresh_token
    static func clear() {
        Keychain.delete(refreshTokenAccount)
        clearCookies()
    }

    static func clearCookies() {
        let storage = HTTPCookieStorage.shared
        storage.cookies?
            .filter { $0.domain.hasSuffix("bilibili.com") && !$0.name.hasPrefix("buvid") }
            .forEach(storage.deleteCookie)
    }
}

/// 通用密码项的最小封装。更新用 SecItemUpdate 原地替换（轮换时不会出现「旧的删了、新的没写进去」的空窗）
enum Keychain {
    private static let service = "com.example.newbi.auth"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(account)
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Cookie 刷新（B 站网页端流程）：
/// 1. cookie/info 问服务器要不要刷新
/// 2. 用公钥把 `refresh_<时间戳>` 做 RSA-OAEP(SHA-256) 加密，换成 correspond 页面里的 refresh_csrf
/// 3. cookie/refresh 用 refresh_token 换新 Cookie（响应的 Set-Cookie 直接进共享 Cookie 存储）和新 refresh_token
/// 4. 新 token 写进 Keychain 后，用新 Cookie 的 csrf + 旧 token 确认，作废旧 Cookie
/// actor 串行：同一时间只有一次刷新在跑，后来的调用等它的结果
actor CookieRefresher {
    static let shared = CookieRefresher()

    private var running: Task<Bool, Never>?

    /// - Returns: 这次是否换了新 Cookie（换了的话调用方应重新拉一次用户信息）
    func refreshIfNeeded() async -> Bool {
        if let running { return await running.value }
        let task = Task { await Self.run() }
        running = task
        let refreshed = await task.value
        running = nil
        return refreshed
    }

    private struct Info: Decodable, Sendable {
        let refresh: Bool
        let timestamp: Int64?
    }

    private struct Refreshed: Decodable, Sendable {
        let refreshToken: String

        private enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private static func run() async -> Bool {
        guard let csrf = BiliClient.csrfToken, let token = Credentials.refreshToken else { return false }
        do {
            let info = try await BiliClient.shared.get(.cookieInfo(csrf: csrf), as: Info.self)
            guard info.refresh else { return false }
            // 服务器给的毫秒时间戳；没有时用本机时间往前 20 秒（本机时钟偏快会被拒）
            let timestamp = info.timestamp ?? Int64(Date.now.timeIntervalSince1970 * 1000) - 20_000
            let path = try correspondPath(timestamp: timestamp)
            let html = String(decoding: try await BiliClient.shared.data(.correspond(path: path)), as: UTF8.self)
            guard let refreshCSRF = refreshCSRF(in: html) else { return false }
            let result = try await BiliClient.shared.post(
                .cookieRefresh,
                form: ["csrf": csrf, "refresh_csrf": refreshCSRF, "source": "main_web", "refresh_token": token],
                as: Refreshed.self
            )
            // 刷新途中退出了登录：响应带回的新 Cookie 不能留下
            guard Credentials.refreshToken == token else {
                Credentials.clearCookies()
                return false
            }
            Credentials.saveRefreshToken(result.refreshToken)
            // 确认失败不影响新 Cookie 使用（旧 Cookie 只是晚些过期）
            if let fresh = BiliClient.csrfToken {
                try? await BiliClient.shared.post(.cookieRefreshConfirm, form: ["csrf": fresh, "refresh_token": token])
            }
            return true
        } catch {
            return false
        }
    }

    /// correspond 页面里 `<div id="1-name">…</div>` 的内容
    private static func refreshCSRF(in html: String) -> String? {
        guard let open = html.range(of: #"<div id="1-name">"#),
              let close = html.range(of: "</div>", range: open.upperBound..<html.endIndex) else { return nil }
        let value = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// B 站网页端公开的 RSA 公钥（1024 位，SPKI）
    private static let publicKey =
        "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDLgd2OAkcGVtoE3ThUREbio0Eg" +
        "Uc/prcajMKXvkCKFCWhJYJcLkcM2DKKcSeFpD/j6Boy538YXnR6VhcuUJOhH2x71" +
        "nzPjfdTcqMz7djHum0qSZA0AyCBDABUqCrfNgCiJ00Ra7GmRj+YCK1NJEuewlb40" +
        "JNrRuoEUXpabUzGB8QIDAQAB"

    private static func correspondPath(timestamp: Int64) throws -> String {
        // SecKeyCreateWithData 要 PKCS#1 的 RSAPublicKey：去掉 SPKI 外层固定的 22 字节头
        guard let spki = Data(base64Encoded: publicKey), spki.count > 22 else { throw BiliError.badURL }
        let pkcs1 = Data(spki.dropFirst(22))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, Data("refresh_\(timestamp)".utf8) as CFData, &error) as Data? else {
            throw BiliError.emptyData
        }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }
}
