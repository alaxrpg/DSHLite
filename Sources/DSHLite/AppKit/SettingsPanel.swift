import AppKit
import DSHLiteCore

/// 设置面板（独立 NSWindow）。
final class SettingsPanel: NSWindowController {
    private static var shared: SettingsPanel?

    private let runtimePicker: NSPopUpButton
    private let packageField: NSTextField
    private let customField: NSTextField
    private let autoRestartCheck: NSButton
    private let keepRunningCheck: NSButton
    private let proxyField: NSTextField
    private let fixedPortField: NSTextField
    private let trustedHostsField: NSTextView
    private var state: AppState?

    private init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 430))

        // Runtime 选择
        let runtimeLabel = NSTextField(labelWithString: "Runtime:")
        runtimeLabel.frame = NSRect(x: 20, y: 390, width: 90, height: 20)
        content.addSubview(runtimeLabel)

        let picker = NSPopUpButton(frame: NSRect(x: 120, y: 386, width: 220, height: 26))
        picker.addItems(withTitles: ["Auto (npx)", "Custom Command"])
        content.addSubview(picker)
        self.runtimePicker = picker

        // Package Spec
        let packageLabel = NSTextField(labelWithString: "Package Spec:")
        packageLabel.frame = NSRect(x: 20, y: 350, width: 90, height: 20)
        content.addSubview(packageLabel)

        let packageField = NSTextField(frame: NSRect(x: 120, y: 346, width: 340, height: 24))
        packageField.placeholderString = "@deepseek-ai/dsh"
        content.addSubview(packageField)
        self.packageField = packageField

        let packageHint = NSTextField(labelWithString: "例如 @deepseek-ai/dsh 或 @deepseek-ai/dsh@0.1.1-rc.2")
        packageHint.font = .systemFont(ofSize: 11)
        packageHint.textColor = .secondaryLabelColor
        packageHint.frame = NSRect(x: 120, y: 324, width: 340, height: 16)
        content.addSubview(packageHint)

        // Custom Executable
        let customLabel = NSTextField(labelWithString: "Executable:")
        customLabel.frame = NSRect(x: 20, y: 350, width: 90, height: 20)
        content.addSubview(customLabel)

        let customField = NSTextField(frame: NSRect(x: 120, y: 346, width: 340, height: 24))
        customField.placeholderString = "/usr/local/bin/dsh"
        content.addSubview(customField)
        self.customField = customField

        let customHint = NSTextField(labelWithString: "自定义命令的绝对路径")
        customHint.font = .systemFont(ofSize: 11)
        customHint.textColor = .secondaryLabelColor
        customHint.frame = NSRect(x: 120, y: 324, width: 340, height: 16)
        content.addSubview(customHint)

        // 固定 loopback 端口（供零信任网关 upstream 使用）
        let fixedPortLabel = NSTextField(labelWithString: "Fixed Port:")
        fixedPortLabel.frame = NSRect(x: 20, y: 296, width: 90, height: 20)
        content.addSubview(fixedPortLabel)

        let fixedPortField = NSTextField(frame: NSRect(x: 120, y: 292, width: 100, height: 24))
        fixedPortField.placeholderString = "留空 = 随机"
        content.addSubview(fixedPortField)
        self.fixedPortField = fixedPortField

        let fixedPortHint = NSTextField(labelWithString: "1–65535；仅监听 127.0.0.1")
        fixedPortHint.font = .systemFont(ofSize: 11)
        fixedPortHint.textColor = .secondaryLabelColor
        fixedPortHint.frame = NSRect(x: 230, y: 296, width: 230, height: 20)
        content.addSubview(fixedPortHint)

        // 零信任网关反代后的浏览器信任 authority
        let trustedHostsLabel = NSTextField(labelWithString: "Trust Hosts:")
        trustedHostsLabel.frame = NSRect(x: 20, y: 260, width: 90, height: 20)
        content.addSubview(trustedHostsLabel)

        let trustedScroll = NSScrollView(frame: NSRect(x: 120, y: 195, width: 340, height: 58))
        trustedScroll.hasVerticalScroller = true
        trustedScroll.autohidesScrollers = true
        trustedScroll.borderType = .bezelBorder
        let trustedTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        trustedTextView.isRichText = false
        trustedTextView.isAutomaticQuoteSubstitutionEnabled = false
        trustedTextView.font = .systemFont(ofSize: 13)
        trustedTextView.textContainerInset = NSSize(width: 4, height: 4)
        trustedScroll.documentView = trustedTextView
        content.addSubview(trustedScroll)
        self.trustedHostsField = trustedTextView

        let trustedHint = NSTextField(labelWithString: "可填 host 或 host:port，每行或逗号分隔；用于零信任网关反代后的浏览器访问，不提供认证/TLS")
        trustedHint.font = .systemFont(ofSize: 11)
        trustedHint.textColor = .secondaryLabelColor
        trustedHint.frame = NSRect(x: 120, y: 169, width: 340, height: 28)
        trustedHint.lineBreakMode = .byWordWrapping
        trustedHint.maximumNumberOfLines = 2
        content.addSubview(trustedHint)

        // 代理
        let proxyLabel = NSTextField(labelWithString: "Proxy URL:")
        proxyLabel.frame = NSRect(x: 20, y: 140, width: 90, height: 20)
        content.addSubview(proxyLabel)

        let proxyField = NSTextField(frame: NSRect(x: 120, y: 136, width: 340, height: 24))
        proxyField.placeholderString = "http://127.0.0.1:7890（留空 = 继承系统环境）"
        content.addSubview(proxyField)
        self.proxyField = proxyField

        let proxyHint = NSTextField(labelWithString: "Finder 启动的 App 通常无 shell 代理；走代理访问 npm registry 时在此填写")
        proxyHint.font = .systemFont(ofSize: 11)
        proxyHint.textColor = .secondaryLabelColor
        proxyHint.frame = NSRect(x: 120, y: 114, width: 340, height: 16)
        content.addSubview(proxyHint)

        // 开关
        let autoRestart = NSButton(checkboxWithTitle: "崩溃后自动重启", target: nil, action: nil)
        autoRestart.frame = NSRect(x: 120, y: 88, width: 240, height: 20)
        content.addSubview(autoRestart)
        self.autoRestartCheck = autoRestart

        let keepRunning = NSButton(checkboxWithTitle: "关闭窗口后 DSH 后台继续运行", target: nil, action: nil)
        keepRunning.frame = NSRect(x: 120, y: 60, width: 280, height: 20)
        content.addSubview(keepRunning)
        self.keepRunningCheck = keepRunning

        // 按钮
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 270, y: 25, width: 90, height: 30)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 370, y: 25, width: 90, height: 30)
        content.addSubview(saveButton)

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = content
        super.init(window: window)
        window.center()

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        picker.target = self
        picker.action = #selector(runtimeChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(_ state: AppState) {
        let panel: SettingsPanel
        if let existing = shared {
            panel = existing
        } else {
            panel = SettingsPanel()
            shared = panel
        }
        panel.state = state
        panel.loadSettings()
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    private func loadSettings() {
        let s = SettingsStore.shared.settings
        runtimePicker.selectItem(at: s.runtime == "custom" ? 1 : 0)
        packageField.stringValue = s.packageSpec
        customField.stringValue = s.customExecutable ?? ""
        autoRestartCheck.state = s.autoRestart ? .on : .off
        keepRunningCheck.state = s.keepRunningWhenWindowClosed ? .on : .off
        proxyField.stringValue = s.proxyURL ?? ""
        fixedPortField.stringValue = s.fixedPort.map(String.init) ?? ""
        trustedHostsField.string = s.trustedHosts.joined(separator: "\n")
        updateVisibility()
    }

    private func updateVisibility() {
        let isAuto = runtimePicker.indexOfSelectedItem == 0
        packageField.isHidden = !isAuto
        customField.isHidden = isAuto
    }

    @objc private func runtimeChanged() {
        updateVisibility()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    @objc private func savePressed() {
        do {
            let fixedPort = try Settings.parseFixedPort(fixedPortField.stringValue)
            let trustedHosts = try Settings.parseTrustedHosts(trustedHostsField.string)
            try SettingsStore.shared.updateValidated { s in
                s.runtime = runtimePicker.indexOfSelectedItem == 0 ? "auto" : "custom"
                s.packageSpec = packageField.stringValue.isEmpty ? "@deepseek-ai/dsh" : packageField.stringValue
                s.customExecutable = customField.stringValue.isEmpty ? nil : customField.stringValue
                s.autoRestart = autoRestartCheck.state == .on
                s.keepRunningWhenWindowClosed = keepRunningCheck.state == .on
                s.proxyURL = proxyField.stringValue.isEmpty ? nil : proxyField.stringValue
                s.trustedHosts = trustedHosts
                s.fixedPort = fixedPort
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置无效"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "确定")
            alert.runModal()
            // 保存失败时保持面板打开，便于用户修正输入；绝不显示“已保存”。
            return
        }
        // 不静默替换正在运行的 supervisor；由用户明确确认是否立即重启。
        if let state {
            let alert = NSAlert()
            alert.messageText = "设置已保存"
            alert.informativeText = "新的启动设置需要重启 DSH 才会生效。现在重启吗？"
            alert.addButton(withTitle: "现在重启")
            alert.addButton(withTitle: "稍后重启")
            if alert.runModal() == .alertFirstButtonReturn {
                // AppState 内部串行等待旧 supervisor 完全停止后再替换并启动。
                state.restartBackend()
            }
        }
        window?.close()
    }
}
