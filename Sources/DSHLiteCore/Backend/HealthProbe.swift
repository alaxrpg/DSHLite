import Foundation

/// Health Probe：HTTP readiness 检测。
///
/// 启动 DSH 后，每 200~500ms 探测 http://127.0.0.1:<port>/
/// 收到有效 HTTP Response => READY。
/// Startup timeout 600 秒（实测首次运行 DSH 完整 boot 可能长达 8 分钟，
/// 因为 npx 首次需要处理 npm package 下载/解析、DSH 加载 40+ 插件）。
/// 用户可通过 Settings 调整。
public struct HealthProbe: Sendable {
    /// 探测间隔（毫秒）
    public var intervalMS: UInt64 = 300
    /// 单次请求超时（秒）
    public var requestTimeout: TimeInterval = 2
    /// 总超时（秒），默认 600s（10 分钟，覆盖首次完整 boot）
    public var overallTimeout: TimeInterval = 600

    public init() {}

    /// 阻塞式探测（在后台任务中使用）。
    /// - Returns: true = ready
    public func waitUntilReady(port: UInt16, host: String = "127.0.0.1") async -> Bool {
        let url = URL(string: "http://\(host):\(port)/")!
        let deadline = Date().addingTimeInterval(overallTimeout)

        while Date() < deadline {
            if Task.isCancelled { return false }
            if await probe(url: url) {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalMS * 1_000_000)
        }
        return false
    }

    /// 单次探测。
    public func probe(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                // 任何有效 HTTP 响应（含 404/500）都说明服务已监听
                return (200..<600).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
