#!/bin/bash
# 原生 Agent 端到端测试：全部文件位于临时目录，不访问用户真实 Downloads。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/artifacts/AI File Sorter.app"
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
  "organization_mode": "automatic",
  "retention_days": 0,
  "recent_modification_protection_hours": 0,
  "automatic_scan_interval_hours": 0,
  "excluded_paths": [],
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

# 预先占用整理目标，确认原生 Agent 使用 _1 后缀而不是覆盖已有文件。
COLLISION_CONFIG="$ROOT/collision-config.json"
sed "s#\"history_file\": \"$ROOT/logs/history.json\"#\"history_file\": \"$ROOT/logs/collision-history.json\"#" "$CONFIG" > "$COLLISION_CONFIG"
COLLISION_DEST="$ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_重名.pdf"
mkdir -p "$(dirname "$COLLISION_DEST")"
printf 'existing' > "$COLLISION_DEST"
printf 'incoming' > "$ROOT/Downloads/Samsung_重名.pdf"
"$AGENT" --config "$COLLISION_CONFIG" --once
test "$(cat "$COLLISION_DEST")" = "existing"
test -f "$ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_重名_1.pdf"
test ! -e "$ROOT/Downloads/Samsung_重名.pdf"

# 验证由 LaunchAgent 使用的事件模式和状态文件。
printf 'event' > "$ROOT/Downloads/三星_event.pdf"
"$AGENT" --config "$CONFIG"
test -f "$ROOT/Library/Samsung/$(date +%Y-%m-%d)_三星_event.pdf"
test -f "$ROOT/logs/state.json"

# 验证明确的单次例外：只移动本次选择，不建立规则，写入历史，并可通过记录 ID 撤销。
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

# 旧配置缺少新字段时默认进入审阅模式，后台不能直接移动命中规则的文件。
LEGACY_CONFIG="$ROOT/legacy-config.json"
sed -e '/"organization_mode"/d' \
    -e '/"retention_days"/d' \
    -e '/"recent_modification_protection_hours"/d' \
    -e '/"automatic_scan_interval_hours"/d' \
    -e '/"excluded_paths"/d' \
    -e "s#\"log_file\": \"$ROOT/logs/sorter.log\"#\"log_file\": \"$ROOT/logs/legacy.log\"#" \
    -e "s#\"state_file\": \"$ROOT/logs/state.json\"#\"state_file\": \"$ROOT/logs/legacy-state.json\"#" "$CONFIG" > "$LEGACY_CONFIG"
printf 'legacy-review' > "$ROOT/Downloads/Samsung_旧配置审阅.pdf"
"$AGENT" --config "$LEGACY_CONFIG"
test -f "$ROOT/Downloads/Samsung_旧配置审阅.pdf"
grep -q '当前整理模式不允许后台自动移动：review' "$ROOT/logs/legacy.log"

# 手动模式与审阅模式都必须只提供待处理内容，不能被后台事件直接移动。
MANUAL_CONFIG="$ROOT/manual-config.json"
sed -e 's/"organization_mode": "automatic"/"organization_mode": "manual"/' \
    -e "s#\"log_file\": \"$ROOT/logs/sorter.log\"#\"log_file\": \"$ROOT/logs/manual.log\"#" \
    -e "s#\"state_file\": \"$ROOT/logs/state.json\"#\"state_file\": \"$ROOT/logs/manual-state.json\"#" "$CONFIG" > "$MANUAL_CONFIG"
printf 'manual-mode' > "$ROOT/Downloads/Samsung_手动模式.pdf"
"$AGENT" --config "$MANUAL_CONFIG"
test -f "$ROOT/Downloads/Samsung_手动模式.pdf"
grep -q '当前整理模式不允许后台自动移动：manual' "$ROOT/logs/manual.log"

# 排除路径在后台自动模式下也必须保留原位。
EXCLUDED_CONFIG="$ROOT/excluded-config.json"
sed "s#\"excluded_paths\": \[\],#\"excluded_paths\": [\"$ROOT/Downloads/Samsung_排除.pdf\"],#" "$CONFIG" > "$EXCLUDED_CONFIG"
printf 'excluded' > "$ROOT/Downloads/Samsung_排除.pdf"
"$AGENT" --config "$EXCLUDED_CONFIG"
test -f "$ROOT/Downloads/Samsung_排除.pdf"

# 保留时间使用旧创建日期的合成文件验证；最近修改保护使用当前创建文件验证。
if ! command -v SetFile >/dev/null 2>&1; then
    echo "错误：macOS 原生测试需要 SetFile 来设置合成文件的创建日期"
    exit 1
fi
PROTECTION_ROOT="$ROOT/protection"
mkdir -p "$PROTECTION_ROOT/Downloads"
RETENTION_CONFIG="$PROTECTION_ROOT/retention-config.json"
sed -e "s#$ROOT/Downloads#$PROTECTION_ROOT/Downloads#g" \
    -e "s#$ROOT/Library#$PROTECTION_ROOT/Library#g" \
    -e "s#$ROOT/logs#$PROTECTION_ROOT/logs#g" \
    -e 's/"retention_days": 0/"retention_days": 1/' \
    "$CONFIG" > "$RETENTION_CONFIG"
printf 'old-enough' > "$PROTECTION_ROOT/Downloads/Samsung_保留期后移动.pdf"
touch -t 202001010000 "$PROTECTION_ROOT/Downloads/Samsung_保留期后移动.pdf"
SetFile -d '01/01/2020 00:00:00' "$PROTECTION_ROOT/Downloads/Samsung_保留期后移动.pdf"
"$AGENT" --config "$RETENTION_CONFIG"
test -f "$PROTECTION_ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_保留期后移动.pdf"
printf 'new-retention' > "$PROTECTION_ROOT/Downloads/Samsung_once_保留期.pdf"
"$AGENT" --config "$RETENTION_CONFIG" --once
test -f "$PROTECTION_ROOT/Downloads/Samsung_once_保留期.pdf"
"$AGENT" --config "$RETENTION_CONFIG" --move-once "$PROTECTION_ROOT/Downloads/Samsung_once_保留期.pdf" "$PROTECTION_ROOT/Quick"
test -f "$PROTECTION_ROOT/Quick/Samsung_once_保留期.pdf"

RECENT_CONFIG="$PROTECTION_ROOT/recent-config.json"
sed -e 's/"retention_days": 1/"retention_days": 0/' \
    -e 's/"recent_modification_protection_hours": 0/"recent_modification_protection_hours": 24/' \
    -e "s#$PROTECTION_ROOT/logs/state.json#$PROTECTION_ROOT/logs/recent-state.json#g" \
    -e "s#$PROTECTION_ROOT/logs/sorter.log#$PROTECTION_ROOT/logs/recent.log#g" \
    -e "s#$PROTECTION_ROOT/logs/history.json#$PROTECTION_ROOT/logs/recent-history.json#g" \
    "$RETENTION_CONFIG" > "$RECENT_CONFIG"
printf 'still-changing' > "$PROTECTION_ROOT/Downloads/Samsung_最近修改保护.pdf"
"$AGENT" --config "$RECENT_CONFIG" --once
test -f "$PROTECTION_ROOT/Downloads/Samsung_最近修改保护.pdf"
test ! -e "$PROTECTION_ROOT/Library/Samsung/$(date +%Y-%m-%d)_Samsung_最近修改保护.pdf"
"$AGENT" --config "$RECENT_CONFIG" --move-once "$PROTECTION_ROOT/Downloads/Samsung_最近修改保护.pdf" "$PROTECTION_ROOT/Quick"
test -f "$PROTECTION_ROOT/Quick/Samsung_最近修改保护.pdf"

# 目标路径位于监听目录内时，必须在配置加载阶段拒绝，避免出现整理循环。
LOOP_CONFIG="$ROOT/loop-config.json"
sed "s#\"target\": \"$ROOT/Library/Samsung\"#\"target\": \"$ROOT/Downloads/分类结果\"#" "$CONFIG" > "$LOOP_CONFIG"
if "$AGENT" --config "$LOOP_CONFIG" --check-config; then
    echo "错误：监听目录内部目标不应通过配置检查"
    exit 1
fi

# 符号链接不能把监听目录外的真实文件伪装成可整理来源。
OUTSIDE_FILE="$ROOT/outside.pdf"
printf 'outside' > "$OUTSIDE_FILE"
ln -s "$OUTSIDE_FILE" "$ROOT/Downloads/Samsung_监听外部链接.pdf"
if "$AGENT" --config "$CONFIG" --move-once "$ROOT/Downloads/Samsung_监听外部链接.pdf" "$ROOT/Quick"; then
    echo "错误：指向监听目录外的符号链接不应被移动"
    exit 1
fi
test -f "$OUTSIDE_FILE"
test -L "$ROOT/Downloads/Samsung_监听外部链接.pdf"

# 临时下载后缀即使被明确选择也不能移动。
printf 'partial' > "$ROOT/Downloads/Samsung_未完成.part"
if "$AGENT" --config "$CONFIG" --move-once "$ROOT/Downloads/Samsung_未完成.part" "$ROOT/Quick"; then
    echo "错误：临时下载文件不应被移动"
    exit 1
fi
test -f "$ROOT/Downloads/Samsung_未完成.part"

echo "原生 Agent 端到端测试通过。"
