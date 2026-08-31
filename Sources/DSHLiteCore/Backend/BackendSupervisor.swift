import Foundation

/// DSH 后端监督器——纯套壳。
///
/// 职责：
/// 1. 用用户配置构造启动命令
/// 2. 随机或固定 loopback 端口启动 DSH Web
/// 3. HealthProbe 真实 HTTP 探测
/// 4. 崩溃自动重启：0s/1s/3s 退避，快速连续崩溃最多 3 次
/// 5. 退出时 killpg 清理进程组
public actor BackendSupervisor {
    public private(set) var phase: BackendPhase = .stopped
    public private(set) var currentURL: URL?
    public private(set) var failureReason: String?
    public private(set) var exitCode: Int32?
    public private(set) var port: UInt16?
    public private(set) var restartCount: Int = 0

    private let runner = ChildProcessRunner()
    private let publisher: BackendStatePublisher
    private let packageSpec: String
    private let customCommand: String?
    private let proxyURL: String?
    private let trustedHosts: [String]
    private let fixedPort: UInt16?
    private let autoRestart: Bool

    private var startTask: Task<Void, Never>?
    private var stopRequested = false
    private var consecutiveRestarts = 0
    private var processExited = false

    /// READY 后稳定达到该时长，再把此前的快速崩溃计数清零。
    /// 不能刚 READY 就清零，否则 “READY → 很快退出” 会无限自动重启。
    private let stableRunResetInterval: TimeInterval = 60
    private var readySince: Date?

    public init(
        publisher: BackendStatePublisher,
        packageSpec: String,
        customCommand: String? = nil,
        proxyURL: String? = nil,
        trustedHosts: [String] = [],
        fixedPort: UInt16? = nil,
        autoRestart: Bool = true
    ) {
        self.publisher = publisher
        self.packageSpec = packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "@deepseek-ai/dsh"
            : packageSpec
        self.customCommand = customCommand
        self.proxyURL = proxyURL
        self.trustedHosts = (try? Settings.normalizedTrustedHosts(trustedHosts)) ?? trustedHosts
        self.fixedPort = fixedPort
        self.autoRestart = autoRestart

        runner.onExit = { [weak self] info in
            Task { [weak self] in
                await self?.handleExit(info: info)
            }
        }
        runner.onOutput = { text, isStdout in
            LogStore.shared.log(
                isStdout ? .stdout : .stderr,
                text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - 生命周期

    public func start() {
        guard phase == .stopped || phase == .failed else { return }
        resetCrashBudget()
        stopRequested = false
        startTask = Task { await run() }
    }

    public func restart() {
        resetCrashBudget()
        stopRequested = false
        startTask?.cancel()
        stopInternal()
        startTask = Task { await run() }
    }

    public func stop() {
        stopRequested = true
        startTask?.cancel()
        readySince = nil
        stopInternal()
        setPhase(.stopped)
    }

    public func stopAndWait() async {
        stop()
        await Task.yield()
    }

    // MARK: - 启动（含端口 TOCTOU 重试，最多 3 次）

    private func run() async {
        setPhase(.starting)
        var lastError: Error?

        for attempt in 0..<3 {
            if stopRequested || Task.isCancelled { return }

            do {
                let port: UInt16
                if let fixedPort {
                    port = fixedPort
                } else {
                    port = try await PortAllocator.allocate()
                }

                guard !stopRequested && !Task.isCancelled else { return }
                self.port = port
                try await launchAndWait(port: port)
                return
            } catch {
                lastError = error
                stopInternal()
                LogStore.shared.log(
                    .launcher,
                    "启动尝试 \(attempt + 1)/3 失败: \(error.localizedDescription)"
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        fail("启动失败（3 次尝试均未就绪）: \(lastError?.localizedDescription ?? "未知错误")")
    }

    private func launchAndWait(port: UInt16) async throws {
        processExited = false
        let spec = makeLaunchSpec(port: port)
        LogStore.shared.log(.launcher, spec.redactedDescription)
        _ = try runner.start(spec: spec)
        LogStore.shared.log(.launcher, "DSH 已启动 port=\(port)")

        setPhase(.waitingForReady)
        let ready = await waitForReadyOrExit(port: port)

        if stopRequested || Task.isCancelled { return }
        guard ready else {
            if processExited {
                throw SupervisorError.processExitedEarly(exitCode: exitCode)
            }
            throw SupervisorError.notReady(port: port)
        }

        currentURL = URL(string: "http://127.0.0.1:\(port)/")!
        readySince = Date()
        setPhase(.ready)
        LogStore.shared.log(.health, "DSH READY: \(currentURL!.absoluteString)")
    }

    /// 探测就绪；若进程提前退出则立即返回 false（不等 600s 超时）。
    private func waitForReadyOrExit(port: UInt16) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let deadline = Date().addingTimeInterval(600)

        while Date() < deadline {
            if stopRequested || Task.isCancelled { return false }
            if processExited { return false }
            if await HealthProbe().probe(url: url) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return false
    }

    // MARK: - 启动规格

    private func makeLaunchSpec(port: UInt16) -> LaunchSpec {
        var env = ProcessInfo.processInfo.environment

        if env["npm_config_cache"] == nil {
            env["npm_config_cache"] = AppPaths.supportDirectory
                .appendingPathComponent("npm-cache")
                .path
        }

        if let proxyURL, !proxyURL.isEmpty {
            env["http_proxy"] = proxyURL
            env["https_proxy"] = proxyURL
            env["all_proxy"] = proxyURL
            env["HTTP_PROXY"] = proxyURL
            env["HTTPS_PROXY"] = proxyURL
            env["ALL_PROXY"] = proxyURL
        }

        let command = Self.makeWebCommand(
            port: port,
            packageSpec: packageSpec,
            customCommand: customCommand,
            trustedHosts: trustedHosts
        )

        return LaunchSpec(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", command],
            environment: env
        )
    }

    public static func makeWebCommand(
        port: UInt16,
        packageSpec: String,
        customCommand: String?,
        trustedHosts: [String]
    ) -> String {
        let executable: String

        if let customCommand {
            executable = "exec \(LaunchSpec.shellQuote(customCommand))"
        } else {
            executable = "exec npx --yes -- \(LaunchSpec.shellQuote(packageSpec))"
        }

        let trustedArguments = trustedHosts
            .map { "--trusted-host \(LaunchSpec.shellQuote($0))" }
            .joined(separator: " ")
        let suffix = trustedArguments.isEmpty ? "" : " \(trustedArguments)"

        return "\(executable) web --host 127.0.0.1 --port \(port) --no-open\(suffix)"
    }

    // MARK: - 崩溃自动重启（0s/1s/3s，快速连续崩溃最多 3 次）

    private func handleExit(info: ChildProcessRunner.ExitInfo) async {
        guard !info.wasTerminatedByUs else { return }

        processExited = true
        exitCode = info.exitCode

        let uptime = readySince.map { Date().timeIntervalSince($0) }
        readySince = nil

        LogStore.shared.log(
            .lifecycle,
            "DSH 进程退出 code=\(info.exitCode ?? -1) signal=\(info.signal ?? -1) phase=\(phase.rawValue)"
        )

        // 启动阶段退出由 run() 的 3 次启动重试处理。
        guard phase == .ready || phase == .restarting else { return }

        guard autoRestart else {
            fail("DSH 进程退出（自动重启已关闭）")
            return
        }

        // 只有真正稳定运行过，才重新给一整套崩溃重试预算。
        if let uptime, uptime >= stableRunResetInterval {
            consecutiveRestarts = 0
            restartCount = 0
        }

        guard consecutiveRestarts < 3 else {
            fail("DSH 连续崩溃 \(consecutiveRestarts) 次，停止自动重启")
            return
        }

        let delays = [0, 1, 3]
        let delay = delays[min(consecutiveRestarts, delays.count - 1)]

        consecutiveRestarts += 1
        restartCount = consecutiveRestarts
        setPhase(.restarting)

        LogStore.shared.log(
            .lifecycle,
            "\(delay)s 后自动重启（第 \(consecutiveRestarts)/3 次）"
        )

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }

        guard !stopRequested && !Task.isCancelled else { return }
        stopInternal()
        await run()
    }

    // MARK: - 内部工具

    private func resetCrashBudget() {
        consecutiveRestarts = 0
        restartCount = 0
        readySince = nil
        failureReason = nil
        exitCode = nil
    }

    private func stopInternal() {
        runner.stop(graceSeconds: 3)
        currentURL = nil
    }

    private func fail(_ reason: String) {
        readySince = nil
        failureReason = reason
        setPhase(.failed)
        LogStore.shared.log(.lifecycle, "FAILED: \(reason)")
    }

    private func setPhase(_ p: BackendPhase) {
        phase = p

        let state = BackendState(
            phase: p,
            stageText: stageText(for: p),
            currentURL: currentURL,
            failureReason: failureReason,
            exitCode: exitCode,
            port: port,
            restartCount: restartCount
        )

        Task { @MainActor in
            publisher.publish(state)
        }
    }

    private func stageText(for p: BackendPhase) -> String {
        switch p {
        case .starting:
            return "正在启动 DSH…"
        case .waitingForReady:
            return "正在等待 DSH Web UI 就绪（首次运行可能需要几分钟）…"
        case .restarting:
            return "DSH 已退出，\(restartCount)/3 次自动重启中…"
        case .failed:
            return failureReason ?? "启动失败"
        case .stopping:
            return "正在停止…"
        case .ready:
            return "DSH 运行中"
        case .stopped:
            return ""
        }
    }
}

public enum SupervisorError: Error, LocalizedError {
    case notReady(port: UInt16)
    case processExitedEarly(exitCode: Int32?)

    public var errorDescription: String? {
        switch self {
        case .notReady(let port):
            return "端口 \(port) 上的 DSH 未在 600s 内就绪"
        case .processExitedEarly(let code):
            return "DSH 进程在就绪前退出（exit code \(code ?? -1)）"
        }
    }
}
