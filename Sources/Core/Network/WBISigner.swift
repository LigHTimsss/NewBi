import Foundation
import CryptoKit

/// B 站 Web 接口 WBI 签名
/// 1. img_key + sub_key 按置换表重排取前 32 位得到 mixin_key
/// 2. 参数加 wts，按 key 排序，过滤 `!'()*`，URL 编码拼接
/// 3. w_rid = md5(query + mixin_key)
struct WBISigner: Sendable {
    private static let table = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
        26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36,
        20, 34, 44, 52,
    ]

    let mixinKey: String

    init(imgKey: String, subKey: String) {
        let raw = Array(imgKey + subKey)
        mixinKey = String(Self.table.compactMap { $0 < raw.count ? raw[$0] : nil }.prefix(32))
    }

    /// 返回已编码的 query 字符串（含 wts、w_rid），直接作为 percentEncodedQuery 使用
    func signedQuery(_ params: [String: String], now: Date = .now) -> String {
        var params = params
        params["wts"] = String(Int(now.timeIntervalSince1970))
        let query = params.keys.sorted()
            .map { key in
                let value = params[key, default: ""].filter { !"!'()*".contains($0) }
                return "\(key.wbiEncoded)=\(value.wbiEncoded)"
            }
            .joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        let rid = digest.map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + rid
    }
}

private extension String {
    /// 与 JS encodeURIComponent 一致（`!'()*` 已被过滤）
    var wbiEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .wbiAllowed) ?? self
    }
}

private extension CharacterSet {
    static let wbiAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
}
