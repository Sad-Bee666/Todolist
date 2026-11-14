#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/dist/Todolist.app"

if [ ! -d "$SRC" ]; then
  echo "先运行 ./build.sh 生成 $SRC"
  exit 1
fi

# 优先装到 /Applications（系统路径，屏幕录制权限链更干净）；无权限时退回 ~/Applications
TARGET="/Applications/Todolist.app"
if ! (mkdir -p "$(dirname "$TARGET")" && touch "$(dirname "$TARGET")/.todolist_write_probe" 2>/dev/null); then
  TARGET="$HOME/Applications/Todolist.app"
  echo "（/Applications 不可写，改装 $TARGET）"
else
  rm -f "$(dirname "$TARGET")/.todolist_write_probe"
fi

if pgrep -x Todolist >/dev/null 2>&1; then
  pkill -x Todolist || true
  sleep 0.6
fi

rm -rf "$TARGET"
mkdir -p "$(dirname "$TARGET")"
cp -R "$SRC" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "已安装到 $TARGET"
open "$TARGET"
echo "已启动。给屏幕录制授权后必须「退出并重开」才会生效。"
echo "自检：open -a \"$TARGET\" --args --self-test 之后看 ~/Library/Application Support/Todolist/selftest.txt"
