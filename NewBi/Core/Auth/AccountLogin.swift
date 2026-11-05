import Foundation
import Security

// MARK: - 人机验证（极验）

/// 一次待完成的人机验证：非 nil 时弹出验证页
struct CaptchaChallenge: Identifiable, Equatable, Sendable {
    let id = UUID()
    let gt: String
    let challenge: String
    /// 和验证结果一起提交的登录 token
    let token: String
}

/// 用户在验证页里完成拼图后拿到的结果
struct GeetestResult: Equatable, Sendable {
    let challenge: String
    let validate: String
    let seccode: String
}

private struct LoginCaptcha: Decodable, Sendable {
    struct Geetest: Decodable, Sendable {
        let gt: String
        let challenge: String
    }

    let token: String
    let geetest: Geetest?
}

private struct LoginKey: Decodable, Sendable {
    /// 盐，拼在密码前面一起加密
    let hash: String
    /// PEM 格式的 RSA 公钥
    let key: String
}

private struct LoginResult: Decodable, Sendable {
    /// 0 为登录成功；非 0 表示这次登录需要额外验证（风险账号、新设备）
    let status: Int?
    let message: String?
    let url: String?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case status, message, url
        case refreshToken = "refresh_token"
    }
}

private struct SMSSent: Decodable, Sendable {
    let captchaKey: String

    private enum CodingKeys: String, CodingKey {
        case captchaKey = "captcha_key"
    }
}

struct LoginFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 密码 / 短信验证码登录

/// B 站网页端的登录流程：
/// - 密码：人机验证 → 取公钥和盐（约 20 秒有效，所以验证通过后再取）→ RSA 加密「盐 + 密码」→ 提交
/// - 短信：人机验证 → 发验证码（拿到 captcha_key）→ 填验证码登录
/// 成功后 Cookie 由共享 Cookie 存储收下，refresh_token 进 Keychain。密码只在内存里待到提交为止，不保存、不打印
/// 短信登录可选的国家 / 地区代码（cid）
struct LoginCountry: Hashable, Sendable {
    let code: Int
    let name: String

    static let all: [LoginCountry] = [
        LoginCountry(code: 86, name: "中国大陆"), LoginCountry(code: 852, name: "中国香港"), LoginCountry(code: 853, name: "中国澳门"),
        LoginCountry(code: 886, name: "中国台湾"), LoginCountry(code: 1, name: "美国 / 加拿大"), LoginCountry(code: 81, name: "日本"),
        LoginCountry(code: 82, name: "韩国"), LoginCountry(code: 65, name: "新加坡"), LoginCountry(code: 60, name: "马来西亚"),
        LoginCountry(code: 61, name: "澳大利亚"), LoginCountry(code: 44, name: "英国"), LoginCountry(code: 49, name: "德国"),
        LoginCountry(code: 33, name: "法国"),
    ]
}

@MainActor
@Observable
final class AccountLoginModel {
    private enum Purpose {
        case password, sms
    }

    var account = ""
    var password = ""
    var countryCode = 86
    var phone = ""
    var code = ""

    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var hint: String?
    /// 非 nil 时弹出人机验证页
    var challenge: CaptchaChallenge?
    /// 重新获取验证码前的倒计时（秒）
    private(set) var countdown = 0
    /// 发验证码成功后拿到，登录时提交
    private(set) var captchaKey: String?
    /// 登录成功：页面据此刷新登录态并关闭
    private(set) var succeeded = false

    @ObservationIgnored private var purpose: Purpose?
    /// 验证页弹着、还没给结果：被下滑关掉时按取消处理
    @ObservationIgnored private var awaitingCaptcha = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    /// 网页端登录接口按来源校验，和 B 站网页一样带上 Origin / Referer
    private static let headers = ["Origin": "https://www.bilibili.com", "Referer": "https://www.bilibili.com/"]

    var canSubmitPassword: Bool { !isBusy && !account.trimmed.isEmpty && !password.isEmpty }
    var canSendCode: Bool { !isBusy && countdown == 0 && phone.trimmed.count >= 5 }
    var canSubmitSMS: Bool { !isBusy && captchaKey != nil && !code.trimmed.isEmpty && !phone.trimmed.isEmpty }

    func startPasswordLogin() {
        begin(.password)
    }

    func sendCode() {
        begin(.sms)
    }

    /// 先拿极验参数，弹出验证页；结果回来后接着走对应的流程
    private func begin(_ purpose: Purpose) {
        guard !isBusy else { return }
        self.purpose = purpose
        error = nil
        hint = nil
        isBusy = true
        Task {
            do {
                let captcha = try await BiliClient.shared.get(.loginCaptcha, as: LoginCaptcha.self)
                guard let geetest = captcha.geetest else { throw LoginFailure("暂时无法进行人机验证，请改用扫码登录") }
                awaitingCaptcha = true
                challenge = CaptchaChallenge(gt: geetest.gt, challenge: geetest.challenge, token: captcha.token)
            } catch {
                fail(error)
            }
        }
    }

    /// 验证页给出结果：result 为 nil 表示用户关掉了验证，或验证出错（message 为原因）
    func captchaFinished(_ result: GeetestResult?, for challenge: CaptchaChallenge, message: String?) {
        guard awaitingCaptcha else { return }
        awaitingCaptcha = false
        self.challenge = nil
        guard let result else {
            isBusy = false
            if let message { error = message }
            return
        }
        let purpose = purpose
        Task {
            do {
                switch purpose {
                case .password: try await loginWithPassword(result, token: challenge.token)
                case .sms: try await deliverCode(result, token: challenge.token)
                case nil: break
                }
                isBusy = false
            } catch {
                fail(error)
            }
        }
    }

    /// 验证页被下滑关掉（没给结果）：按取消处理
    func captchaDismissed() {
        guard awaitingCaptcha else { return }
        awaitingCaptcha = false
        challenge = nil
        isBusy = false
    }

    func loginWithSMS() {
        guard canSubmitSMS, let captchaKey else { return }
        error = nil
        isBusy = true
        let form = [
            "cid": "\(countryCode)", "tel": phone.trimmed, "code": code.trimmed,
            "source": "main_web", "captcha_key": captchaKey, "keep": "true",
        ]
        Task {
            do {
                let response = try await BiliClient.shared.post(.smsLogin, form: form, as: LoginResult.self, headers: Self.headers)
                try finish(response)
                isBusy = false
            } catch {
                fail(error)
            }
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    // MARK: 流程

    private func loginWithPassword(_ result: GeetestResult, token: String) async throws {
        // 盐约 20 秒内有效：人机验证可能要好一会儿，所以验证通过之后才取
        let key = try await BiliClient.shared.get(.loginKey, as: LoginKey.self)
        let encrypted = try PasswordCipher.encrypt(key.hash + password, publicKeyPEM: key.key)
        let response = try await BiliClient.shared.post(.passwordLogin, form: [
            "username": account.trimmed,
            "password": encrypted,
            "keep": "0",
            "token": token,
            "challenge": result.challenge,
            "validate": result.validate,
            "seccode": result.seccode,
            "source": "main_web",
        ], as: LoginResult.self, headers: Self.headers)
        try finish(response)
        password = ""
    }

    private func deliverCode(_ result: GeetestResult, token: String) async throws {
        let sent = try await BiliClient.shared.post(.smsSend, form: [
            "cid": "\(countryCode)",
            "tel": phone.trimmed,
            "source": "main_web",
            "token": token,
            "challenge": result.challenge,
            "validate": result.validate,
            "seccode": result.seccode,
        ], as: SMSSent.self, headers: Self.headers)
        captchaKey = sent.captchaKey
        hint = "验证码已发送"
        startCountdown()
    }

    private func finish(_ response: LoginResult) throws {
        guard (response.status ?? 0) == 0 else {
            let message = response.message.flatMap { $0.isEmpty ? nil : $0 }
            throw LoginFailure(message ?? "这次登录需要额外验证，请改用短信验证码登录或扫码登录")
        }
        if let token = response.refreshToken { Credentials.saveRefreshToken(token) }
        succeeded = true
    }

    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        isBusy = false
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown -= 1
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - 密码加密

/// 网页端密码登录：用接口给的 RSA 公钥（PEM / SPKI）对「盐 + 密码」做 PKCS#1 v1.5 加密，结果 Base64
enum PasswordCipher {
    static func encrypt(_ text: String, publicKeyPEM pem: String) throws -> String {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else { throw LoginFailure("登录公钥无效，请重试") }
        // SecKeyCreateWithData 要 PKCS#1 的 RSAPublicKey：PEM 是 SPKI 时剥掉外层
        let pkcs1 = pem.contains("BEGIN RSA PUBLIC KEY") ? der : (rsaPublicKey(fromSPKI: der) ?? der)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(text.utf8) as CFData, &error) as Data? else {
            throw LoginFailure("密码加密失败，请重试")
        }
        return encrypted.base64EncodedString()
    }

    /// SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }，取出里面的 RSAPublicKey
    static func rsaPublicKey(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0

        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            return value
        }

        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard readLength() != nil else { return nil }
        // AlgorithmIdentifier：整段跳过
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithmLength = readLength() else { return nil }
        index += algorithmLength
        // BIT STRING：第一个字节是未用位数（0）
        guard index < bytes.count, bytes[index] == 0x03 else { return nil }
        index += 1
        guard let bitLength = readLength(), bitLength > 1, index < bytes.count, bytes[index] == 0x00 else { return nil }
        index += 1
        let end = index + bitLength - 1
        guard end <= bytes.count else { return nil }
        return Data(bytes[index..<end])
    }
}
