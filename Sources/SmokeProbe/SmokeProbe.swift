import Foundation
import DSHLiteCore

// 核心冒烟测试：验证 PortAllocator / HealthProbe / SettingsStore / 进程清理。
// 不依赖任何已删除的探测/发现抽象——按计划只测核心套壳能力。
@main
enum SmokeProbe {
    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    static func main() async {
        log("=== DSH Lite Core Smoke ===")
        var passed = 0
        var failed = 0

        // 1. PortAllocator：应返回 loopback 随机端口
        do {
            let port = try await PortAllocator.allocate()
            log("port allocator: \(port) (127.0.0.1)")
            if port > 0 && port < UInt16.max { passed += 1 } else { failed += 1; log("  ✗ 端口非法") }
        } catch {
            failed += 1
            log("port allocator FAILED: \(error)")
        }

        // 2. ServerAddressDetector：loopback URL 正则
        do {
            let url = ServerAddressDetector.detectURL(in: "dsh web: http://127.0.0.1:41723 ready")
            log("address detector: \(url?.absoluteString ?? "nil")")
            if url?.host == "127.0.0.1" { passed += 1 } else { failed += 1; log("  ✗ 未识别 loopback URL") }
            // 必须拒绝外部 URL
            let bad = ServerAddressDetector.detectURL(in: "http://example.com:80/x")
            if bad == nil { passed += 1 } else { failed += 1; log("  ✗ 接受了非 loopback URL") }
        }

        // 3. SettingsStore：默认值 + 写入/读取 + 代理字段
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dshlite-smoke-\(UUID().uuidString.prefix(8))")
            let store = SettingsStore(url: dir.appendingPathComponent("config.json"))
            store.update { s in
                s.proxyURL = "http://127.0.0.1:7890"
                s.packageSpec = "@deepseek-ai/dsh"
            }
            let reloaded = SettingsStore(url: dir.appendingPathComponent("config.json"))
            log("settings: proxy=\(reloaded.settings.proxyURL ?? "nil") spec=\(reloaded.settings.packageSpec)")
            if reloaded.settings.proxyURL == "http://127.0.0.1:7890" { passed += 1 } else { failed += 1; log("  ✗ 配置读写失败") }
        }

        // 4. ChildProcessRunner 进程组清理：启动 sleep 进程，stop() 后必须消失
        do {
            let runner = ChildProcessRunner()
            let spec = LaunchSpec(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                environment: ProcessInfo.processInfo.environment
            )
            let pid: pid_t
            do {
                pid = try runner.start(spec: spec)
            } catch {
                failed += 1
                log("runner start FAILED: \(error)")
                log("=== 结果: \(passed) 通过, \(failed) 失败 ===")
                exit(1)
            }
            log("runner: started pid=\(pid)")
            // 确认存活
            if kill(pid, 0) == 0 { passed += 1 } else { failed += 1; log("  ✗ 进程未存活") }
            runner.stop(graceSeconds: 1)
            // 确认已被 reap
            let state = runner.state
            if case .exited = state { passed += 1 } else { failed += 1; log("  ✗ 进程未清理: \(state)") }
            log("runner: cleaned up")
        }

        log("=== 结果: \(passed) 通过, \(failed) 失败 ===")
        exit(failed == 0 ? 0 : 1)
    }
}
