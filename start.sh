#!/bin/bash
# 中文管理脚本：加载 LaunchAgent，并立即触发一次状态检查。

set -euo pipefail

# 与图形 App 启动环境保持一致。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ai.filesorter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -f "$PLIST" ]; then
    echo "尚未安装，请先运行 ./install.sh"
    exit 1
fi

launchctl bootstrap "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID/$LABEL"
echo "AI-File-Sorter-Mac 已启动。"
