#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist" 2>/dev/null || echo "1.0.0")"
STAGE="$ROOT/dist/dmg-stage"
OUT="$ROOT/dist/Todolist-$VERSION.dmg"

"$ROOT/build.sh"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/Todolist.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/使用说明.txt" <<'TXT'
Todolist — 菜单栏待办

安装：把 Todolist 拖到右边的 Applications 文件夹。

首次使用：
1. 菜单栏右上角会出现图标，鼠标移上去即展开面板。
2. 第一次按 ⌃⌥T 截图时，macOS 会要求「屏幕录制」权限：
   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 Todolist → 退出并重开应用。
3. 要用模型解析待办：面板齿轮 → 填 API Key（DeepSeek / OpenAI / 自定义）。
   不填也能用，会自动降级为本地规则解析。
4. 数据在 ~/Library/Application Support/Todolist/。
TXT

hdiutil create -volname "Todolist" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
echo "已生成：$OUT"
