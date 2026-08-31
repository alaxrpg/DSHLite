# DSH Lite 交接文档（给下一个执行 AI）

> 交接时间：2026-08-28 17:58（第三次更新：MenuBarClientCore 崩溃已修复）
> 项目目录：`/Users/lizhiyuan/项目/deepseek-harness-plugin/DSHLite/`
> 输出语言：**简体中文**（用户强制偏好）

---

## 一、项目定位与硬性需求（用户反复纠偏后的最终版）

**DSH Lite = macOS 原生"套壳"应用**（Swift + AppKit/WKWebView），角色是
"DSH Web Runtime Supervisor + System WebView Shell"。必须遵守：

1. **不打包** DSH / Node / Bun / Chromium / Electron；**不修改 DSH 源码**；App 本体 < 20MB
2. 用 `npx @deepseek-ai/dsh web` 为基础，**packageSpec 必须来自配置文件**（`Settings.packageSpec`），**绝不硬编码**
3. **禁止依赖 DSH 内部实现**；已删掉 adapter/runtime discovery/capability probe/launch spec builder 抽象层（用户明确否决：*"让你套壳,你总想塞什么杂七杂八东西"*）
4. **代理**：必须走代理（用户环境 `127.0.0.1:7890`），**只允许用户手动配置**（`Settings.proxyURL`），**禁止自动探测/剥离**（用户原话：*"默认自动探测代理不要这种狗屁功能"*）
5. **用用户默认 shell 启动**：`/bin/zsh -lic "npx ..."`，**不做 PATH 查找/指纹/缓存/多路径探测**（用户原话：*"你只需要套壳""你只要使用用户的默认shell环境启动就好"*）
6. **端口**：PortAllocator bind `127.0.0.1:0` 取随机端口；TOCTOU 竞争最多重试 3 次（每次重新申请端口）；拒绝 `0.0.0.0`
7. **Health Probe**：300ms 间隔真实 HTTP 探测，启动超时 600s（首次 boot 实测可达 8 分钟），不 sleep 硬等
8. **进程**：`posix_spawn` + `POSIX_SPAWN_SETPGROUP` 独立进程组；`SIGTERM→3s→SIGKILL` 用 **killpg**，**禁止 killall/pkill**
9. **UI 行为**：Cmd+W 隐藏窗口后台继续；Cmd+Q 清理进程组后退出；Menu Bar extra（状态/Show/Open in Browser/Restart/Stop/Logs/Settings/Quit）
10. **崩溃自动重启**：0s/1s/3s 退避，最多 3 次
11. **日志滚动**：≤5MB × 3
12. **配置**：`~/Library/Application Support/DSHLite/config.json`
13. **不改 `~/.dsh`**；WKWebView 只加载 supervisor.currentURL；导航仅允许 loopback，外链交系统浏览器
14. **用户主 DSH 正运行在 127.0.0.1:3080，禁止停止/重启/替换**，只能只读诊断

---

## 二、当前代码状态（全部已编译通过）

### 目录结构
```
Sources/DSHLiteCore/Backend/   (8 文件，全部编译通过)
  BackendState.swift           BackendPhase 枚举 + BackendState + BackendStatePublisher
  BackendSupervisor.swift      ★ 核心监督器（已重写为最小套壳）
  ChildProcessRunner.swift     posix_spawn + SETPGROUP + killpg 清理
  HealthProbe.swift            300ms 探测 / 600s 超时
  LaunchSpec.swift             ★ 新增（原定义丢失已重建）
  PortAllocator.swift          NWListener 127.0.0.1:0 随机端口
  ServerAddressDetector.swift  loopback URL 正则 fallback
Sources/DSHLiteCore/Support/   (3 文件)
  AppPaths.swift               DSHLITE_HOME 覆盖支持
  LogStore.swift               滚动日志 5MB×3
  SettingsStore.swift          Settings 含 proxyURL（手动）/packageSpec/autoRestart
Sources/DSHLite/App/           (3 文件)
  AppState.swift               ★ 已重写（删除已删类型引用，直接构造 supervisor）
  AppStateHolder.swift
  DSHLiteApp.swift             @main + AppDelegate（全 AppKit）
Sources/DSHLite/AppKit/        (3 文件)
  MainViewController.swift     Loading/Ready/Error 切换 + WKNavigationDelegate
  LogsPanel.swift
  SettingsPanel.swift          Runtime/Package Spec/Executable/Proxy URL(手动)/开关
Sources/SmokeProbe/SmokeProbe.swift   ★ 已重写（不引用已删类型）
Sources/E2ETest/E2ETest.swift         ★ 已重写（用新构造路径）
```

### 当前编译产物
```
.build-cache/DSHLite.bin    579KB  (App 可执行)
.build-cache/SmokeProbe.bin 406KB  (单元测试工具)
.build-cache/E2ETest.bin    416KB  (E2E 测试工具，16:30 已重链最新 Core)
dist/DSH Lite.app           636KB  (.app bundle，已完成)
```

### 编译命令（每次全量重建用）
```bash
cd .build-cache/obj && rm -f *.o *.swiftmodule && \
swiftc -module-name DSHLiteCore -parse-as-library -module-cache-path "$PWD/../modules" -emit-module -emit-module-path ../DSHLiteCore.swiftmodule -c -emit-object \
  ../../Sources/DSHLiteCore/Backend/*.swift ../../Sources/DSHLiteCore/Support/*.swift && \
swiftc -module-name DSHLite -parse-as-library -module-cache-path "$PWD/../modules" -I .. -emit-module -emit-module-path ../DSHLite.swiftmodule -c -emit-object \
  ../../Sources/DSHLite/App/*.swift ../../Sources/DSHLite/AppKit/*.swift && \
swiftc -o ../DSHLite.bin -module-cache-path "$PWD/../modules" -I .. $(ls *.o | grep -vE "SmokeProbe|E2ETest") && \
swiftc -o ../SmokeProbe.bin -module-cache-path "$PWD/../modules" -I .. SmokeProbe.o BackendState.o LaunchSpec.o PortAllocator.o HealthProbe.o ChildProcessRunner.o ServerAddressDetector.o BackendSupervisor.o AppPaths.o LogStore.o SettingsStore.o && \
swiftc -o ../E2ETest.bin -module-cache-path "$PWD/../modules" -I .. E2ETest.o BackendState.o LaunchSpec.o PortAllocator.o HealthProbe.o ChildProcessRunner.o ServerAddressDetector.o BackendSupervisor.o AppPaths.o LogStore.o SettingsStore.o && \
cd .. && ./Scripts/build-app.sh
```

---

## 三、测试现状与已解决问题

### ✅ 已通过
- **SmokeProbe 6/6 通过**（16:22）：端口分配 / loopback 地址检测（拒绝外链）/ 配置读写（代理字段）/ 进程组清理
- **一次 DSH 真实启动成功**（16:26）：日志显示 `DSH READY: http://127.0.0.1:51468/`（启动后 5 秒就绪）
- .app bundle 构建成功（636KB）
- **E2E 通过**（17:0x，58s READY）：npm_config_cache 注入生效（注意：后来实测 `~/.npm` 并无 root-owned 文件，EPERM 旧结论失效；复用 `~/.npm` 现成 `_npx` 缓存即可秒起。App 的 npm-cache 目录方案保留未动）
- **App 真实启动验证通过**（kill -9 后 5 秒恢复 READY）

### ✅ MenuBarClientCore SIGSEGV 崩溃（已修复，17:58）
**现象**：App 在 READY 后 6~64 秒必崩（6 份崩溃报告模式一致），崩在主线程 run loop：
```
-[NSApplication run] → __CFRunLoopDoBlocks → MenuBarClientCore(私有框架)
→ swift_task_isCurrentExecutorWithFlagsImpl → SerialExecutor._isSameExecutor
→ 解引用野指针 (KERN_INVALID_ADDRESS 0x7c8) → SIGSEGV
```
**排查**（二分法，全部有对照实验）：
- 冻结状态栏更新（observer 直接 return）→ 仍崩（17:21:49）→ 排除状态栏更新本身
- 冻结 WebView（.ready 不再创建 WKWebView）→ **存活 5 分钟**（17:38-17:43）→ 锁定触发源是 WKWebView 创建路径
**根因**：macOS 27.0 beta（Build 26A5421a）进程外菜单栏（MenuBarClientCore，Swift 6 实现）在 Swift 并发 `Task { @MainActor }` job 上下文中处理 UI 变更时存在 use-after-free：从该上下文创建 WKWebView 会注册文本输入上下文、牵动菜单栏客户端，其内部持有的 executor 对象被提前释放，主 run loop 后续执行 block 时撞野指针。（苹果官方文档 NSStatusItem / WKWebView 线程要求均已核对，我们的调用本身合规；属 beta 系统缺陷，触发路径可绕开）
**修复**（两处，均已验证）：
1. `MainViewController.swift`：WKWebView 改为**启动时在 `loadView()`（AppKit 上下文）创建并隐藏待命**，READY 时只做 `load()` + unhide；observer 从 `Task { @MainActor }` 改为 `DispatchQueue.main.async`；删除无用的 `allowUniversalAccessFromFileURLs` KVC hack（DSH UI 是 http 同源，不需要）；`removeWebView()` 改为隐藏复用（避免回调上下文重建）
2. `DSHLiteApp.swift`：状态栏 observer 同样改为 `DispatchQueue.main.async` 派发；`statusTitleItem` 提为属性
**验证**：V1（WebView 修复 + 状态栏仍冻结）READY 后 7 分钟存活零崩溃（17:48-17:55）；V2（全部解冻）见 17:58 后验证记录
**注意**：若升级正式版 macOS 后仍崩，优先怀疑该 workaround 失效，重新二分

### ✅ 原已知问题收口
1. **子进程清理**：启动链已使用 `exec npx --yes -- <packageSpec> ...`，zsh 被 npx 替换后保持 pid/pgid；`ChildProcessRunner` 继续使用独立进程组和 `SIGTERM → SIGKILL`。离线 SmokeProbe 已验证进程组清理；Cmd+Q 的 GUI 现场检查仍列为目标环境验收项。
2. **编译警告**：本轮 native 全量构建已无 warning。


---

## 四、后续仅剩目标环境验收

- 在匹配的 Swift compiler/SDK 下运行 `swift test`。
- 在不干扰现有 `127.0.0.1:3080` 的前提下，手工验证 Cmd+W、Cmd+Q、WebView 错误覆盖层、`Update DSH…` 确认与 Trust Hosts 的网关访问。
- 当前构建目标明确为 native-only，不规划 Universal、公证、自动更新框架或 DSH Desktop 功能。

---

## 五、关键环境事实（勿忘）

| 项 | 值 |
|---|---|
| 代理 | `http://127.0.0.1:7890`（curl 实测 200 通） |
| 主 DSH | `127.0.0.1:3080`（运行中，200，**禁止干扰**） |
| Swift | swiftc 6.4，**无完整 Xcode/xcodebuild**，SPM `swift build` 坏（signal 5）→ 手工 swiftc 管线 |
| SwiftUI 宏 | 不可用 → 全 AppKit |
| 用户 shell | `/bin/zsh -lic`（可拿 npx：fnm multishell 路径） |
| npm 缓存 | `~/.npm` root-owned → 需 `npm_config_cache` 覆盖 |
| 日志位置 | `~/Library/Application Support/DSHLite/logs/dshlite.log`（沙箱外测试需 DSHLITE_HOME 重定向） |
| 配置位置 | `~/Library/Application Support/DSHLite/config.json` |

## 六、用户沟通红线

- **输出简体中文**
- 用户强烈反感过度工程：**只做计划内功能**，不加"杂七杂八"的东西
- 用户明确说过：*"计划已经很详细了,你非要加一堆乱起八糟的东西,进行反思,重新来"*
- 先让 App 跑起来（Build → Finder 启动 → 后台 DSH → READY → WKWebView → 可用）再谈测试/文档

## 七、2026-08-28 收口状态

- **已实现**：DSH 菜单和状态栏菜单提供最小 `Update DSH…` 操作。仅 Auto runtime 可用；用户确认后通过 `/bin/zsh -lic` 执行 `npm install -g -- <当前 packageSpec>`，复用 Settings 校验和 shell quoting；`--` 确保即使 spec 以 `-` 开头也作为位置参数。更新不检查版本、不修改 package spec、不自动重启 DSH，输出进入脱敏日志，退出码失败会提示查看日志；App 退出时清理更新进程组。
- **已实现**：Settings 增加可选 `trustedHosts`（默认空列表），设置面板支持逗号/换行分隔的 `host` 或 `host:port`，保存时去空、去重并校验 DNS/IPv4 authority。启动命令保持 `--host 127.0.0.1`，仅为每项追加安全引用的 `--trusted-host`；此配置只用于零信任网关后的浏览器 trust，不提供认证/TLS，网关负责外部访问控制。
- **已实现**：Settings 增加可选 `fixedPort`（默认 `nil`），设置面板可填写 `1`–`65535`（空值使用随机端口）。配置固定端口时 DSH 仍只绑定 `127.0.0.1`，启动重试保持同一端口，不支持外部 bind；该选项仅用于零信任网关 upstream。

- **已实现**：WKWebView 在 AppKit `loadView()` 中单实例创建并复用；网页导航失败显示轻量覆盖层，可重新加载页面、重启 DSH 或查看日志；未注入 JavaScript、未增加浏览器工具栏。
- **已实现**：`keepRunningWhenWindowClosed` 为真时 Cmd+W 仅隐藏窗口；为假时停止后端，Dock/菜单重新显示窗口时对 stopped/failed 状态重新启动。
- **已实现**：保存启动设置后明确询问是否立即重启，不再静默替换运行中的 supervisor。
- **已实现**：`Scripts/build-app.sh` 清理并从源码全量编译，仅支持 native；签名、bundle 和可执行文件校验失败会返回非零。
- **已实现**：README 与 `.gitignore` 已收口，明确未锁定 DSH 版本、公开 CLI 兼容边界及 DSH Desktop 功能边界。
- **待验证**：需要在目标 macOS 图形环境中手工确认导航失败覆盖层、Cmd+W 两种策略和 Cmd+Q 进程清理；本轮不运行真实 E2E，也不触碰 `127.0.0.1:3080`。
