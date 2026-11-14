#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/dist/Todolist.app"
DEST_DIR="$HOME/Applications"

if [ ! -d "$SRC" ]; then
  echo "先运行 ./build.sh 生成 $SRC"
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/Todolist.app"
cp -R "$SRC" "$DEST_DIR/Todolist.app"
xattr -dr com.apple.quarantine "$DEST_DIR/Todolist.app" 2>/dev/null || true
echo "已安装到 $DEST_DIR/Todolist.app"

if pgrep -x Todolist >/dev/null 2>&1; then
  pkill -x Todolist || true
  sleep 0.5
fi
open "$DEST_DIR/Todolist.app"
echo "已启动，看菜单栏右上角图标。"