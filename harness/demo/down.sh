#!/usr/bin/env bash
# 停掉演示环境（up.sh 起的进程）并删掉演示库。
HERE="$(cd "$(dirname "$0")" && pwd)"; PIDS="$HERE/work/pids"
if [ -f "$PIDS" ]; then while read -r p; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done < "$PIDS"; fi
pkill -f "demo-upstream.py" 2>/dev/null; pkill -f "next dev -p 8888" 2>/dev/null; pkill -f "next dev -p 8880" 2>/dev/null
dropdb -U "${PGUSER:-$(whoami)}" --if-exists netonapi_demo 2>/dev/null
rm -rf "$HERE/work"
echo "演示环境已停止"
