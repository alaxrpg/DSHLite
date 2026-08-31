import Foundation

/// 从 DSH stdout/stderr 中发现服务地址（fallback 路径）。
///
/// 只接受 loopback URL：http(s)://(127.0.0.1|localhost|[::1]):<port>
/// 不接受任何互联网 URL。
public struct ServerAddressDetector {
    /// 仅匹配 loopback 主机
    private static let loopbackHostPattern = "(?:127\\.0\\.0\\.1|localhost|\\[::1\\]|::1)"

    /// 匹配 loopback URL 的正则
    public static let urlPattern = #"https?://(?:127\.0\.0\.1|localhost|\[::1\]|::1):\d+"#

    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: urlPattern)

    /// 从文本中提取第一个 loopback URL（无则 nil）。
    public static func detectURL(in text: String) -> URL? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        let candidate = String(text[swiftRange])
        guard let url = URL(string: candidate) else { return nil }
        // 二次校验 host 必须是 loopback
        guard let host = url.host else { return nil }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1" else {
            return nil
        }
        // 拒绝非 http/https
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 从 DSH stdout 流中增量检测（简单实现：每次把累积文本重新扫描）。
    public static func detectURL(accumulated: String) -> URL? {
        detectURL(in: accumulated)
    }
}
