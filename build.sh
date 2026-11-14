#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Todolist"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

echo "==> 清理"
rm -rf "$BUILD_DIR" "$APP"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$ROOT/.cache/modules"

echo "==> 编译（$(basename "$SDK")）"
swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$ROOT/.cache/modules" \
  -o "$BUILD_DIR/$APP_NAME" \
  "$ROOT"/Sources/*.swift

echo "==> 组装 .app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "警告：签名失败，仍可直接运行"

echo "==> 完成：$APP"