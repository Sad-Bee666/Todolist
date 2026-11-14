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

IDENTITY="Todolist Local Signing"
echo "==> 签名"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP" || {
    echo "警告：本地证书签名失败，退回 ad-hoc"
    codesign --force --deep --sign - "$APP" || echo "警告：ad-hoc 签名也失败"
  }
else
  echo "（未找到本地证书，使用 ad-hoc：TCC 授权会在每次重建后失效）"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "警告：签名失败，仍可直接运行"
fi

echo "==> 完成：$APP"