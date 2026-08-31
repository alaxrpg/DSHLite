#!/bin/bash
set -euo pipefail

PACKAGE_SPEC="${DSH_PACKAGE_SPEC:-${1:-@deepseek-ai/dsh@next}}"
RUNTIME_HOME="${DSH_RUNTIME_HOME:-$HOME/.local/share/dsh-runtime}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
REWIRE_GLOBAL="${DSH_REWIRE_GLOBAL:-0}"

if ! command -v node >/dev/null 2>&1; then
  echo "错误：未找到 node" >&2
  exit 2
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "错误：未找到 pnpm" >&2
  exit 2
fi

mkdir -p "$RUNTIME_HOME" "$BIN_DIR"

cat > "$RUNTIME_HOME/package.json" <<'JSON'
{
  "name": "dsh-runtime",
  "private": true,
  "version": "1.0.0"
}
JSON

cat > "$RUNTIME_HOME/pnpm-workspace.yaml" <<'YAML'
packages:
  - .
nodeLinker: hoisted
autoInstallPeers: true
allowBuilds:
  '@deepseek-ai/dsh-subprocess-local': true
  '@google/genai': true
  koffi: true
  node-pty: true
  protobufjs: true
YAML

pushd "$RUNTIME_HOME" >/dev/null
pnpm add --save-exact "$PACKAGE_SPEC"
popd >/dev/null

DSH_ENTRY="$RUNTIME_HOME/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -f "$DSH_ENTRY" ]; then
  echo "错误：安装完成但未找到 $DSH_ENTRY" >&2
  exit 3
fi

WRAPPER="$BIN_DIR/dsh"
cat > "$WRAPPER" <<EOF
#!/bin/bash
exec node "$DSH_ENTRY" "\$@"
EOF
chmod +x "$WRAPPER"

"$WRAPPER" --version >/dev/null

if [ "$REWIRE_GLOBAL" = "1" ]; then
  GLOBAL_BIN="$(pnpm bin -g)"
  pnpm remove -g @deepseek-ai/dsh >/dev/null 2>&1 || true
  mkdir -p "$GLOBAL_BIN"
  GLOBAL_WRAPPER="$GLOBAL_BIN/dsh"
  cat > "$GLOBAL_WRAPPER" <<EOF
#!/bin/bash
exec node "$DSH_ENTRY" "\$@"
EOF
  chmod +x "$GLOBAL_WRAPPER"
  echo "已将 pnpm 全局 dsh 命令重定向到隔离 runtime：$GLOBAL_WRAPPER"
fi

echo "DSH runtime 已安装：$RUNTIME_HOME"
echo "命令入口：$WRAPPER"
echo "package spec：$PACKAGE_SPEC"
