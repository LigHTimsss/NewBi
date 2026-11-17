import Foundation
import os
import Security

/// 登录凭据放在哪：
/// - Cookie（SESSDATA、bili_jct、DedeUserID…）：系统 `HTTPCookieStorage.shared`，持久化在 App 沙盒里、受系统数据保护，
///   API 请求、媒体代理和后台下载共用这一份；不另存副本
/// - refresh_token：Keychain，仅本机、首次解锁后可读（后台唤醒也能读到），不进 iCloud 钥匙串、不随备份迁移到别的设备
/// - 退出登录时两边都清；不打印、不上传任何凭据
enum Credentials {
    static let refreshTokenAccount = "refresh_token"

    /// Keychain 暂时写不进去时（比如设备还没解锁过）先放在内存里：
    /// 刷新 Cookie 后服务器已作废旧 token，新的丢了下次刷新就必然失败，最后被悄悄登出
    private static let pendingToken = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let sessionGeneration = OSAllocatedUnfairLock(initialState: UUID())

    /// 在登录请求发出之前换代，旧刷新响应即使随后成功也不能覆盖新会话。
    static func beginLogin() -> UUID {
        sessionGeneration.withLock { generation in
            generation = UUID()
            return generation
        }
    }

    static func isCurrent(_ generation: UUID) -> Bool {
        sessionGeneration.withLock { $0 == generation }
    }

    static func cancelLogin(_ generation: UUID) {
        sessionGeneration.withLock { if $0 == generation { $0 = UUID() } }
    }

    static var deviceCookies: [HTTPCookie] {
        (HTTPCookieStorage.shared.cookies ?? []).filter {
            ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")) && $0.name.hasPrefix("buvid")
        }
    }

    struct RefreshSnapshot: Sendable {
        let generation: UUID
        let token: String
        let csrf: String
        let cookies: [HTTPCookie]
    }

    static func refreshSnapshot() -> RefreshSnapshot? {
        sessionGeneration.withLock { generation in
            guard let token = refreshToken, let csrf = BiliClient.csrfToken else { return nil }
            return RefreshSnapshot(generation: generation, token: token, csrf: csrf,
                                   cookies: HTTPCookieStorage.shared.cookies ?? [])
        }
    }

    /// 校验和提交在同一临界区，取消/退出不能插入两者之间。
    static func commit(cookies: [HTTPCookie], token: String?, generation: UUID, replacingToken: String? = nil) -> Bool {
        sessionGeneration.withLock { current in
            guard current == generation,
                  replacingToken == nil || replacingToken == refreshToken else { return false }
            let cookies = cookies.filter { $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com") }
            guard cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }),
                  cookies.contains(where: { $0.name == "DedeUserID" && !$0.value.isEmpty }) else { return false }
            clearCookiesUnlocked()
            cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
            if let token, !token.isEmpty { saveRefreshTokenUnlocked(token) }
            else {
                pendingToken.withLock { $0 = nil }
                Keychain.delete(refreshTokenAccount)
            }
            return true
        }
    }

    static var refreshToken: String? {
        pendingToken.withLock { $0 } ?? Keychain.read(refreshTokenAccount)
    }

    /// - Returns: 是否已经写进 Keychain（false 时 token 暂存在内存，回到前台会再写一次）
    @discardableResult
    static func saveRefreshToken(_ token: String) -> Bool {
        sessionGeneration.withLock { _ in saveRefreshTokenUnlocked(token) }
    }

    @discardableResult
    private static func saveRefreshTokenUnlocked(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if Keychain.write(token, account: refreshTokenAccount) {
            pendingToken.withLock { $0 = nil }
            return true
        }
        pendingToken.withLock { $0 = token }
        return false
    }

    /// 回到前台时把暂存在内存里的 token 补写进 Keychain
    static func retryPendingSave() {
        sessionGeneration.withLock { _ in
            guard let token = pendingToken.withLock({ $0 }) else { return }
            saveRefreshTokenUnlocked(token)
        }
    }

    /// 当前 Cookie 属于哪个账号（DedeUserID）
    static var cookieMid: String? {
        HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.bilibili.com")!)?
            .first { $0.name == "DedeUserID" }?.value
    }

    /// 退出登录：删 B 站域下除设备标识（buvid*）以外的 Cookie，删 refresh_token
    static func clear() {
        sessionGeneration.withLock { generation in
            generation = UUID()
            pendingToken.withLock { $0 = nil }
            Keychain.delete(refreshTokenAccount)
            clearCookiesUnlocked()
        }
    }

    static func clearCookies() {
        sessionGeneration.withLock { generation in
            generation = UUID()
            clearCookiesUnlocked()
        }
    }

    private static func clearCookiesUnlocked() {
        let storage = HTTPCookieStorage.shared
        storage.cookies?
            .filter { ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")) && !$0.name.hasPrefix("buvid") }
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
/// 3. cookie/refresh 在独立 Cookie 容器里换新 Cookie 和 token，会话未变化才提交
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
        guard let snapshot = Credentials.refreshSnapshot() else { return false }
        let csrf = snapshot.csrf, token = snapshot.token
        let client = BiliClient(isolatedCookies: snapshot.cookies)
        defer { Task { await client.invalidate() } }
        do {
            let info = try await client.get(.cookieInfo(csrf: csrf), as: Info.self)
            guard info.refresh, Credentials.isCurrent(snapshot.generation) else { return false }
            // 服务器给的毫秒时间戳；没有时用本机时间往前 20 秒（本机时钟偏快会被拒）
            let timestamp = info.timestamp ?? Int64(Date.now.timeIntervalSince1970 * 1000) - 20_000
            let path = try correspondPath(timestamp: timestamp)
            let html = String(decoding: try await client.data(.correspond(path: path)), as: UTF8.self)
            guard let refreshCSRF = refreshCSRF(in: html), Credentials.isCurrent(snapshot.generation) else { return false }
            let result = try await client.post(
                .cookieRefresh,
                form: ["csrf": csrf, "refresh_csrf": refreshCSRF, "source": "main_web", "refresh_token": token],
                as: Refreshed.self
            )
            let cookies = await client.cookies()
            guard !Task.isCancelled,
                  Credentials.commit(cookies: cookies, token: result.refreshToken,
                                     generation: snapshot.generation, replacingToken: token) else { return false }
            // 确认失败不影响新 Cookie 使用（旧 Cookie 只是晚些过期）
            if let fresh = cookies.first(where: { $0.name == "bili_jct" })?.value {
                try? await client.post(.cookieRefreshConfirm, form: ["csrf": fresh, "refresh_token": token])
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
