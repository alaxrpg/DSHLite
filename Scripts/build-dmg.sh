#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/DSH Lite.app"
STAGE="$ROOT/.build-cache/dmg-root"

"$ROOT/Scripts/build-app.sh" native

if [ ! -d "$APP" ]; then
    echo "错误：未找到编译产物 $APP" >&2
    exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
DMG="$ROOT/dist/DSHLite-${VERSION}-macOS-${ARCH}.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/DSH Lite.app"
ln -s /Applications "$STAGE/Applications"

# UDZO = compressed, read-only disk image. 适合作为 GitHub Release/Artifact 分发。
hdiutil create \
    -volname "DSH Lite" \
    -srcfolder "$STAGE" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG"

hdiutil verify "$DMG"
rm -rf "$STAGE"

echo "==> DMG 完成: $DMG"
