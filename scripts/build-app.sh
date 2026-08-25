#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="微信发送"
APP_DIR="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
swift test
swift build -c release

rm -rf "$APP_DIR" "$ROOT/dist/轻羽发送.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT/.build/release/LeafSend" "$APP_DIR/Contents/MacOS/LeafSend"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

rm -rf "$ROOT/.build/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/.build/AppIcon.iconset"
iconutil -c icns "$ROOT/.build/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# Keep the designated requirement stable across ad-hoc builds so macOS TCC
# permissions continue to match after the app bundle is replaced.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "local.wechatsend.app"' \
  "$APP_DIR"
echo "$APP_DIR"
