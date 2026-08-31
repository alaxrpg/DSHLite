import AppKit
import DSHLiteCore

/// 日志面板（独立 NSWindow）。
final class LogsPanel: NSWindowController {
    private static var shared: LogsPanel?

    private let textView: NSTextView
    private var timer: Timer?

    private init() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSH Lite Logs"
        window.contentView = scrollView
        super.init(window: window)
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
        // 定时刷新（2 秒）
        panel.timer?.invalidate()
        panel.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                panel.reload()
            }
        }
    }

    func reload() {
        let lines = LogStore.shared.recentLines(limit: 500)
        textView.string = lines.joined()
        textView.scrollToEndOfDocument(nil)
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
