import AppKit
import WebKit
import DSHLiteCore

/// 主视图控制器：根据后端状态切换 Loading / Ready(WebView) / Failed。
final class MainViewController: NSViewController, WKNavigationDelegate {
    private let state: AppState
    private var webView: WKWebView?
    private var loadingView: NSView?
    private var errorView: NSView?
    private var navigationFailureView: NSView?

    /// 最近一次交给 WKWebView 加载的后端地址。
    ///
    /// 这个值只在目标 URL 真正变化时更新；Loading/Failed 仅隐藏 WebView，
    /// 不再把它清空。否则后端状态短暂抖动后回到同一个 URL，会被误判成
    /// “新页面”并再次 load，表现为页面持续刷新。
    private var loadedURL: URL?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)

        // macOS 27 beta 的进程外菜单栏（MenuBarClientCore）在 Swift 并发 job
        // 上下文中提交部分 AppKit/WebKit UI 变更存在崩溃路径，因此继续走经典
        // 主队列派发，不改回 Task { @MainActor }。
        state.addObserver { [weak self] in
            DispatchQueue.main.async {
                self?.refreshFromState()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // WKWebView 在 AppKit 启动上下文中提前创建并隐藏待命，避免 READY 时
        // 从异步回调上下文首次创建 WKWebView。
        setupWebView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshFromState()
    }

    // MARK: - 状态刷新

    private func refreshFromState() {
        switch state.backendState.phase {
        case .ready:
            showWebView(url: state.backendState.currentURL)
        case .failed:
            showError(
                reason: state.backendState.failureReason ?? "未知错误",
                exitCode: state.backendState.exitCode
            )
        default:
            showLoading(stageText: state.backendState.stageText)
        }
    }

    // MARK: - 子视图切换

    private func showLoading(stageText: String) {
        removeErrorView()
        removeNavigationFailureView()
        hideWebView()

        if let loadingView {
            if let label = loadingView.viewWithTag(1001) as? NSTextField {
                label.stringValue = stageText
            }
            return
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)

        let title = NSTextField(labelWithString: "Starting DeepSeek Harness…")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let stage = NSTextField(labelWithString: stageText)
        stage.tag = 1001
        stage.font = .systemFont(ofSize: 13)
        stage.textColor = .secondaryLabelColor
        stage.alignment = .center
        stage.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stage)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 40),
            spinner.heightAnchor.constraint(equalToConstant: 40),
            title.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stage.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stage.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stage.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        loadingView = container
    }

    /// 启动时创建 WebView（隐藏），约束就位；READY 时再上屏加载。
    private func setupWebView() {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.isHidden = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        webView = wv
    }

    private func showWebView(url: URL?) {
        removeErrorView()
        removeNavigationFailureView()
        removeLoadingView()

        guard let url else {
            showLoading(stageText: "等待 URL…")
            return
        }
        guard let webView else { return }

        webView.isHidden = false

        // 只在 endpoint 真正变化时导航。相同 URL 的状态通知只更新 UI，
        // 不触发 load/reload。
        guard loadedURL != url else { return }

        loadedURL = url
        webView.load(URLRequest(url: url))
    }

    private func showError(reason: String, exitCode: Int32?) {
        hideWebView()
        removeLoadingView()
        removeNavigationFailureView()
        if errorView != nil { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let icon = NSTextField(labelWithString: "⚠️")
        icon.font = .systemFont(ofSize: 44)
        icon.alignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)

        let title = NSTextField(labelWithString: "DSH could not be started.")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let reasonLabel = NSTextField(wrappingLabelWithString: reason)
        reasonLabel.font = .systemFont(ofSize: 13)
        reasonLabel.alignment = .center
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reasonLabel)

        var controls: [NSView] = [icon, title, reasonLabel]

        if let exitCode {
            let codeLabel = NSTextField(labelWithString: "Exit code: \(exitCode)")
            codeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            codeLabel.textColor = .secondaryLabelColor
            codeLabel.alignment = .center
            codeLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(codeLabel)
            controls.append(codeLabel)
        }

        let restartButton = NSButton(title: "Restart", target: self, action: #selector(restartPressed))
        restartButton.bezelStyle = .rounded
        restartButton.keyEquivalent = "\r"
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(restartButton)
        controls.append(restartButton)

        let logsButton = NSButton(title: "Show Logs", target: self, action: #selector(logsPressed))
        logsButton.bezelStyle = .rounded
        logsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(logsButton)
        controls.append(logsButton)

        var constraints: [NSLayoutConstraint] = [
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ]

        var previous: NSView = title
        for control in controls.dropFirst(2) {
            constraints.append(control.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 10))
            constraints.append(control.centerXAnchor.constraint(equalTo: container.centerXAnchor))
            constraints.append(control.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20))
            constraints.append(control.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20))
            previous = control
        }
        constraints.append(previous.bottomAnchor.constraint(equalTo: container.bottomAnchor))

        NSLayoutConstraint.activate(constraints)
        errorView = container
    }

    /// 只隐藏 WebView，保留实例、进程池以及已加载 endpoint。
    ///
    /// 后端重新启动到随机端口时 URL 会变化，READY 后自然触发一次新加载；
    /// 相同 URL 的状态抖动不会再次加载页面。
    private func hideWebView() {
        webView?.isHidden = true
    }

    private func removeLoadingView() {
        loadingView?.removeFromSuperview()
        loadingView = nil
    }

    private func removeErrorView() {
        errorView?.removeFromSuperview()
        errorView = nil
    }

    private func showNavigationFailure(_ error: Error) {
        guard navigationFailureView == nil else { return }
        guard let webView else { return }
        webView.isHidden = false

        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay, positioned: .above, relativeTo: webView)

        let title = NSTextField(labelWithString: "网页加载失败")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: error.localizedDescription)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(detail)

        let reload = NSButton(title: "重新加载页面", target: self, action: #selector(reloadPagePressed))
        reload.bezelStyle = .rounded
        reload.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(reload)

        let restart = NSButton(title: "重启 DSH", target: self, action: #selector(restartPressed))
        restart.bezelStyle = .rounded
        restart.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(restart)

        let logs = NSButton(title: "查看日志", target: self, action: #selector(logsPressed))
        logs.bezelStyle = .rounded
        logs.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(logs)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            title.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -55),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            detail.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
            reload.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 18),
            reload.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            restart.topAnchor.constraint(equalTo: reload.bottomAnchor, constant: 8),
            restart.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            logs.topAnchor.constraint(equalTo: restart.bottomAnchor, constant: 8),
            logs.centerXAnchor.constraint(equalTo: overlay.centerXAnchor)
        ])

        navigationFailureView = overlay
    }

    private func removeNavigationFailureView() {
        navigationFailureView?.removeFromSuperview()
        navigationFailureView = nil
    }

    // MARK: - Actions

    @objc private func restartPressed() {
        state.restartBackend()
    }

    @objc private func logsPressed() {
        state.isLogsSheetPresented = true
    }

    @objc private func reloadPagePressed() {
        removeNavigationFailureView()
        webView?.reload()
    }

    // MARK: - WKNavigationDelegate（Navigation Security）

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // 放行 loopback；外部链接交系统浏览器。
        let host = (url.host ?? "")
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showNavigationFailure(error)
    }
}
