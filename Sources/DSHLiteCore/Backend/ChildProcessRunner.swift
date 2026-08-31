import Foundation

/// 子进程运行器：基于 posix_spawn + POSIX_SPAWN_SETPGROUP。
///
/// 职责：
/// - 以独立进程组启动（DSH Lite → npx → node → DSH 多级进程全部归入同一 PGID）
/// - 捕获 stdout/stderr
/// - 提供 stop()：SIGTERM 进程组 → 最多等 3 秒 → SIGKILL 进程组
/// - 上报退出码与信号
///
/// 绝不允许 killall/pkill，只能 killpg(ownedPGID)。
public final class ChildProcessRunner: @unchecked Sendable {
    public struct ExitInfo: Sendable {
        public let pid: pid_t
        public let exitCode: Int32?
        public let signal: Int32?
        public let wasTerminatedByUs: Bool
    }

    public enum State: Sendable {
        case idle
        case running(pid: pid_t, pgid: pid_t)
        case exited(ExitInfo)
    }

    private let lock = NSLock()
    private var _state: State = .idle
    /// 我们是否主动终止（避免把正常退出误判为崩溃）
    private var terminating = false

    /// 输出回调（stdout/stderr 行）
    public var onOutput: ((String, Bool) -> Void)? // (text, isStdout)
    /// 退出回调（在主队列回调）
    public var onExit: ((ExitInfo) -> Void)?

    public init() {}

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// 启动进程。
    /// 允许从 .exited / .idle 状态启动（重试循环会复用 runner）。
    public func start(spec: LaunchSpec) throws -> pid_t {
        lock.lock()
        switch _state {
        case .running:
            lock.unlock()
            throw ChildProcessError.alreadyRunning
        case .idle, .exited:
            break // 可启动
        }
        lock.unlock()

        let argv = [spec.executable.path] + spec.arguments
        let cargs = argv.map { strdup($0) } + [nil]

        let env: [String: String] = spec.environment
        let cenv = env.map { key, value in
            strdup("\(key)=\(value)")
        } + [nil]

        defer {
            for ptr in cargs { free(ptr) }
            for ptr in cenv { free(ptr) }
        }

        // 输出管道
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw ChildProcessError.pipeCreationFailed
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // 子进程侧：stdout/stderr 接管道
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // 新进程组：POSIX_SPAWN_SETPGROUP + pgroup=0 => 子进程成为新进程组组长
        var flags: Int16 = 0
        posix_spawnattr_getflags(&attr, &flags)
        flags |= Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        // 清掉 SIGINT/SIGQUIT 继承（避免终端信号干扰）
        var sigDefault = sigaction()
        sigDefault.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(SIGINT, &sigDefault, nil)
        sigaction(SIGQUIT, &sigDefault, nil)

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, cargs[0], &fileActions, &attr, cargs, cenv)

        guard spawnResult == 0 else {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            throw ChildProcessError.spawnFailed(errno: spawnResult)
        }

        // 父进程侧：关闭写端，读取读端
        close(outPipe[1])
        close(errPipe[1])
        let outRead = outPipe[0]
        let errRead = errPipe[0]

        lock.lock()
        _state = .running(pid: pid, pgid: pid)
        terminating = false
        lock.unlock()

        // 读取线程
        let runner = self
        DispatchQueue.global(qos: .utility).async {
            runner.readLoop(readFD: outRead, isStdout: true)
        }
        DispatchQueue.global(qos: .utility).async {
            runner.readLoop(readFD: errRead, isStdout: false)
        }

        // 监控线程：waitpid
        DispatchQueue.global(qos: .utility).async {
            runner.waitLoop(pid: pid)
        }

        return pid
    }

    // MARK: - 输出读取

    private func readLoop(readFD: Int32, isStdout: Bool) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var partial = Data()
        while true {
            let n = read(readFD, &buffer, buffer.count)
            if n <= 0 { break }
            partial.append(contentsOf: buffer[0..<n])
            // 按行输出
            while let newlineIndex = partial.firstIndex(of: 0x0A) {
                let lineData = partial.prefix(upTo: newlineIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    onOutput?(line, isStdout)
                }
                partial.removeSubrange(...newlineIndex)
            }
        }
        // 残余
        if !partial.isEmpty, let line = String(data: partial, encoding: .utf8) {
            onOutput?(line, isStdout)
        }
        close(readFD)
    }

    private func waitLoop(pid: pid_t) {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let exitCode: Int32?
        let signal: Int32?
        if (status & 0x7F) == 0 {
            // 正常退出：低 8 位为退出码
            exitCode = (status >> 8) & 0xFF
            signal = nil
        } else {
            // 信号终止
            exitCode = nil
            signal = status & 0x7F
        }
        let wasTerminated = lock.withLock {
            let was = terminating
            terminating = false
            _state = .exited(ExitInfo(pid: pid, exitCode: exitCode, signal: signal, wasTerminatedByUs: was))
            return was
        }
        let info = ExitInfo(pid: pid, exitCode: exitCode, signal: signal, wasTerminatedByUs: wasTerminated)
        DispatchQueue.main.async {
            self.onExit?(info)
        }
    }

    // MARK: - 停止

    /// 停止进程组：SIGTERM → 最多 3 秒 → SIGKILL。
    /// 返回时保证进程已被 reap（状态为 .exited/.idle），可立即重新 start。
    public func stop(graceSeconds: TimeInterval = 3) {
        lock.lock()
        guard case .running(let pid, _) = _state else {
            lock.unlock()
            return
        }
        terminating = true
        lock.unlock()

        let pgid = pid // 新进程组组长 pid == pgid
        killpg(pgid, SIGTERM)

        // 等待最多 graceSeconds（waitLoop 会 reap 并更新状态）
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if isExitedOrIdle() { return }
            usleep(50_000)
        }
        // 仍然存在 => SIGKILL
        killpg(pgid, SIGKILL)

        // SIGKILL 后继续等待 reap（最多再 2 秒）
        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline {
            if isExitedOrIdle() { return }
            usleep(50_000)
        }
    }

    private func isExitedOrIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .exited, .idle: return true
        case .running: return false
        }
    }

    /// 立即强制终止（不等待）。
    public func killNow() {
        lock.lock()
        guard case .running(let pid, _) = _state else {
            lock.unlock()
            return
        }
        terminating = true
        lock.unlock()
        killpg(pid, SIGKILL)
    }
}

public enum ChildProcessError: Error, LocalizedError {
    case alreadyRunning
    case pipeCreationFailed
    case spawnFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "进程已在运行"
        case .pipeCreationFailed:
            return "创建管道失败"
        case .spawnFailed(let code):
            return String(cString: strerror(code))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
