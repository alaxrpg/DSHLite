import Foundation

/// DSH 后端监督器——纯套壳。
///
/// 职责（严格按计划，不加额外功能）：
/// 1. 用用户配置（Settings）构造启动命令：packageSpec 来自配置文件，绝不硬编码
/// 2. 默认由 PortAllocator 绑定 127.0.0.1:0 取随机端口；配置 fixedPort 时使用该固定 loopback 端口
///    （固定端口启动失败时重试仍使用同一端口）；TOCTOU 竞争最多重试 3 次
/// 3. HealthProbe 真实 HTTP 探测（300ms 间隔，600s 总超时），不 sleep 硬等
/// 4. 崩溃自动重启：0s/1s/3s 退避，最多 3 次（autoRestart 开关控制）
/// 5. 退出时 killpg 清理进程组（SIGTERM → 3s → SIGKILL）
///
/// 不包含：node 路径发现、capability 探测、PATH 查找、自动代理探测。
/// 使用用户默认 shell（/bin/zsh -lic）启动，PATH/nvm/fnm 由 shell 环境解决。
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
    /// 进程是否已退出（启动阶段用于立即失败，不等 HealthProbe 超时）
    private var processExited = false

    /// - Parameters:
    ///   - packageSpec: npx 包 spec（来自 Settings.packageSpec，如 "@deepseek-ai/dsh"）
    ///   - customCommand: 自定义命令（来自 Settings.customExecutable，nil = 用 npx）
    ///   - proxyURL: 手动配置的代理（来自 Settings.proxyURL，nil = 不注入）
    ///   - trustedHosts: 零信任网关使用的浏览器信任 authority；DSH 仍只监听 loopback
    ///   - fixedPort: 可选的固定 loopback 端口；nil 时由 PortAllocator 分配随机端口
    ///   - autoRestart: 崩溃自动重启开关（来自 Settings.autoRestart）
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
        self.packageSpec = packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "@deepseek-ai/dsh" : packageSpec
        // 不把非法 custom 路径折叠成 nil，否则会静默回退到 npx。AppState 在创建前
        // 会校验 Settings；若其他调用方直接传入非法路径，则让启动显式失败。
        self.customCommand = customCommand
        self.proxyURL = proxyURL
        self.trustedHosts = (try? Settings.normalizedTrustedHosts(trustedHosts)) ?? trustedHosts
        self.fixedPort = fixedPort
        self.autoRestart = autoRestart
        runner.onExit = { [weak self] info in
            Task { [weak self] in await self?.handleExit(info: info) }
        }
        runner.onOutput = { text, isStdout in
            LogStore.shared.log(isStdout ? .stdout : .stderr, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - 生命周期

    public func start() {
        guard phase == .stopped || phase == .failed else { return }
        stopRequested = false
        startTask = Task { await run() }
    }

    public func restart() {
        stopRequested = false
        startTask?.cancel()
        stopInternal()
        startTask = Task { await run() }
    }

    public func stop() {
        stopRequested = true
        startTask?.cancel()
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
                // 固定端口用于零信任网关 upstream；失败重试不得悄悄改用随机端口。
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
                LogStore.shared.log(.launcher, "启动尝试 \(attempt + 1)/3 失败: \(error.localizedDescription)")
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
        restartCount = 0
        consecutiveRestarts = 0
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

    /// 构造启动规格：全部来自配置，不硬编码。
    /// 用用户默认 shell 启动（PATH/nvm/fnm/代理由 shell 环境解决）。
    private func makeLaunchSpec(port: UInt16) -> LaunchSpec {
        var env = ProcessInfo.processInfo.environment
        // npm 缓存：~/.npm 可能含 root-owned 文件（npm 已知 bug）导致 npx 写缓存 EPERM。
        // 若用户环境未指定 npm_config_cache，则指向 App 自己的目录（由 ensureDirectories 创建）。
        if env["npm_config_cache"] == nil {
            env["npm_config_cache"] = AppPaths.supportDirectory.appendingPathComponent("npm-cache").path
        }
        // 代理：仅当用户手动配置时注入（绝不自动探测）
        if let proxyURL, !proxyURL.isEmpty {
            env["http_proxy"] = proxyURL
            env["https_proxy"] = proxyURL
            env["all_proxy"] = proxyURL
            env["HTTP_PROXY"] = proxyURL
            env["HTTPS_PROXY"] = proxyURL
            env["ALL_PROXY"] = proxyURL
        }
        // CLI 参数由计划固定：web --host 127.0.0.1 --port N --no-open
        // 用 exec 前缀：zsh 自身被替换，pid/pgid 不变；否则 zsh -i 的 job control
        // 会把 npx/node 放进独立进程组，killpg(记录的 pgid) 杀不到子进程（退出残留孤儿）
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

    /// 生成公开 CLI 启动命令。每个 trusted host 都是独立、安全引用的参数。
    /// 保持 DSH 绑定在 IPv4 loopback；trusted host 仅告知反代后的浏览器访问 authority。
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
            // `--` 终止 npx 自身的选项解析，确保以 `-` 开头的 package spec
            // 也只会作为一个位置参数传给 npx，不能改写 npx 的执行选项。
            executable = "exec npx --yes -- \(LaunchSpec.shellQuote(packageSpec))"
        }
        let trustedArguments = trustedHosts.map {
            "--trusted-host \(LaunchSpec.shellQuote($0))"
        }.joined(separator: " ")
        let suffix = trustedArguments.isEmpty ? "" : " \(trustedArguments)"
        return "\(executable) web --host 127.0.0.1 --port \(port) --no-open\(suffix)"
    }

    // MARK: - 崩溃自动重启（0s/1s/3s 退避，最多 3 次）

    private func handleExit(info: ChildProcessRunner.ExitInfo) async {
        guard !info.wasTerminatedByUs else { return }
        processExited = true
        exitCode = info.exitCode
        LogStore.shared.log(.lifecycle, "DSH 进程退出 code=\(info.exitCode ?? -1) signal=\(info.signal ?? -1) phase=\(phase.rawValue)")

        // 启动阶段（waitingForReady 前）的退出由 run() 的 3 次重试循环处理
        guard phase == .ready || phase == .restarting else { return }
        guard autoRestart else {
            fail("DSH 进程退出（自动重启已关闭）")
            return
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
        LogStore.shared.log(.lifecycle, "\(delay)s 后自动重启（第 \(consecutiveRestarts)/3 次）")

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
        guard !stopRequested && !Task.isCancelled else { return }
        stopInternal()
        await run()
    }

    // MARK: - 内部工具

    private func stopInternal() {
        runner.stop(graceSeconds: 3)
        currentURL = nil
    }

    private func fail(_ reason: String) {
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
        case .starting: return "正在启动 DSH…"
        case .waitingForReady: return "正在等待 DSH Web UI 就绪（首次运行可能需要几分钟）…"
        case .restarting: return "DSH 已退出，\(restartCount)/3 次自动重启中…"
        case .failed: return failureReason ?? "启动失败"
        case .stopping: return "正在停止…"
        case .ready: return "DSH 运行中"
        case .stopped: return ""
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
