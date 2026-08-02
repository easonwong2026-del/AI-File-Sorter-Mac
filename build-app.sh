#!/bin/bash
# 构建原生 SwiftUI .app，并把带固定身份的原生 Agent 放入 App 固定位置。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/artifacts"
APP_PATH="$OUTPUT_DIR/AI File Sorter.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/mac-app/Info.plist")"
ZIP_PATH="$OUTPUT_DIR/AI-File-Sorter-Mac-Apple-Silicon-v$VERSION.zip"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-file-sorter-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "找不到 Swift 编译器，请先运行 xcode-select --install。"
    exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "仅支持在 Apple Silicon arm64 主机上构建此版本。"
    exit 1
fi

# 某些 macOS 同时保留多个 SDK；兼容 CommandLineTools、Xcode 以及 GitHub-hosted runner 的目录布局。
SDK_PATH=""
if XCODE_ROOT="$(xcode-select -p 2>/dev/null)"; then
    for SDK_ROOT in \
        "$XCODE_ROOT/SDKs" \
        "$XCODE_ROOT/Platforms/MacOSX.platform/Developer/SDKs" \
        "$XCODE_ROOT/Toolchains/XcodeDefault.xctoolchain/SDKs"; do
        if [ -d "$SDK_ROOT" ]; then
            SDK_PATH="$(find "$SDK_ROOT" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort | head -1)"
            [ -n "$SDK_PATH" ] && break
        fi
    done
fi
if [ -z "$SDK_PATH" ]; then
    SDK_PATH="$(find /Applications -path '*/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk' -type d 2>/dev/null | sort | head -1)"
fi
if [ -z "$SDK_PATH" ] && command -v xcrun >/dev/null 2>&1; then
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    echo "找不到 macOS SDK，请确认已安装 Xcode Command Line Tools 或 Xcode。"
    exit 1
fi
MODULE_CACHE="$BUILD_DIR/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE"

# 只构建 Apple Silicon arm64；不生成 Intel 或 Universal 中间产物。
APP_SOURCES=(
    "$PROJECT_DIR/mac-app/Sources/App/AIFileSorterApplication.swift"
    "$PROJECT_DIR/mac-app/Sources/App/WelcomeAndMain.swift"
    "$PROJECT_DIR/mac-app/Sources/Core/FileAssessmentTypes.swift"
    "$PROJECT_DIR/mac-app/Sources/Core/AssessmentTimestamp.swift"
    "$PROJECT_DIR/mac-app/Sources/Models/SorterModels.swift"
    "$PROJECT_DIR/mac-app/Sources/Services/LaunchAgentManager.swift"
    "$PROJECT_DIR/mac-app/Sources/Services/AppModel.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/SharedViews.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/OverviewView.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/InboxView.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/OrganizingPlanView.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/RulesView.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/HistoryView.swift"
    "$PROJECT_DIR/mac-app/Sources/Views/SidebarView.swift"
)

swiftc -swift-version 5 -Osize -parse-as-library -sdk "$SDK_PATH" -target "arm64-apple-macosx13.0" \
    -framework SwiftUI -framework AppKit -framework QuickLookUI \
    "${APP_SOURCES[@]}" -o "$BUILD_DIR/AIFileSorter"
swiftc -swift-version 5 -Osize -sdk "$SDK_PATH" -target "arm64-apple-macosx13.0" \
    -framework CryptoKit \
    "$PROJECT_DIR/mac-app/Sources/Core/FileAssessmentTypes.swift" \
    "$PROJECT_DIR/mac-app/Sources/Core/AssessmentTimestamp.swift" \
    "$PROJECT_DIR/mac-app/Sources/Agent/AIFileSorterAgent.swift" -o "$BUILD_DIR/AIFileSorterAgent"

swiftc -swift-version 5 -sdk "$SDK_PATH" -target "arm64-apple-macosx13.0" \
    -framework AppKit "$PROJECT_DIR/mac-app/Tools/IconMaker.swift" -o "$BUILD_DIR/IconMaker"
"$BUILD_DIR/IconMaker" "$BUILD_DIR/AppIcon.iconset"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources/Engine" "$APP_PATH/Contents/Library/LaunchServices"
cp "$BUILD_DIR/AIFileSorter" "$APP_PATH/Contents/MacOS/AIFileSorter"
cp "$PROJECT_DIR/mac-app/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.iconset/icon_512x512@2x.png" "$APP_PATH/Contents/Resources/AppIcon.png"
cp "$BUILD_DIR/AIFileSorterAgent" "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"

cp "$PROJECT_DIR/config.json" "$APP_PATH/Contents/Resources/Engine/config.json"

chmod +x "$APP_PATH/Contents/MacOS/AIFileSorter" "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"
# 发布包不携带未使用的调试符号，减少 App 体积；不影响运行日志和崩溃报告地址。
strip -S "$APP_PATH/Contents/MacOS/AIFileSorter" "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent"
# 即使开发构建使用临时签名，后台组件也保持固定的反向域名标识；正式发布时替换为 Developer ID。
codesign --force --sign - --identifier "com.ai.filesorter.agent" "$APP_PATH/Contents/Library/LaunchServices/com.ai.filesorter.agent" >/dev/null
codesign --force --deep --sign - "$APP_PATH" >/dev/null
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "构建完成：$APP_PATH"
echo "压缩包：$ZIP_PATH"
