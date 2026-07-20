#!/bin/bash
# 中文安装脚本：检查 Python、生成 LaunchAgent、加载并启动服务。

set -euo pipefail

# 从图形 App 启动时环境变量较少，补充系统和常见 Homebrew Python 路径。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ai.filesorter"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALLED_PLIST="$AGENTS_DIR/$LABEL.plist"

if ! command -v python3 >/dev/null 2>&1; then
    echo "未找到 Python 3。请先安装 Xcode Command Line Tools（xcode-select --install）或 Homebrew Python。"
    exit 1
fi

PYTHON_BIN="$(command -v python3)"
PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print("%s.%s" % sys.version_info[:2])')"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)'; then
    echo "需要 Python 3.8 或更高版本，当前版本：$PYTHON_VERSION"
    exit 1
fi

# 从配置读取实际监听目录，让图形界面的文件夹选择能够生效。
WATCH_DIR="$($PYTHON_BIN - "$PROJECT_DIR/config.json" <<'PY'
import json
import os
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    configured = json.load(handle).get("watch_folder", "~/Downloads")
print(os.path.abspath(os.path.expandvars(os.path.expanduser(configured))))
PY
)"

mkdir -p "$PROJECT_DIR/logs" "$AGENTS_DIR" "$WATCH_DIR"
chmod +x "$PROJECT_DIR/install.sh" "$PROJECT_DIR/start.sh" "$PROJECT_DIR/stop.sh"

# 本项目只使用 Python 标准库，因此依赖安装步骤仅做语法和配置检查。
"$PYTHON_BIN" -m compileall -q "$PROJECT_DIR/main.py" "$PROJECT_DIR/sorter.py" "$PROJECT_DIR/logger.py" "$PROJECT_DIR/ai_classifier.py"
"$PYTHON_BIN" "$PROJECT_DIR/main.py" --config "$PROJECT_DIR/config.json" --check-config

# 直接生成 LaunchAgent，不再依赖外部 plist 模板，避免 App 资源部署不完整时安装失败。
"$PYTHON_BIN" - "$INSTALLED_PLIST" "$PYTHON_BIN" "$PROJECT_DIR" "$WATCH_DIR" <<'PY'
import plistlib
import sys

output, python_path, project_dir, watch_dir = sys.argv[1:]
config_path = project_dir + "/config.json"
data = {
    "Label": "com.ai.filesorter",
    "ProgramArguments": [python_path, project_dir + "/main.py", "--config", config_path],
    "RunAtLoad": True,
    "WatchPaths": [watch_dir, config_path],
    "WorkingDirectory": project_dir,
    "ProcessType": "Background",
    "ThrottleInterval": 5,
    "StandardOutPath": project_dir + "/logs/launchd.out.log",
    "StandardErrorPath": project_dir + "/logs/launchd.err.log",
}

with open(output, "wb") as handle:
    plistlib.dump(data, handle, sort_keys=False)
PY

plutil -lint "$INSTALLED_PLIST" >/dev/null

# 仅供自动化测试验证生成结果；正常安装不会设置此变量。
if [ "${AI_FILE_SORTER_DRY_RUN:-0}" = "1" ]; then
    echo "LaunchAgent 生成检查通过：$INSTALLED_PLIST"
    exit 0
fi

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$INSTALLED_PLIST"

echo ""
echo "安装成功。"
echo "Python：$PYTHON_BIN ($PYTHON_VERSION)"
echo "监听目录：$WATCH_DIR"
echo "配置文件：$PROJECT_DIR/config.json"
echo "日志文件：$PROJECT_DIR/logs/sorter.log"
echo "首次启动会保留 Downloads 现有文件；之后新下载的文件会自动整理。"
