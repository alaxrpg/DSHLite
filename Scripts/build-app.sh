#!/bin/bash
set -euo pipefail

# 从源码全量构建本机架构的 DSH Lite .app；当前不提供 Universal 构建。
if [ "${1:-native}" != "native" ]; then
    echo "错误：当前仅支持 native 架构；请使用 ./Scripts/build-app.sh native" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/.build-cache"
OBJ="$BUILD/obj"
BIN="$BUILD/DSHLite.bin"
APP_DIR="$ROOT/dist/DSH Lite.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/Assets/DSHFishLogo.svg"
ICONSET="$BUILD/AppIcon.iconset"
APP_ICON="$BUILD/AppIcon.icns"

if [ ! -f "$ICON_SOURCE" ]; then
    echo "错误：缺少官方 DSH FishLogo 源文件 $ICON_SOURCE" >&2
    exit 2
fi

echo "==> 清理本项目编译缓存"
rm -rf "$OBJ" "$BIN" "$ICONSET" "$APP_ICON"
mkdir -p "$OBJ" "$BUILD/modules"

echo "==> 从官方 FishLogo 生成 AppIcon.icns"
swift "$ROOT/Scripts/generate-app-icon.swift" "$ICON_SOURCE" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_ICON"
test -f "$APP_ICON"

echo "==> 编译 DSHLiteCore 源码"
pushd "$OBJ" >/dev/null
swiftc -module-name DSHLiteCore -parse-as-library -module-cache-path "$BUILD/modules" \
    -emit-module -emit-module-path "$BUILD/DSHLiteCore.swiftmodule" -c -emit-object \
    "$ROOT"/Sources/DSHLiteCore/Backend/*.swift "$ROOT"/Sources/DSHLiteCore/Support/*.swift

echo "==> 编译 DSHLite AppKit 源码"
swiftc -module-name DSHLite -parse-as-library -module-cache-path "$BUILD/modules" -I "$BUILD" \
    -c -emit-object "$ROOT"/Sources/DSHLite/App/*.swift "$ROOT"/Sources/DSHLite/AppKit/*.swift
popd >/dev/null

echo "==> 链接可执行文件"
APP_OBJECTS=("$OBJ"/DSHLiteApp.o "$OBJ"/AppState.o "$OBJ"/AppStateHolder.o "$OBJ"/MainViewController.o "$OBJ"/LogsPanel.o "$OBJ"/SettingsPanel.o)
CORE_OBJECTS=("$OBJ"/BackendSupervisor.o "$OBJ"/BackendState.o "$OBJ"/ChildProcessRunner.o "$OBJ"/HealthProbe.o "$OBJ"/LaunchSpec.o "$OBJ"/PortAllocator.o "$OBJ"/ServerAddressDetector.o "$OBJ"/AppPaths.o "$OBJ"/LogStore.o "$OBJ"/SettingsStore.o)
swiftc -o "$BIN" -module-cache-path "$BUILD/modules" -I "$BUILD" \
    "${APP_OBJECTS[@]}" "${CORE_OBJECTS[@]}"

echo "==> 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/DSH Lite"
cp "$APP_ICON" "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleExecutable</key><string>DSH Lite</string>
<key>CFBundleIdentifier</key><string>com.dshlite.app</string>
<key>CFBundleName</key><string>DSH Lite</string>
<key>CFBundleDisplayName</key><string>DSH Lite</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

chmod +x "$MACOS/DSH Lite"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
test -x "$MACOS/DSH Lite"
test -f "$CONTENTS/Info.plist"
test -f "$RESOURCES/AppIcon.icns"
echo "==> 完成: $APP_DIR"
