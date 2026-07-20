#!/bin/bash
# 原生 2.0 Agent 端到端测试：全部文件位于临时目录，不访问用户真实 Downloads。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$(cd "$PROJECT_DIR/.." && pwd)/AI File Sorter.app"
AGENT="$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-file-sorter-native-test.XXXXXX")"
cleanup() {
    if [ "${KEEP_TEST_ROOT:-0}" = "1" ]; then echo "保留测试目录：$ROOT"; else rm -rf "$ROOT"; fi
}
trap cleanup EXIT

mkdir -p "$ROOT/Downloads"
CONFIG="$ROOT/config.json"

cat > "$CONFIG" <<JSON
{
  "_config_version": 3,
  "watch_folder": "$ROOT/Downloads",
  "log_file": "$ROOT/logs/sorter.log",
  "state_file": "$ROOT/logs/state.json",
  "history_file": "$ROOT/logs/history.json",
  "scan_interval_seconds": 0.05,
  "stable_seconds": 0.05,
  "event_idle_seconds": 0.05,
  "max_event_runtime_seconds": 2,
  "process_existing_on_first_start": true,
  "move_method": "native",
  "rename": {"enabled": true, "template": "{date}_{original_name}", "date_format": "%Y-%m-%d"},
  "supported_extensions": [".pdf", ".docx", ".jpg"],
  "rules": [
    {"enabled": true, "match_mode": "any", "keywords": ["Samsung", "三星"], "exclude_keywords": [], "extensions": [], "target": "$ROOT/Library/Samsung"},
    {"enabled": true, "match_mode": "all", "keywords": ["Project", "Final"], "exclude_keywords": ["draft"], "extensions": ["pdf"], "target": "$ROOT/Library/Advanced"},
    {"enabled": false, "match_mode": "any", "keywords": ["Disabled"], "exclude_keywords": [], "extensions": [], "target": "$ROOT/Library/Disabled"},
    {"name": "全部图片", "enabled": true, "match_mode": "any", "keywords": [], "exclude_keywords": [], "extensions": ["jpg"], "target": "$ROOT/Library/Images"},
    {"name": "正则和大小", "enabled": true, "match_mode": "any", "keywords": [], "exclude_keywords": [], "extensions": ["pdf"], "name_regex": "^Report_[0-9]{4}[.]pdf$", "minimum_size_mb": 0.000001, "target": "$ROOT/Library/Regex"}
  ]
}
JSON

printf 'matched' > "$ROOT/Downloads/Samsung_S95F.pdf"
printf 'unknown' > "$ROOT/Downloads/其他资料.pdf"

"$AGENT" --config "$CONFIG" --check-config
# 后台组件必须保留固定签名标识，供 macOS 权限系统跨升级识别。
test "$(codesign -dv "$AGENT" 2>&1 | sed -n 's/^Identifier=//p')" = "com.ai.filesorter.agent"
"$AGENT" --config "$CONFIG" --once

test -f "$ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_S95F.pdf"
test -f "$ROOT/Downloads/其他资料.pdf"
test -f "$ROOT/logs/history.json"
grep -q '结果=成功' "$ROOT/logs/sorter.log"
grep -q '结果=未分类' "$ROOT/logs/sorter.log"
grep -q '手动整理完成' "$ROOT/logs/sorter.log"

# 验证由 LaunchAgent 使用的事件模式和状态文件。
printf 'event' > "$ROOT/Downloads/三星_event.pdf"
"$AGENT" --config "$CONFIG"
test -f "$ROOT/Library/Samsung/$(date +%Y-%m-%d)_三星_event.pdf"
test -f "$ROOT/logs/state.json"

# 验证单次批量整理不建立规则、写入历史，并可通过记录 ID 撤销。
printf 'one-time' > "$ROOT/Downloads/Samsung_临时单次文件.pdf"
"$AGENT" --config "$CONFIG" --move-many "$ROOT/Quick" "$ROOT/Downloads/Samsung_临时单次文件.pdf"
test -f "$ROOT/Quick/Samsung_临时单次文件.pdf"
grep -q '单次整理' "$ROOT/logs/history.json"
HISTORY_ID="$(plutil -extract 2.id raw "$ROOT/logs/history.json")"
"$AGENT" --config "$CONFIG" --undo "$HISTORY_ID"
test -f "$ROOT/Downloads/Samsung_临时单次文件.pdf"
# 整理计划使用同一个批次 ID，支持一次撤销整批文件。
printf 'batch-a' > "$ROOT/Downloads/Samsung_批次A.pdf"
printf 'batch-b' > "$ROOT/Downloads/Samsung_批次B.pdf"
"$AGENT" --config "$CONFIG" --sort-paths "$ROOT/Downloads/Samsung_批次A.pdf" "$ROOT/Downloads/Samsung_批次B.pdf"
test -f "$ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_批次A.pdf"
BATCH_ID="$(plutil -extract 4.batch_id raw "$ROOT/logs/history.json")"
"$AGENT" --config "$CONFIG" --undo-batch "$BATCH_ID"
test -f "$ROOT/Downloads/Samsung_批次A.pdf"
test -f "$ROOT/Downloads/Samsung_批次B.pdf"
grep -q '"undone":true' "$ROOT/logs/history.json"
grep -q '"reason":"undo"' "$ROOT/logs/state.json"
# 即使文件名命中规则，撤销后也不会被目录事件立刻再次移走。
"$AGENT" --config "$CONFIG"
test -f "$ROOT/Downloads/Samsung_临时单次文件.pdf"
# 目标与当前目录相同时必须拒绝，避免文件被无意义地重复改名。
if "$AGENT" --config "$CONFIG" --move-once "$ROOT/Downloads/Samsung_临时单次文件.pdf" "$ROOT/Downloads"; then
    echo "错误：同目录单次整理不应成功"
    exit 1
fi

# 验证“全部关键词”、排除词、扩展名条件和停用规则。
printf 'advanced' > "$ROOT/Downloads/Project_Final.pdf"
printf 'excluded' > "$ROOT/Downloads/Project_Final_draft.pdf"
printf 'wrong-extension' > "$ROOT/Downloads/Project_Final.docx"
printf 'disabled' > "$ROOT/Downloads/Disabled.pdf"
printf 'extension-only' > "$ROOT/Downloads/普通照片.jpg"
printf 'regex-size' > "$ROOT/Downloads/Report_2026.pdf"
"$AGENT" --config "$CONFIG"
test -f "$ROOT/Library/Advanced/$(date +%Y-%m-%d)_Project_Final.pdf"
test -f "$ROOT/Downloads/Project_Final_draft.pdf"
test -f "$ROOT/Downloads/Project_Final.docx"
test -f "$ROOT/Downloads/Disabled.pdf"
test -f "$ROOT/Library/Images/$(date +%Y-%m-%d)_普通照片.jpg"
test -f "$ROOT/Library/Regex/$(date +%Y-%m-%d)_Report_2026.pdf"

# 自动监听持有事件锁时，待分类里的手动批量移动仍必须立即可用。
BUSY_CONFIG="$ROOT/busy-config.json"
sed 's/"event_idle_seconds": 0.05/"event_idle_seconds": 1/' "$CONFIG" > "$BUSY_CONFIG"
"$AGENT" --config "$BUSY_CONFIG" &
EVENT_PID=$!
sleep 0.1
printf 'manual-during-watch' > "$ROOT/Downloads/无规则_监听期间移动.pdf"
"$AGENT" --config "$BUSY_CONFIG" --move-many "$ROOT/Quick" "$ROOT/Downloads/无规则_监听期间移动.pdf"
test -f "$ROOT/Quick/无规则_监听期间移动.pdf"
wait "$EVENT_PID"

# 验证 1.x Python 状态文件会安全迁移，而不是当作全新安装。
cat > "$ROOT/logs/state.json" <<JSON
{"version":1,"initialized":true,"rules_fingerprint":"legacy","files":{}}
JSON
"$AGENT" --config "$CONFIG"
grep -q '"version":2' "$ROOT/logs/state.json"
grep -q '迁移到原生 2.0 格式' "$ROOT/logs/sorter.log"

echo "原生 Agent 端到端测试通过。"
