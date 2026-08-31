import Foundation

/// 启动规格：可执行文件 + 参数 + 环境（ChildProcessRunner 的输入）。
///
/// 由 BackendSupervisor 依据用户配置（Settings）构造，不包含任何探测逻辑。
public struct LaunchSpec: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// 脱敏描述（只打印环境变量名列表，绝不打印值——值中可能含代理凭据）。
    public var redactedDescription: String {
        let envKeys = environment.keys.sorted().joined(separator: ",")
        return "LaunchSpec(exec=\(executable.path), argCount=\(arguments.count), envKeys=[\(envKeys)])"
    }

    /// POSIX shell 单参数引用。输出可安全嵌入 zsh/bash 命令，不解释变量、重定向或命令替换。
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// npm 全局更新的轻量状态。
public enum DSHUpdateState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed(exitCode: Int32?, reason: String)
}

public enum DSHUpdateError: Error, LocalizedError, Equatable {
    case unavailableForCustomRuntime
    case alreadyRunning
    case invalidSettings(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableForCustomRuntime:
            return "自定义运行时不支持更新 DSH"
        case .alreadyRunning:
            return "DSH 更新已在进行中"
        case .invalidSettings(let reason):
            return "DSH 更新设置无效：\(reason)"
        case .startFailed(let reason):
            return "无法启动 DSH 更新：\(reason)"
        }
    }
}

/// 仅负责构造 npm 更新命令，便于离线测试且不引入 DSH 版本/内部 API 依赖。
public struct DSHUpdateCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(settings: Settings, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard settings.runtime == "auto" else {
            throw DSHUpdateError.unavailableForCustomRuntime
        }
        do {
            try settings.validate()
        } catch {
            throw DSHUpdateError.invalidSettings(error.localizedDescription)
        }

        var updateEnvironment = environment
        if updateEnvironment["npm_config_cache"] == nil {
            updateEnvironment["npm_config_cache"] = AppPaths.supportDirectory
                .appendingPathComponent("npm-cache").path
        }
        if let proxyURL = settings.proxyURL, !proxyURL.isEmpty {
            for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
                updateEnvironment[key] = proxyURL
            }
        }

        // `--` 明确结束 npm option 解析，即使 packageSpec 以 `-` 开头也只能作为包参数。
        let command = "exec npm install -g -- \(LaunchSpec.shellQuote(settings.packageSpec))"
        self.executable = URL(fileURLWithPath: "/bin/zsh")
        self.arguments = ["-lic", command]
        self.environment = updateEnvironment
    }

    public var redactedDescription: String {
        let keys = environment.keys.sorted().joined(separator: ",")
        return "DSHUpdateCommand(exec=\(executable.path), argCount=\(arguments.count), envKeys=[\(keys)])"
    }
}

/// 受控的 npm 更新进程。每个实例同一时间只允许一个更新，进程退出后可再次触发。
public final class DSHUpdater: @unchecked Sendable {
    private let runner = ChildProcessRunner()
    private let lock = NSLock()
    private var running = false

    public var onStateChange: ((DSHUpdateState) -> Void)?

    public init() {
        runner.onOutput = { text, isStdout in
            LogStore.shared.log(isStdout ? .stdout : .stderr, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        runner.onExit = { [weak self] info in
            guard let self else { return }
            self.lock.lock()
            self.running = false
            self.lock.unlock()
            if info.wasTerminatedByUs {
                return
            }
            if let code = info.exitCode, code == 0 {
                self.onStateChange?(.succeeded)
                LogStore.shared.log(.lifecycle, "DSH npm 更新完成")
            } else {
                let reason = "npm install 失败（exit code \(info.exitCode ?? -1)\(info.signal.map { ", signal \($0)" } ?? "")"
                self.onStateChange?(.failed(exitCode: info.exitCode, reason: reason))
                LogStore.shared.log(.lifecycle, reason)
            }
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    @discardableResult
    public func start(settings: Settings) throws -> DSHUpdateCommand {
        let command = try DSHUpdateCommand(settings: settings)
        lock.lock()
        guard !running else {
            lock.unlock()
            throw DSHUpdateError.alreadyRunning
        }
        running = true
        lock.unlock()
        do {
            LogStore.shared.log(.launcher, command.redactedDescription)
            _ = try runner.start(spec: LaunchSpec(
                executable: command.executable,
                arguments: command.arguments,
                environment: command.environment
            ))
            onStateChange?(.running)
            return command
        } catch {
            lock.lock()
            running = false
            lock.unlock()
            throw DSHUpdateError.startFailed(error.localizedDescription)
        }
    }

    /// App 退出时终止更新进程组；正常完成时不会触发该路径。
    public func stop() {
        lock.lock()
        let shouldStop = running
        lock.unlock()
        guard shouldStop else { return }
        runner.stop(graceSeconds: 3)
        lock.lock()
        running = false
        lock.unlock()
    }
}
