import Foundation
import DSHLiteCore

// 端到端测试：真实启动 DSH（隔离 DSH_HOME，不碰用户 ~/.dsh）。
// 用与 App 完全相同的路径：BackendSupervisor(配置参数) → zsh -lic npx → DSH → ready。
@main
enum E2ETest {
    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    static func main() async {
        log("=== E2E: 启动真实 DSH ===")
        // 安全隔离：临时 DSH_HOME + 复用用户 profiles/web 的配置与依赖（只读）。
        // 目的：不干扰用户正在运行的 DSH 实例，也不修改任何 ~/.dsh 文件。
        let userWeb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/web", isDirectory: true)
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshlite-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let isolatedWeb = isolatedHome.appendingPathComponent("profiles/web", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedWeb, withIntermediateDirectories: true)
        // 复制配置文件（不含 node_modules），node_modules 软链只读共享
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: userWeb, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name == "node_modules" {
                    try? fm.createSymbolicLink(at: isolatedWeb.appendingPathComponent(name),
                                               withDestinationURL: userWeb.appendingPathComponent(name))
                } else {
                    try? fm.copyItem(at: entry, to: isolatedWeb.appendingPathComponent(name))
                }
            }
        }
        setenv("DSH_HOME", isolatedHome.path, 1)
        log("隔离 DSH_HOME: \(isolatedHome.path)")

        // 代理：走环境（测试在 shell 中运行，已有 http_proxy）
        let publisher = BackendStatePublisher()
        var lastPhase: BackendPhase = .stopped
        publisher.onStateChange = { state in
            if state.phase != lastPhase {
                lastPhase = state.phase
                log("状态: \(state.phase.rawValue) — \(state.stageText)")
            }
            if let url = state.currentURL {
                log("URL: \(url.absoluteString)")
            }
        }

        // 与 App 完全相同的构造路径（配置参数）
        let supervisor = BackendSupervisor(
            publisher: publisher,
            packageSpec: "@deepseek-ai/dsh",
            customCommand: nil,
            proxyURL: nil,
            autoRestart: false
        )

        await supervisor.start()

        // 等最多 600s（首次 npx 全量下载 + DSH boot 可能需要数分钟）
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            if await supervisor.phase == .ready {
                log("=== READY ===")
                // 验证 HTTP 可访问
                let url = await supervisor.currentURL!
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                if let (data, resp) = try? await URLSession.shared.data(for: request),
                   let http = resp as? HTTPURLResponse {
                    log("HTTP \(http.statusCode), body \(data.count) bytes")
                    log("=== E2E 通过 ===")
                    await supervisor.stop()
                    exit(0)
                }
            }
            if await supervisor.phase == .failed {
                log("=== FAILED: \(await supervisor.failureReason ?? "?") ===")
                await supervisor.stop()
                exit(1)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("=== 超时 ===")
        await supervisor.stop()
        exit(1)
    }
}
