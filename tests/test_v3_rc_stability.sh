#!/bin/bash
# v3 RC Agent 扫描合同和跨进程 mutation lock 测试。
# 每个场景都使用独立临时目录，并真实启动多个 Agent 进程。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/artifacts/AI File Sorter.app"
AGENT="$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"
ROOT="$(mktemp -d "/tmp/ai-file-sorter-v3-stability-test.XXXXXX")"
cleanup() {
    if [ "${KEEP_TEST_ROOT:-0}" = "1" ]; then echo "保留测试目录：$ROOT"; else rm -rf "$ROOT"; fi
}
on_exit() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "v3 RC stability test failed with status $status; root=$ROOT"
        find "$ROOT" -maxdepth 4 -type f -print
        for output in "$ROOT"/*/*.out "$ROOT"/*/*/*.out; do
            if [ -f "$output" ]; then
                echo "--- $output"
                sed -n '1,120p' "$output"
            fi
        done
    fi
    cleanup
    trap - EXIT
    exit "$status"
}
trap on_exit EXIT

test -x "$AGENT"

make_config() {
    local scenario="$1"
    local scenario_root="$ROOT/$scenario"
    mkdir -p "$scenario_root/Downloads" "$scenario_root/Target" "$scenario_root/logs"
    cat > "$scenario_root/config.json" <<JSON
{
  "_config_version": 10,
  "watch_folder": "$scenario_root/Downloads",
  "log_file": "$scenario_root/logs/sorter.log",
  "state_file": "$scenario_root/logs/state.json",
  "history_file": "$scenario_root/logs/history.json",
  "scan_interval_seconds": 0.05,
  "stable_seconds": 0,
  "event_idle_seconds": 0.05,
  "max_event_runtime_seconds": 1,
  "process_existing_on_first_start": true,
  "move_method": "native",
  "organization_mode": "automatic",
  "retention_days": 0,
  "recent_modification_protection_hours": 0,
  "automatic_scan_interval_hours": 0,
  "excluded_paths": [],
  "supported_extensions": [".pdf"],
  "rename": {"enabled": false, "template": "{original_name}", "date_format": "%Y-%m-%d"},
  "rules": [
    {"name": "Race rule", "enabled": true, "match_mode": "any", "keywords": ["Race"], "exclude_keywords": [], "extensions": ["pdf"], "target": "$scenario_root/Target"}
  ]
}
JSON
    printf '%s\n' "$scenario_root/config.json"
}

SCAN_CONFIG="$(make_config scan)"
SCAN_ROOT="$ROOT/scan"
echo "v3 RC stability: scan-json"
printf 'scan-secret-content' > "$SCAN_ROOT/Downloads/Race_scan.pdf"
printf 'unfinished' > "$SCAN_ROOT/Downloads/Race_download.part"
printf 'hidden' > "$SCAN_ROOT/Downloads/.hidden.pdf"
printf 'unsupported' > "$SCAN_ROOT/Downloads/Race_notes.txt"
"$AGENT" --config "$SCAN_CONFIG" --scan-json > "$SCAN_ROOT/scan.json"
test "$(plutil -extract schema_version raw "$SCAN_ROOT/scan.json")" = "2"
grep -q '"watch_folder"' "$SCAN_ROOT/scan.json"
grep -q '"status":"automatic_pending"\|"status":"awaiting_confirmation"\|"status":"ready"' "$SCAN_ROOT/scan.json"
grep -q '"status":"temporary"' "$SCAN_ROOT/scan.json"
grep -q '"status":"hidden"' "$SCAN_ROOT/scan.json"
grep -q '"status":"unsupported"' "$SCAN_ROOT/scan.json"
grep -q '"can_manual_move":false' "$SCAN_ROOT/scan.json"
grep -q '"can_include_in_plan":false' "$SCAN_ROOT/scan.json"
grep -q '"modified_ns":' "$SCAN_ROOT/scan.json"
! grep -q 'scan-secret-content' "$SCAN_ROOT/scan.json"

REVIEW_CONFIG="$SCAN_ROOT/review-config.json"
sed 's/"organization_mode": "automatic"/"organization_mode": "review"/' "$SCAN_CONFIG" > "$REVIEW_CONFIG"
"$AGENT" --config "$REVIEW_CONFIG" --scan-json > "$SCAN_ROOT/review.json"
grep -q '"status":"awaiting_confirmation"' "$SCAN_ROOT/review.json"
grep -q '"can_include_in_plan":true' "$SCAN_ROOT/review.json"
grep -q '"can_auto_move_now":false' "$SCAN_ROOT/review.json"

MANUAL_CONFIG="$SCAN_ROOT/manual-config.json"
sed 's/"organization_mode": "automatic"/"organization_mode": "manual"/' "$SCAN_CONFIG" > "$MANUAL_CONFIG"
"$AGENT" --config "$MANUAL_CONFIG" --scan-json > "$SCAN_ROOT/manual.json"
grep -q '"status":"ready"' "$SCAN_ROOT/manual.json"
grep -q '"can_manual_move":true' "$SCAN_ROOT/manual.json"
grep -q '"can_auto_move_now":false' "$SCAN_ROOT/manual.json"

PENDING_CONFIG="$SCAN_ROOT/pending-config.json"
sed -e 's/"stable_seconds": 0/"stable_seconds": 5/' "$SCAN_CONFIG" > "$PENDING_CONFIG"
"$AGENT" --config "$PENDING_CONFIG" --scan-json > "$SCAN_ROOT/pending.json"
grep -q '"status":"automatic_pending"' "$SCAN_ROOT/pending.json"

DIFFERENT_CONFIG="$(make_config different)"
DIFFERENT_ROOT="$ROOT/different"
echo "v3 RC stability: concurrent different files"
printf 'a' > "$DIFFERENT_ROOT/Downloads/Race_a.pdf"
printf 'b' > "$DIFFERENT_ROOT/Downloads/Race_b.pdf"
set +e
"$AGENT" --config "$DIFFERENT_CONFIG" --move-once "$DIFFERENT_ROOT/Downloads/Race_a.pdf" "$DIFFERENT_ROOT/Target" > "$DIFFERENT_ROOT/a.out" 2>&1 &
PID_A=$!
"$AGENT" --config "$DIFFERENT_CONFIG" --move-once "$DIFFERENT_ROOT/Downloads/Race_b.pdf" "$DIFFERENT_ROOT/Target" > "$DIFFERENT_ROOT/b.out" 2>&1 &
PID_B=$!
wait "$PID_A"; STATUS_A=$?
wait "$PID_B"; STATUS_B=$?
set -e
test "$STATUS_A" -eq 0
test "$STATUS_B" -eq 0
test -f "$DIFFERENT_ROOT/Target/Race_a.pdf"
test -f "$DIFFERENT_ROOT/Target/Race_b.pdf"
test -n "$(plutil -extract 0.id raw "$DIFFERENT_ROOT/logs/history.json")"
test "$(grep -o '"id"' "$DIFFERENT_ROOT/logs/history.json" | wc -l | tr -d ' ')" -eq 2

CORRUPT_CONFIG="$(make_config corrupt)"
CORRUPT_ROOT="$ROOT/corrupt"
echo "v3 RC stability: corrupt persistence"
printf 'history-corrupt' > "$CORRUPT_ROOT/Downloads/Race_history_corrupt.pdf"
printf '{not-valid-history' > "$CORRUPT_ROOT/logs/history.json"
cp "$CORRUPT_ROOT/logs/history.json" "$CORRUPT_ROOT/history.before"
set +e
"$AGENT" --config "$CORRUPT_CONFIG" --move-once "$CORRUPT_ROOT/Downloads/Race_history_corrupt.pdf" "$CORRUPT_ROOT/Target" > "$CORRUPT_ROOT/history.out" 2>&1
HISTORY_STATUS=$?
set -e
test "$HISTORY_STATUS" -ne 0
test -f "$CORRUPT_ROOT/Downloads/Race_history_corrupt.pdf"
cmp -s "$CORRUPT_ROOT/history.before" "$CORRUPT_ROOT/logs/history.json"
rm -f "$CORRUPT_ROOT/logs/history.json"
printf 'state-corrupt' > "$CORRUPT_ROOT/Downloads/Race_state_corrupt.pdf"
printf '{not-valid-state' > "$CORRUPT_ROOT/logs/state.json"
cp "$CORRUPT_ROOT/logs/state.json" "$CORRUPT_ROOT/state.before"
set +e
"$AGENT" --config "$CORRUPT_CONFIG" --once > "$CORRUPT_ROOT/state.out" 2>&1
STATE_STATUS=$?
set -e
test "$STATE_STATUS" -ne 0
cmp -s "$CORRUPT_ROOT/state.before" "$CORRUPT_ROOT/logs/state.json"

SAME_CONFIG="$(make_config same)"
SAME_ROOT="$ROOT/same"
echo "v3 RC stability: same-file competition"
printf 'same-file' > "$SAME_ROOT/Downloads/Race_same.pdf"
set +e
"$AGENT" --config "$SAME_CONFIG" --move-once "$SAME_ROOT/Downloads/Race_same.pdf" "$SAME_ROOT/Target" > "$SAME_ROOT/first.out" 2>&1 &
PID_FIRST=$!
"$AGENT" --config "$SAME_CONFIG" --move-once "$SAME_ROOT/Downloads/Race_same.pdf" "$SAME_ROOT/Target" > "$SAME_ROOT/second.out" 2>&1 &
PID_SECOND=$!
wait "$PID_FIRST"; STATUS_FIRST=$?
wait "$PID_SECOND"; STATUS_SECOND=$?
set -e
test $(( (STATUS_FIRST == 0 && STATUS_SECOND != 0) || (STATUS_FIRST != 0 && STATUS_SECOND == 0) )) -eq 1
test "$(find "$SAME_ROOT/Target" -type f -name 'Race_same*.pdf' | wc -l | tr -d ' ')" -eq 1
test -n "$(plutil -extract 0.id raw "$SAME_ROOT/logs/history.json")"
test "$(grep -o '"id"' "$SAME_ROOT/logs/history.json" | wc -l | tr -d ' ')" -eq 1
grep -q '不存在\|未执行\|已不存在' "$SAME_ROOT/first.out" "$SAME_ROOT/second.out"

AUTO_CONFIG="$(make_config automatic-manual)"
AUTO_ROOT="$ROOT/automatic-manual"
echo "v3 RC stability: automatic/manual competition"
printf 'automatic-manual' > "$AUTO_ROOT/Downloads/Race_auto.pdf"
set +e
"$AGENT" --config "$AUTO_CONFIG" --run > "$AUTO_ROOT/automatic.out" 2>&1 &
AUTO_PID=$!
"$AGENT" --config "$AUTO_CONFIG" --move-once "$AUTO_ROOT/Downloads/Race_auto.pdf" "$AUTO_ROOT/Target" > "$AUTO_ROOT/manual.out" 2>&1 &
MANUAL_PID=$!
wait "$AUTO_PID"; AUTO_STATUS=$?
wait "$MANUAL_PID"; MANUAL_STATUS=$?
set -e
echo "v3 RC stability: automatic/manual exit codes automatic=$AUTO_STATUS manual=$MANUAL_STATUS"
test "$AUTO_STATUS" -eq 0
test "$(find "$AUTO_ROOT/Target" -type f -name 'Race_auto*.pdf' | wc -l | tr -d ' ')" -eq 1
test -n "$(plutil -extract 0.id raw "$AUTO_ROOT/logs/history.json")"
test "$(grep -o '"id"' "$AUTO_ROOT/logs/history.json" | wc -l | tr -d ' ')" -eq 1

UNDO_CONFIG="$(make_config undo)"
UNDO_ROOT="$ROOT/undo"
echo "v3 RC stability: undo/automatic competition"
printf 'undo-race' > "$UNDO_ROOT/Downloads/Race_undo.pdf"
"$AGENT" --config "$UNDO_CONFIG" --move-once "$UNDO_ROOT/Downloads/Race_undo.pdf" "$UNDO_ROOT/Target" > "$UNDO_ROOT/move.out" 2>&1
UNDO_ID="$(plutil -extract 0.id raw "$UNDO_ROOT/logs/history.json")"
set +e
"$AGENT" --config "$UNDO_CONFIG" --run > "$UNDO_ROOT/automatic.out" 2>&1 &
UNDO_AUTO_PID=$!
"$AGENT" --config "$UNDO_CONFIG" --undo "$UNDO_ID" > "$UNDO_ROOT/undo.out" 2>&1 &
UNDO_PID=$!
wait "$UNDO_AUTO_PID"; UNDO_AUTO_STATUS=$?
wait "$UNDO_PID"; UNDO_STATUS=$?
set -e
echo "v3 RC stability: undo/automatic exit codes automatic=$UNDO_AUTO_STATUS undo=$UNDO_STATUS"
test "$UNDO_AUTO_STATUS" -eq 0
test "$UNDO_STATUS" -eq 0
test -f "$UNDO_ROOT/Downloads/Race_undo.pdf"
test ! -e "$UNDO_ROOT/Target/Race_undo.pdf"
test -n "$(plutil -extract 0.id raw "$UNDO_ROOT/logs/history.json")"
test "$(plutil -extract version raw "$UNDO_ROOT/logs/state.json")" -ge 2
grep -q '"reason":"undo"' "$UNDO_ROOT/logs/state.json"

echo "v3 RC 扫描合同与并发 mutation lock 测试通过。"
