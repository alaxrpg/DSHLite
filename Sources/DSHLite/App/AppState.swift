import AppKit
import DSHLiteCore

/// 应用级状态：桥接 BackendSupervisor 与 UI。
/// 采用简单观察者模式（无 Combine/SwiftUI 依赖）。
@MainActor
public final class AppState {
    public private(set) var backendState: BackendState = .initial {
        didSet {
            // BackendState 是值类型；完全相同的快照不重复刷新 WebView/菜单栏。
            if oldValue != backendState {
                notifyObservers()
            }
        }
    }

    public private(set) var updateState: DSHUpdateState = .idle {
        didSet {
            if oldValue != updateState {
                notifyObservers()
            }
        }
    }

    public var isLogsSheetPresented = false {
        didSet {
            if isLogsSheetPresented {
                LogsPanel.show(self)
            }
        }
    }

    public var isSettingsSheetPresented = false {
        didSet {
            if isSettingsSheetPresented {
                SettingsPanel.show(self)
            }
        }
    }

    public var isWindowVisible = true

    public let backendPublisher = BackendStatePublisher()
    public var supervisor: BackendSupervisor?

    private var observers: [() -> Void] = []
    private let dshUpdater = DSHUpdater()

    /// 所有后端生命周期操作共用一个串行队列，避免 Cmd+W、重开窗口和设置重启交错。
    private var lifecycleTask: Task<Void, Never>?

    public init() {
        AppStateHolder.shared.state = self

        AppDelegate.terminateHandler = { [weak self] in
            await self?.shutdownBackend()
        }

        backendPublisher.onStateChange = { [weak self] state in
            self?.backendState = state
        }

        dshUpdater.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.updateState = state
            }
        }
    }

    public func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notifyObservers() {
        for observer in observers {
            observer()
        }
    }

    /// 构造 supervisor：所有参数从 Settings 读取。
    @discardableResult
    public func makeSupervisor() -> Bool {
        guard supervisor == nil else { return true }

        let s = SettingsStore.shared.settings

        do {
            try s.validate()
        } catch {
            let reason = error.localizedDescription
            var failedState = backendState
            failedState.phase = .failed
            failedState.stageText = reason
            failedState.currentURL = nil
            failedState.failureReason = reason
            failedState.exitCode = nil
            failedState.port = nil
            backendState = failedState
            LogStore.shared.log(.config, "配置无效，未启动 DSH: \(reason)")
            return false
        }

        supervisor = BackendSupervisor(
            publisher: backendPublisher,
            packageSpec: s.packageSpec,
            customCommand: s.runtime == "custom" ? s.customExecutable : nil,
            proxyURL: s.proxyURL,
            trustedHosts: s.trustedHosts,
            fixedPort: s.fixedPort,
            autoRestart: s.autoRestart
        )

        return true
    }

    public func startBackend() {
        enqueueLifecycle { [weak self] in
            guard let self, let supervisor = self.supervisor else { return }
            await supervisor.start()
        }
    }

    public func restartBackend() {
        enqueueLifecycle { [weak self] in
            guard let self else { return }

            if let supervisor = self.supervisor {
                await supervisor.stopAndWait()
                self.supervisor = nil
            }

            guard self.makeSupervisor(), let supervisor = self.supervisor else { return }
            await supervisor.start()
        }
    }

    public func stopBackend() {
        enqueueLifecycle { [weak self] in
            guard let self, let supervisor = self.supervisor else { return }
            await supervisor.stopAndWait()
        }
    }

    public func shutdownBackend() async {
        let task = enqueueLifecycle { [weak self] in
            guard let self, let supervisor = self.supervisor else { return }
            await supervisor.stopAndWait()
        }

        await task.value
        dshUpdater.stop()
        updateState = .idle
    }

    /// 请求执行一次用户确认后的 npm 全局更新。更新只使用当前配置，不重启 DSH。
    public func startDSHUpdate() throws {
        let settings = SettingsStore.shared.settings

        do {
            try settings.validate()
            _ = try dshUpdater.start(settings: settings)
            updateState = .running
        } catch {
            if let updateError = error as? DSHUpdateError {
                throw updateError
            }
            let wrapped = DSHUpdateError.startFailed(error.localizedDescription)
            throw wrapped
        }
    }

    /// 窗口关闭时由 AppDelegate 调用；停止也进入同一串行生命周期队列。
    public func windowDidClose() {
        isWindowVisible = false

        if !SettingsStore.shared.settings.keepRunningWhenWindowClosed {
            stopBackend()
        }
    }

    /// 窗口重新显示时排入启动操作；BackendSupervisor 会拒绝重复启动。
    public func windowDidReopen() {
        isWindowVisible = true
        startBackend()
    }

    public func openInBrowser() {
        guard let url = backendState.currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func enqueueLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask

        let task = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }

            guard self != nil else { return }
            await operation()
        }

        lifecycleTask = task
        return task
    }
}
