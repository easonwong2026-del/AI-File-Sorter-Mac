#!/bin/bash
# 将已构建的 App 安装到系统“应用程序”目录，确保 LaunchAgent 使用固定路径。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$PROJECT_DIR/artifacts/AI File Sorter.app"
TARGET_APP="/Applications/AI File Sorter.app"

if [ ! -d "$SOURCE_APP" ]; then
    "$PROJECT_DIR/build-app.sh"
fi

if [ -w "/Applications" ]; then
    rm -rf "$TARGET_APP"
    ditto "$SOURCE_APP" "$TARGET_APP"
else
    # 非管理员用户会看到一次系统密码提示，仅用于写入 /Applications。
    osascript - "$SOURCE_APP" "$TARGET_APP" <<'APPLESCRIPT'
on run argv
    set sourceApp to item 1 of argv
    set targetApp to item 2 of argv
    do shell script "/bin/rm -rf " & quoted form of targetApp & " && /usr/bin/ditto " & quoted form of sourceApp & " " & quoted form of targetApp with administrator privileges
end run
APPLESCRIPT
fi
open "$TARGET_APP"
echo "已安装并打开：$TARGET_APP"
