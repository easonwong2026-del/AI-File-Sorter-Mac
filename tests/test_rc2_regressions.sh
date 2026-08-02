#!/bin/bash
# rc.2 崩溃回归、schema v2 与收件箱快照语义测试。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-file-sorter-rc2-regression.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
HARNESS="$ROOT/rc2-harness.swift"
EXECUTABLE="$ROOT/rc2-harness"
MODULE_CACHE="$ROOT/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE"

cat > "$HARNESS" <<'SWIFT'
import Foundation

@main
struct RC2Harness {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("失败：\(message)\n".utf8))
            exit(1)
        }
    }

    static func item(
        path: String,
        status: FileProcessingStatus,
        modifiedNs: Int64 = 1_754_098_560_123_000_000,
        target: String = "~/Target",
        canManualMove: Bool = true,
        canIncludeInPlan: Bool = false
    ) -> FileAssessmentItem {
        FileAssessmentItem(
            path: path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: "pdf",
            fileSize: 10,
            modifiedAt: "not-a-date",
            modifiedNs: modifiedNs,
            status: status,
            reason: status.rawValue,
            remainingSeconds: status == .waitingRetention ? 20 : 0,
            ruleName: canIncludeInPlan ? "Rule" : "",
            targetFolder: target,
            destinationPath: target + "/file.pdf",
            canManualMove: canManualMove,
            canIncludeInPlan: canIncludeInPlan,
            canAutoMoveNow: status == .ready
        )
    }

    static func main() throws {
        let json = #"{"schema_version":2,"generated_at":"2026-08-02T01:36:00.123Z","watch_folder":"/tmp/Downloads","items":[{"path":"/tmp/Downloads/a.pdf","file_name":"a.pdf","extension":"pdf","file_size":10,"modified_at":"invalid","modified_ns":1754098560123000000,"status":"ready","reason":"ok","remaining_seconds":0,"rule_name":"Rule","target_folder":"/tmp/Target","destination_path":"/tmp/Target/a.pdf","can_manual_move":true,"can_include_in_plan":true,"can_auto_move_now":true}]}"#
        let document = try JSONDecoder().decode(FileAssessmentDocument.self, from: Data(json.utf8))
        check(document.schemaVersion == 2, "应读取 schema v2")
        check(document.items[0].modifiedNs == 1_754_098_560_123_000_000, "modified_ns 必须保持整数精度")
        check(AssessmentTimestamp.date(from: document.items[0].modifiedAt) == nil, "非法显示时间应返回 nil")
        for value in [
            "2026-08-02T01:36:00.123Z",
            "2026-08-02T01:36:00.123456Z",
            "2026-08-02T01:36:00.123456789Z",
            "2026-08-02T01:36:00Z",
            "1960-01-01T00:00:00.000Z",
            "2500-01-01T00:00:00.000Z"
        ] {
            check(AssessmentTimestamp.date(from: value) != nil, "应支持安全显示解析：\(value)")
        }

        let path = "/tmp/Downloads/file.pdf"
        let waiting = item(path: path, status: .waitingRetention, target: "/tmp/OldTarget")
        var old = PendingFile(assessment: waiting, keyword: "用户关键词", selected: true, ignored: true)
        let updated = item(path: path, status: .ready, target: "/tmp/NewTarget", canIncludeInPlan: true)
        let rebuilt = [PendingFile.rebuilding(
            assessment: updated,
            previous: old,
            suggestedKeyword: "自动关键词",
            ignored: true,
            permissions: AssessmentActionPermissions(
                canManualMove: updated.canManualMove,
                canIncludeInPlan: updated.canIncludeInPlan,
                canAutoMoveNow: updated.canAutoMoveNow
            )
        )]
        check(rebuilt.count == 1, "同路径的新 assessment 应替换旧条目")
        check(rebuilt[0].assessment.status == .ready, "状态应更新")
        check(rebuilt[0].assessment.targetFolder == "/tmp/NewTarget", "目标应更新")
        check(rebuilt[0].keyword == "用户关键词", "keyword 应保留")
        check(rebuilt[0].ignored, "ignored 应保留")
        check(!rebuilt[0].selected, "ignored 条目不能保持 selected")

        old.ignored = false
        old.selected = true
        let locked = item(path: "/tmp/Downloads/locked.pdf", status: .locked, canManualMove: false)
        let lockedResult = [PendingFile.rebuilding(
            assessment: locked,
            previous: old,
            suggestedKeyword: "locked",
            ignored: false,
            permissions: AssessmentActionPermissions(
                canManualMove: locked.canManualMove,
                canIncludeInPlan: locked.canIncludeInPlan,
                canAutoMoveNow: locked.canAutoMoveNow
            )
        )]
        check(!lockedResult[0].selected, "新 assessment 不可手动选择时必须取消 selected")
        check(lockedResult[0].assessment.canIncludeInPlan == false, "locked 不得进入整理计划")
        check([PendingFile]().isEmpty, "删除文件应从列表消失")
        print("rc.2 timestamp/schema/snapshot 回归测试通过。")
    }
}
SWIFT

swiftc -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macosx13.0" \
    -framework SwiftUI -framework AppKit -framework QuickLookUI \
    "$PROJECT_DIR/mac-app/Sources/Core/FileAssessmentTypes.swift" \
    "$PROJECT_DIR/mac-app/Sources/Core/AssessmentTimestamp.swift" \
    "$PROJECT_DIR/mac-app/Sources/Models/SorterModels.swift" \
    "$HARNESS" -o "$EXECUTABLE"
"$EXECUTABLE"
