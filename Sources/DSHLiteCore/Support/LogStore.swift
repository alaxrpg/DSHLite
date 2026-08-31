import Foundation

/// 滚动日志存储。
///
/// - 单文件 <= 5 MB
/// - 最多保留 3 个文件（当前 + 2 个轮转）
/// - 线程安全（内部串行队列）
/// - 绝不记录：API Key、完整环境变量、用户 Prompt、DSH Session 内容
public final class LogStore: @unchecked Sendable {
    public enum Category: String {
        case launcher = "launcher"
        case stdout = "stdout"
        case stderr = "stderr"
        case lifecycle = "lifecycle"
        case health = "health"
        case web = "web"
        case config = "config"
    }

    public static let shared = LogStore()

    public static let maxFileSize: UInt64 = 5 * 1024 * 1024 // 5 MB
    public static let maxFiles = 3

    private let queue = DispatchQueue(label: "com.dshlite.logstore", qos: .utility)
    private let fileHandleQueue = DispatchQueue(label: "com.dshlite.logstore.file", qos: .utility)
    private let formatter: DateFormatter
    private let url: URL

    /// 最近日志（内存环形缓冲，供 UI 展示）
    private var ring: [String] = []
    private let ringCapacity = 500

    public init(url: URL = AppPaths.logsDirectory.appendingPathComponent("dshlite.log")) {
        self.url = url
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter.locale = Locale(identifier: "en_US_POSIX")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func log(_ category: Category, _ message: String) {
        queue.async {
            let line = "[\(self.formatter.string(from: Date()))] [\(category.rawValue)] \(Self.redact(message))\n"
            self.ring.append(line)
            if self.ring.count > self.ringCapacity {
                self.ring.removeFirst(self.ring.count - self.ringCapacity)
            }
            self.appendToFile(line)
        }
    }

    /// 统一脱敏入口，供日志写入和单元测试复用。
    internal static func redact(_ input: String) -> String {
        var value = input
        // URL query 中的 token 等字段先处理，避免后续通用键值规则漏掉 '&' 分隔的值。
        let queryPatterns: [(String, String)] = [
            (#"(?i)([?&](?:token|access[_-]?token|refresh[_-]?token|auth[_-]?token|_authToken|api[-_]?key|npm[_-]?token)=)[^&#\s]+"#, "$1[REDACTED]")
        ]
        for (pattern, replacement) in queryPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..., in: value)
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            }
        }

        let patterns: [(String, String)] = [
            // Header 形式：Authorization: Basic/Bearer <credential>。
            (#"(?i)(\bauthorization\s*[:=]\s*(?:basic|bearer)\s+)[^\s,;]+"#, "$1[REDACTED]"),
            // 环境变量、JSON 或 CLI 键值形式；保留键和分隔符，不保留完整值。
            (#"(?i)([\"']?(?:token|access[_-]?token|refresh[_-]?token|auth[_-]?token|_authToken|authorization|npm[_-]?token|api[-_]?key|secret|password)[\"']?\s*[:=]\s*[\"']?)[^\"'\s,;&]+([\"']?)"#, "$1[REDACTED]$2"),
            // URL userinfo：仅保留 scheme 和 host，凭据替换为占位符。
            (#"(?i)((?:https?|socks5?)://)[^/\s:@]+:[^/\s@]+@"#, "$1[REDACTED]@")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..., in: value)
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            }
        }
        return value
    }

    /// 同步读取最近日志行（UI 使用；避免阻塞主线程的耗时文件 IO 留在文件侧）
    public func recentLines(limit: Int = 200) -> [String] {
        queue.sync {
            Array(self.ring.suffix(limit))
        }
    }

    public var recentText: String {
        recentLines().joined()
    }

    // MARK: - 文件轮转

    private func appendToFile(_ line: String) {
        fileHandleQueue.sync {
            let fm = FileManager.default
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > Self.maxFileSize {
                rotate()
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    do { try handle.write(contentsOf: data) }
                    catch { NSLog("DSHLite 日志写入失败: %@", error.localizedDescription) }
                }
            } else {
                // 首次创建
                do { try line.data(using: .utf8)?.write(to: url) }
                catch { NSLog("DSHLite 日志创建失败: %@", error.localizedDescription) }
            }
        }
    }

    private func rotate() {
        let fm = FileManager.default
        // dshlite.log -> dshlite.1.log -> dshlite.2.log，删除最老的
        for index in stride(from: Self.maxFiles - 2, through: 1, by: -1) {
            let from = url.deletingLastPathComponent().appendingPathComponent("dshlite.\(index).log")
            let to = url.deletingLastPathComponent().appendingPathComponent("dshlite.\(index + 1).log")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }
        let first = url.deletingLastPathComponent().appendingPathComponent("dshlite.1.log")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: url, to: first)
    }
}
