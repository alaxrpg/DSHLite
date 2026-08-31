import AppKit
import DSHLiteCore

/// DSH Lite 应用入口（AppKit 版，无 SwiftUI 宏依赖）。
@main
public enum DSHLiteMain {
    public static func main() {
        try? AppPaths.ensureDirectories()
        _ = LogStore.shared

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// App 委托：管理窗口、菜单栏、生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var terminateHandler: (@MainActor () async -> Void)?

    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusTitleItem: NSMenuItem?
    private var mainUpdateItem: NSMenuItem?
    private var statusUpdateItem: NSMenuItem?
    private var mainViewController: MainViewController?
    private var appState: AppState?
    private var presentedUpdateState: DSHUpdateState?
    /// 退出流程已开始：此后禁止一切状态栏/菜单更新（避免 teardown 期间 MenuBarClientCore use-after-free 崩溃）
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        appState = state

        // 主窗口
        let contentVC = MainViewController(state: state)
        mainViewController = contentVC
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSH Lite"
        window.contentViewController = contentVC
        window.center()
        window.setFrameAutosaveName("DSHLiteMainWindow")
        window.delegate = self
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar(state: state)
        setupStatusItem(state: state)
        SettingsStore.shared.onChange = { [weak self, weak state] _ in
            DispatchQueue.main.async {
                guard let self, let state, !self.isTerminating else { return }
                self.updateUpdateMenuItems(state: state)
            }
        }

        // 启动后端
        state.makeSupervisor()
        state.startBackend()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出流程开始：立刻拆除状态栏并冻结 UI 更新，防止异步 stopBackend 期间
        // observer 继续更新 statusItem/NSMenuItem 导致 MenuBarClientCore 崩溃
        isTerminating = true
        teardownStatusItem()
        guard let handler = Self.terminateHandler else {
            return .terminateNow
        }
        Task { @MainActor in
            await handler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock 点击恢复窗口
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            appState?.windowDidReopen()
        }
        return true
    }

    /// Cmd+W 关闭窗口：DSH 后台继续运行（隐藏窗口而不是销毁）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        appState?.windowDidClose()
        return false
    }

    // MARK: - 菜单栏

    private func setupMenuBar(state: AppState) {
        let mainMenu = NSMenu()

        // App 菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DSH Lite", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide DSH Lite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DSH Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File 菜单
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Show DSH", action: #selector(showMainWindow), keyEquivalent: "0")
        fileMenu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "b")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // DSH 菜单
        let dshMenuItem = NSMenuItem()
        mainMenu.addItem(dshMenuItem)
        let dshMenu = NSMenu(title: "DSH")
        dshMenu.addItem(withTitle: "Restart DSH", action: #selector(restartDSH), keyEquivalent: "r")
        dshMenu.addItem(withTitle: "Stop DSH", action: #selector(stopDSH), keyEquivalent: "")
        let mainUpdate = dshMenu.addItem(withTitle: "Update DSH…", action: #selector(updateDSH), keyEquivalent: "")
        mainUpdateItem = mainUpdate
        dshMenuItem.submenu = dshMenu

        // View 菜单
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        viewMenuItem.submenu = viewMenu

        // Window 菜单
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 状态栏

    private func setupStatusItem(state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        updateStatusIcon(state.backendState.phase)

        let menu = NSMenu()
        let statusTitle = NSMenuItem(title: "DSH Status: Starting…", action: nil, keyEquivalent: "")
        statusTitle.isEnabled = false
        menu.addItem(statusTitle)
        statusTitleItem = statusTitle
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Show DSH", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Restart DSH", action: #selector(restartDSH), keyEquivalent: "")
        menu.addItem(withTitle: "Stop DSH", action: #selector(stopDSH), keyEquivalent: "")
        let statusUpdate = menu.addItem(withTitle: "Update DSH…", action: #selector(updateDSH), keyEquivalent: "")
        statusUpdateItem = statusUpdate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Logs…", action: #selector(showLogs), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        // 状态实时更新（退出后冻结）。
        // [修复] 用经典 AppKit 主队列派发代替 Swift 并发 Task job：
        // macOS 27 beta 上从 Task{@MainActor} 上下文更新菜单栏相关对象会触发
        // MenuBarClientCore 内部 use-after-free（executor 野指针 SIGSEGV）。
        state.addObserver { [weak self, weak state] in
            DispatchQueue.main.async {
                guard let self, let state, !self.isTerminating, self.statusItem != nil else { return }
                let phase = state.backendState.phase
                self.updateStatusIcon(phase)
                self.statusTitleItem?.title = self.statusText(for: phase, updateState: state.updateState)
                self.updateUpdateMenuItems(state: state)
            }
        }
        updateUpdateMenuItems(state: state)
    }

    /// 退出时显式拆除状态栏，避免系统 teardown 与后续更新竞争
    private func teardownStatusItem() {
        guard let item = statusItem else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func updateStatusIcon(_ phase: BackendPhase) {
        guard !isTerminating, statusItem != nil else { return }
        let symbol: String
        switch phase {
        case .ready: symbol = "checkmark.circle.fill"
        case .failed: symbol = "xmark.octagon.fill"
        case .stopped: symbol = "circle"
        default: symbol = "arrow.triangle.2.circlepath"
        }
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DSH Lite")
        }
    }

    private func statusText(for phase: BackendPhase, updateState: DSHUpdateState = .idle) -> String {
        if updateState == .running {
            return "DSH Status: Updating DSH…"
        }
        switch phase {
        case .stopped: return "DSH Status: Stopped"
        case .starting: return "DSH Status: Starting…"
        case .waitingForReady: return "DSH Status: Waiting for Web UI…"
        case .ready: return "DSH Status: Running"
        case .stopping: return "DSH Status: Stopping…"
        case .failed: return "DSH Status: Failed"
        case .restarting: return "DSH Status: Restarting…"
        }
    }

    // MARK: - Actions

    @objc private func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appState?.windowDidReopen()
    }

    @objc private func openInBrowser() {
        appState?.openInBrowser()
    }

    @objc private func closeWindow() {
        mainWindow?.performClose(nil)
    }

    @objc private func restartDSH() {
        appState?.restartBackend()
    }

    @objc private func stopDSH() {
        appState?.stopBackend()
    }

    @objc private func updateDSH() {
        guard let state = appState,
              SettingsStore.shared.settings.runtime == "auto",
              state.updateState != .running else { return }

        let alert = NSAlert()
        alert.messageText = "更新 DSH？"
        alert.informativeText = "将执行 npm install -g -- \(SettingsStore.shared.settings.packageSpec)，更新全局 DSH 包。此操作会修改本机 npm 环境，完成后不会自动重启 DSH。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try state.startDSHUpdate()
        } catch {
            showUpdateFailure(error.localizedDescription, offerLogs: false)
        }
    }

    private func updateUpdateMenuItems(state: AppState) {
        let isCustom = SettingsStore.shared.settings.runtime != "auto"
        let isRunning = state.updateState == .running
        let title = isCustom ? "Update DSH (Not available)" : (isRunning ? "Updating DSH…" : "Update DSH…")
        for item in [mainUpdateItem, statusUpdateItem] {
            item?.title = title
            item?.isEnabled = !isCustom && !isRunning && !isTerminating
        }
        if presentedUpdateState != state.updateState {
            presentedUpdateState = state.updateState
            if case .succeeded = state.updateState {
                showUpdateSuccess()
            } else if case .failed(_, let reason) = state.updateState {
                showUpdateFailure(reason, offerLogs: true)
            }
        }
    }

    private func showUpdateSuccess() {
        let alert = NSAlert()
        alert.messageText = "DSH 更新完成"
        alert.informativeText = "全局 DSH 包已更新。当前运行中的 DSH 不会自动重启。"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    private func showUpdateFailure(_ message: String, offerLogs: Bool) {
        let alert = NSAlert()
        alert.messageText = "DSH 更新失败"
        alert.informativeText = message
        if offerLogs {
            alert.addButton(withTitle: "查看日志")
            alert.addButton(withTitle: "确定")
        } else {
            alert.addButton(withTitle: "确定")
        }
        let response = alert.runModal()
        if offerLogs && response == .alertFirstButtonReturn {
            showLogs()
        }
    }

    @objc private func showLogs() {
        appState?.isLogsSheetPresented = true
    }

    @objc private func showSettings() {
        appState?.isSettingsSheetPresented = true
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DSH Lite"
        alert.informativeText = "DSH Web Runtime Supervisor + System WebView Shell\n\nDSH Lite 与 DeepSeek Harness 是两个独立软件。"
        alert.runModal()
    }
}
