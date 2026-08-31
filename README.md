# DSH Lite

DSH Lite 是一个轻量的 macOS 原生外壳：使用用户默认的 `/bin/zsh -lic` 环境启动 `npx <packageSpec> web`，等待本机 loopback Web UI 就绪，再用系统 `WKWebView` 展示。它只优化网页访问体验，不重新实现 DSH Desktop。

## 边界

- 不打包 DSH、Node、Chromium 或 Electron，也不修改 DSH 源码。
- 默认 `packageSpec` 为未锁定版本的 `@deepseek-ai/dsh`；可在设置中填写具体版本。
- 兼容边界仅是公开 `dsh web` CLI 与 loopback HTTP，不依赖 DSH 内部 API、DOM、插件或会话文件。
- WKWebView 复用系统持久化网页数据；loopback 导航留在应用，外部链接交给系统浏览器。
- 不提供会话、插件、工作区、终端、多实例或远程服务等 DSH Desktop 功能。

## 使用

运行前需要本机可用的 Node/npm/npx。Finder 启动时通过用户默认 zsh 环境获取这些命令。代理不会自动探测；需要时在 Settings 中手动填写，例如 `http://127.0.0.1:7890`。

在 DSH 菜单或状态栏菜单选择 `Update DSH…`，确认后会在用户默认登录 shell 中执行
`npm install -g -- <当前 packageSpec>`。更新仅适用于 Auto (npx) runtime；Custom runtime
会显示为不适用。更新过程不会自动检查版本、修改 package spec 或重启正在运行的 DSH，输出可在 Logs 中查看。

Settings 中的 `Trust Hosts` 可填写零信任网关反代后的 `host` 或 `host:port`，支持逗号或换行分隔。
这些值只会作为重复的 `--trusted-host` 参数传给公开的 `dsh web` CLI，用于浏览器访问信任配置；
DSH 进程仍只绑定 `127.0.0.1`，DSH Lite 不提供认证或 TLS，网关负责零信任认证、TLS 和外部暴露。

如需让零信任网关稳定连接 upstream，可在 Settings 的 `Fixed Port` 填写 `1`–`65535`（例如 `3080`）。
留空时仍使用随机 loopback 端口。固定端口仅用于 `127.0.0.1` upstream，DSH Lite 不支持绑定外部地址；端口占用时会明确启动失败，重试不会偷偷切换为随机端口。

配置和日志位于：

`~/Library/Application Support/DSHLite/config.json`  
`~/Library/Application Support/DSHLite/logs/`

## 构建

当前构建脚本只生成本机 native 架构，并从源码清理后全量编译：

```sh
./Scripts/build-app.sh native
```

脚本会严格检查 ad-hoc 签名、bundle 和可执行文件。它不会启动真实 DSH，也不会触碰用户正在运行的 `127.0.0.1:3080`。

默认快速验证由项目现有的离线 SmokeProbe/单元测试入口负责；真实 DSH E2E 必须显式运行，并使用临时 `DSHLITE_HOME` 和随机端口。请勿把 E2E 当作构建脚本的隐式步骤。

## 状态

当前 UI、进程监督和网页容器按轻量目标实现。DSH Lite 跟随公开 CLI 的变化；若 CLI 参数发生破坏性变化，只在启动参数位置做最小适配。
