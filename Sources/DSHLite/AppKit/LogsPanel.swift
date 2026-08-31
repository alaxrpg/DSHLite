import AppKit
import DSHLiteCore

/// 日志面板（独立 NSWindow）。
final class LogsPanel: NSWindowController {
    private static var shared: LogsPanel?

    private let textView: NSTextView
    private let copyAllButton: NSButton
    private var timer: Timer?

    private init() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        self.textView = textView

        let copyAllButton = NSButton(title: "复制全部", target: nil, action: nil)
        copyAllButton.bezelStyle = .rounded
        copyAllButton.setButtonType(.momentaryPushIn)
        self.copyAllButton = copyAllButton

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 4, right: 8)
        toolbar.addView(NSView(), in: .leading)
        toolbar.addView(copyAllButton, in: .trailing)

        let root = NSStackView(views: [toolbar, scrollView])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSH Lite Logs"
        window.contentView = root
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        super.init(window: window)
        copyAllButton.target = self
        copyAllButton.action = #selector(copyAllLogs)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(_ state: AppState) {
        let panel: LogsPanel
        if let existing = shared {
            panel = existing
        } else {
            panel = LogsPanel()
            shared = panel
            // 日志目录提示
            panel.appendLine("日志目录: \(AppPaths.logsDirectory.path)\n")
        }
        panel.reload()
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.makeFirstResponder(panel.textView)
        // 定时刷新（2 秒）。reload 会避免无变化时重写 NSTextView，防止选区被重置。
        panel.timer?.invalidate()
        panel.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                panel.reload()
            }
        }
    }

    func reload() {
        let content = LogStore.shared.recentLines(limit: 500).joined()
        guard content != textView.string else { return }

        let oldLength = (textView.string as NSString).length
        let selectedRange = textView.selectedRange()
        let wasFollowingTail = selectedRange.length == 0 && selectedRange.location >= oldLength

        textView.string = content

        let newLength = (content as NSString).length
        let restoredLocation = min(selectedRange.location, newLength)
        let restoredLength = min(selectedRange.length, max(0, newLength - restoredLocation))
        textView.setSelectedRange(NSRange(location: restoredLocation, length: restoredLength))

        if wasFollowingTail {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func copyAllLogs() {
        let content = textView.string
        guard !content.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    private func appendLine(_ line: String) {
        textView.string += line
    }
}

extension LogsPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
