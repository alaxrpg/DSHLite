import Foundation

/// 应用路径统一入口。
///
/// 所有文件系统位置集中在 AppPaths，避免路径散落在代码中。
/// - 配置目录: ~/Library/Application Support/DSHLite/
/// - 日志目录: ~/Library/Application Support/DSHLite/logs/
/// - 配置文件: ~/Library/Application Support/DSHLite/config.json
public enum AppPaths {
    /// 测试/开发覆盖：DSHLITE_HOME 指向后，所有路径以它为准（用于无沙箱环境测试）。
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DSHLITE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DSHLite", isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
