import Foundation

/// DSH Lite 用户配置（Codable JSON）。
///
/// 存储位置: ~/Library/Application Support/DSHLite/config.json
/// 注意：本文件与 DSH 自身的 `~/.dsh` 完全无关，DSH Lite 绝不读写 `~/.dsh`。
public struct Settings: Codable, Equatable {
    /// runtime 选择: "auto"（默认）或 "custom"
    public var runtime: String
    /// npx 包 spec，例如 "@deepseek-ai/dsh" 或 "@deepseek-ai/dsh@0.1.1-rc.2"
    public var packageSpec: String
    /// 自定义可执行文件路径（runtime == "custom" 时使用；null = 未配置）
    public var customExecutable: String?
    /// 崩溃后是否自动重启
    public var autoRestart: Bool
    /// 窗口关闭（Cmd+W）后 DSH 后台是否继续运行
    public var keepRunningWhenWindowClosed: Bool
    /// 代理 URL（如 http://127.0.0.1:7890）。空 = 继承进程环境。
    /// Finder 启动的 App 通常没有 shell 代理环境，此字段让用户显式配置。
    public var proxyURL: String?
    /// 零信任网关允许的浏览器访问 authority（host 或 host:port）。DSH 仍只监听 loopback。
    public var trustedHosts: [String]
    /// 可选的固定 loopback 端口，仅供零信任网关 upstream 稳定指向；nil = 随机端口。
    public var fixedPort: UInt16?

    public init(
        runtime: String = "auto",
        packageSpec: String = "@deepseek-ai/dsh",
        customExecutable: String? = nil,
        autoRestart: Bool = true,
        keepRunningWhenWindowClosed: Bool = true,
        proxyURL: String? = nil,
        trustedHosts: [String] = [],
        fixedPort: UInt16? = nil
    ) {
        self.runtime = runtime
        self.packageSpec = packageSpec
        self.customExecutable = customExecutable
        self.autoRestart = autoRestart
        self.keepRunningWhenWindowClosed = keepRunningWhenWindowClosed
        self.proxyURL = proxyURL
        self.trustedHosts = trustedHosts
        self.fixedPort = fixedPort
    }

    private enum CodingKeys: String, CodingKey { case runtime, packageSpec, customExecutable, autoRestart, keepRunningWhenWindowClosed, proxyURL, trustedHosts, fixedPort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? defaults.runtime
        packageSpec = try c.decodeIfPresent(String.self, forKey: .packageSpec) ?? defaults.packageSpec
        customExecutable = try c.decodeIfPresent(String.self, forKey: .customExecutable)
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? defaults.autoRestart
        keepRunningWhenWindowClosed = try c.decodeIfPresent(Bool.self, forKey: .keepRunningWhenWindowClosed) ?? defaults.keepRunningWhenWindowClosed
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL)
        trustedHosts = try c.decodeIfPresent([String].self, forKey: .trustedHosts) ?? defaults.trustedHosts
        fixedPort = try c.decodeIfPresent(UInt16.self, forKey: .fixedPort) ?? defaults.fixedPort
    }

    public func validate() throws {
        guard !packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !packageSpec.contains("\0"), !packageSpec.contains("\n"), !packageSpec.contains("\r") else {
            throw SettingsValidationError.invalidPackageSpec
        }
        if runtime == "custom" {
            guard let path = customExecutable, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw SettingsValidationError.invalidCustomExecutable
            }
        }
        if fixedPort == 0 {
            throw SettingsValidationError.invalidFixedPort("0")
        }
        _ = try Self.normalizedTrustedHosts(trustedHosts)
    }

    /// 解析设置面板中的固定端口文本；空文本表示使用随机端口。
    public static func parseFixedPort(_ text: String) throws -> UInt16? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = UInt32(value), parsed > 0, parsed <= UInt32(UInt16.max) else {
            throw SettingsValidationError.invalidFixedPort(value)
        }
        return UInt16(parsed)
    }

    /// 将设置面板中的逗号/换行分隔文本解析为规范化、去重后的 authority 列表。
    public static func parseTrustedHosts(_ text: String) throws -> [String] {
        let values = text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        return try normalizedTrustedHosts(values)
    }

    /// 校验并规范化 host 或 host:port。只接受 DNS 名称和 IPv4，不接受 URL/路径/认证信息。
    public static func normalizedTrustedHosts(_ hosts: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in hosts {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            guard !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.isASCII == false }),
                  !value.contains("/"), !value.contains("?"), !value.contains("#"), !value.contains("@"),
                  !value.contains("\\"), !value.contains("://") else {
                throw SettingsValidationError.invalidTrustedHost(raw)
            }

            let host: String
            let port: UInt16?
            let colonCount = value.reduce(into: 0) { count, character in
                if character == ":" { count += 1 }
            }
            if colonCount == 0 {
                host = value
                port = nil
            } else if colonCount == 1 {
                let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
                guard pieces.count == 2, !pieces[1].isEmpty,
                      pieces[1].allSatisfy({ $0.isNumber }),
                      let parsedPort = UInt32(pieces[1]), parsedPort > 0, parsedPort <= UInt32(UInt16.max) else {
                    throw SettingsValidationError.invalidTrustedHost(raw)
                }
                host = String(pieces[0])
                port = UInt16(parsedPort)
            } else {
                // IPv6 与带括号 authority 不在本工具的支持范围内，避免把 URL 误当作 trust host。
                throw SettingsValidationError.invalidTrustedHost(raw)
            }

            let normalizedHost = host.lowercased()
            guard Self.isValidTrustedHostName(normalizedHost) else {
                throw SettingsValidationError.invalidTrustedHost(raw)
            }
            let authority = port.map { "\(normalizedHost):\($0)" } ?? normalizedHost
            if seen.insert(authority).inserted { result.append(authority) }
        }
        return result
    }

    private static func isValidTrustedHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        // IPv4 作为单独的严格格式接受；其余输入按 DNS label 校验。
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return octets.allSatisfy { part in
                guard part.count <= 3, let number = UInt16(part) else { return false }
                return number <= 255 && (part.count == 1 || !part.hasPrefix("0"))
            }
        }
        guard octets.count >= 1 else { return false }
        return octets.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public enum SettingsValidationError: Error, LocalizedError {
    case invalidPackageSpec
    case invalidCustomExecutable
    case invalidTrustedHost(String)
    case invalidFixedPort(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPackageSpec: return "DSH 包 spec 不能为空，且不能包含换行或 NUL"
        case .invalidCustomExecutable: return "自定义可执行文件必须是存在且可执行的绝对路径"
        case .invalidTrustedHost(let host): return "信任域名无效：\(host)。请输入 host 或 host:port，不要包含 scheme、路径、认证信息、空白或非法端口"
        case .invalidFixedPort(let port): return "固定端口无效：\(port)。请留空使用随机端口，或输入 1 到 65535 之间的数字"
        }
    }
}

/// SettingsStore：加载/保存/观察配置。
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    public private(set) var settings: Settings
    private let url: URL
    private let lock = NSLock()

    /// 配置变更通知（主线程派发）
    public var onChange: ((Settings) -> Void)?

    public init(url: URL = AppPaths.configFile, initial: Settings = Settings()) {
        self.url = url
        self.settings = initial
        load()
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // 首次运行无配置文件：使用默认值（proxyURL 由用户手动填写，绝不自动探测）
            save()
            return
        }
        do {
            var decoded = try JSONDecoder().decode(Settings.self, from: data)
            // 容错：只做字段级合并，避免旧版本配置缺少新字段时整体失效
            let defaults = Settings()
            if decoded.runtime.isEmpty { decoded.runtime = defaults.runtime }
            if decoded.packageSpec.isEmpty { decoded.packageSpec = defaults.packageSpec }
            lock.lock()
            settings = decoded
            lock.unlock()
        } catch {
            // 配置损坏：带时间戳备份后回退默认，保留用户数据供恢复。
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingPathExtension().appendingPathExtension("invalid-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            LogStore.shared.log(.config, "配置损坏，已备份到 \(backup.lastPathComponent)")
            save()
        }
    }

    public func update(_ mutate: (inout Settings) -> Void) {
        lock.lock()
        var updated = settings
        mutate(&updated)
        do {
            try updated.validate()
        } catch {
            lock.unlock()
            LogStore.shared.log(.config, "配置校验失败: \(error.localizedDescription)")
            return
        }
        settings = updated
        lock.unlock()
        save()
        onChange?(settings)
    }

    /// 校验并保存配置；失败时不改变当前配置。
    public func updateValidated(_ mutate: (inout Settings) -> Void) throws {
        lock.lock(); var updated = settings; mutate(&updated); lock.unlock()
        try updated.validate()
        try saveThrowing(updated)
        lock.lock(); settings = updated; lock.unlock()
        onChange?(updated)
    }

    private func save() {
        lock.lock()
        let snapshot = settings
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            LogStore.shared.log(.config, "保存配置失败: \(error.localizedDescription)")
        }
    }

    private func saveThrowing(_ snapshot: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
