#!/bin/bash
# 中文管理脚本：卸载 LaunchAgent；配置和日志不会被删除。

set -euo pipefail

# 与图形 App 启动环境保持一致。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ai.filesorter"

if launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "AI-File-Sorter-Mac 已停止。"
else
    echo "AI-File-Sorter-Mac 当前未运行。"
fi
