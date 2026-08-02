#!/bin/bash
# Apple Silicon 发布包审计：不触碰真实用户目录，只检查 artifacts/ 中的构建结果。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/artifacts/AI File Sorter.app"
ZIP_PATH="$PROJECT_DIR/artifacts/AI-File-Sorter-Mac-Apple-Silicon-v3.0.0-rc.2.zip"

test "$(uname -m)" = "arm64"
test -d "$APP_PATH"
test -f "$ZIP_PATH"
test "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")" = "3.0.0-rc.2"
test "$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")" = "20"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

audit_macho() {
    local path="$1"
    local description
    description="$(file -b "$path")"
    case "$description" in
        *Mach-O*) ;;
        *) return 0 ;;
    esac
    echo "=== $path"
    echo "$description"
    test "$(lipo -archs "$path")" = "arm64"
    if printf '%s\n' "$description" | grep -Eq 'x86_64|i386|universal'; then
        echo "发现非 Apple Silicon 架构：$path" >&2
        exit 1
    fi
    lipo -archs "$path"
}

audit_macho "$APP_PATH/Contents/MacOS/AIFileSorter"
audit_macho "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"

while IFS= read -r -d '' path; do
    audit_macho "$path"
done < <(find "$APP_PATH" -type f -print0)

otool -L "$APP_PATH/Contents/MacOS/AIFileSorter" >/dev/null
otool -L "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent" >/dev/null
echo "Apple Silicon bundle 审计通过：所有 Mach-O 仅含 arm64。"
