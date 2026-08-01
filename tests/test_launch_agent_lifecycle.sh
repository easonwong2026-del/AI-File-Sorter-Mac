#!/bin/bash
# LaunchAgent 生命周期和配置迁移逻辑测试。
# 使用临时 HOME、临时 App 和注入的 launchctl 执行器，不接触真实 LaunchAgents。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "/tmp/ai-file-sorter-lifecycle-test.XXXXXX")"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
HARNESS="$ROOT/LifecycleHarness.swift"
EXECUTABLE="$ROOT/lifecycle-harness"
MODULE_CACHE="$ROOT/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE"

cat > "$HARNESS" <<'SWIFT'
import Foundation

@main
struct LifecycleHarness {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("失败：\(message)\n".utf8))
            exit(1)
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIFECYCLE_ROOT"]!)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let app = root.appendingPathComponent("AI File Sorter.app", isDirectory: true)
        let agent = app.appendingPathComponent("Contents/Library/LaunchServices/com.ai.filesorter.agent")
        let watch = root.appendingPathComponent("Downloads", isDirectory: true)
        let configURL = root.appendingPathComponent("Engine/config.json")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: configURL)
        try Data("agent".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        var loaded = false
        var failBootstrap = false
        let executor: LaunchAgentManager.CommandExecutor = { command in
            switch command.arguments.first {
            case "print":
                return loaded
                    ? LaunchAgentCommandResult(status: 0, output: "service loaded")
                    : LaunchAgentCommandResult(status: 1, output: "Could not find service")
            case "bootstrap":
                if failBootstrap {
                    return LaunchAgentCommandResult(status: 1, output: "bootstrap permission denied")
                }
                loaded = true
                return LaunchAgentCommandResult(status: 0, output: "")
            case "bootout":
                loaded = false
                return LaunchAgentCommandResult(status: 0, output: "")
            default:
                return LaunchAgentCommandResult(status: 1, output: "unexpected command")
            }
        }

        let manager = LaunchAgentManager(
            homeDirectory: home,
            fixedApplicationURL: app,
            userID: 501,
            commandExecutor: executor
        )
        let configuration = manager.makeConfiguration(
            configURL: configURL,
            watchPath: watch,
            startIntervalSeconds: 3600
        )

        _ = try manager.enable(configuration)
        check(loaded, "enable 应 bootstrap 服务")
        check(FileManager.default.fileExists(atPath: manager.launchAgentPlistURL.path), "enable 应生成 plist")
        let plistData = try Data(contentsOf: manager.launchAgentPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        check((plist["StartInterval"] as? NSNumber)?.intValue == 3600, "StartInterval 应与配置一致")

        _ = try manager.disable()
        check(!loaded, "disable 应 bootout 服务")
        check(!FileManager.default.fileExists(atPath: manager.launchAgentPlistURL.path), "disable 应删除 plist")

        let reinitialized = LaunchAgentManager(
            homeDirectory: home,
            fixedApplicationURL: app,
            userID: 501,
            commandExecutor: executor
        )
        let afterRestart = reinitialized.inspect(configuration: configuration)
        check(!afterRestart.plistExists && !afterRestart.loaded, "重新初始化后关闭状态不应恢复")

        failBootstrap = true
        do {
            _ = try reinitialized.enable(configuration)
            check(false, "bootstrap 失败不应报告 enable 成功")
        } catch { }
        check(!FileManager.default.fileExists(atPath: reinitialized.launchAgentPlistURL.path), "enable 失败应回滚新 plist")

        failBootstrap = false
        _ = try manager.enable(configuration)
        loaded = true
        let failingDisableExecutor: LaunchAgentManager.CommandExecutor = { command in
            if command.arguments.first == "print" {
                return LaunchAgentCommandResult(status: 0, output: "service loaded")
            }
            if command.arguments.first == "bootout" {
                return LaunchAgentCommandResult(status: 1, output: "permission denied")
            }
            return LaunchAgentCommandResult(status: 1, output: "unexpected command")
        }
        let failingDisable = LaunchAgentManager(
            homeDirectory: home,
            fixedApplicationURL: app,
            userID: 501,
            commandExecutor: failingDisableExecutor
        )
        do {
            _ = try failingDisable.disable()
            check(false, "bootout 失败不应报告 disable 成功")
        } catch { }
        check(FileManager.default.fileExists(atPath: failingDisable.launchAgentPlistURL.path), "关闭失败不得删除仍可能生效的 plist")

        let oldConfig = Data(#"{"_config_version":9,"organization_mode":"manual","watch_folder":"~/Downloads","rules":[]}"#.utf8)
        var decoded = try JSONDecoder().decode(SorterConfig.self, from: oldConfig)
        check(decoded.automationStateNeedsMigration, "v9 配置应触发一次性服务状态迁移")
        let result = decoded.migrateAutomationEnabled(using: LegacyAutomationStateObservation(
            plistExists: true,
            serviceLoaded: false,
            serviceProbeSucceeded: true
        ))
        if case let .migrated(enabled, _) = result {
            check(enabled, "存在旧 plist 时应迁移为启用")
        } else {
            check(false, "v9 配置迁移结果类型错误")
        }
        check(decoded.organizationMode == "manual", "迁移不得改变整理模式")
        check(!decoded.automationStateNeedsMigration, "迁移后不应重复迁移")

        print("LaunchAgent 生命周期与 v9→v10 迁移测试通过。")
    }
}
SWIFT

LIFECYCLE_ROOT="$ROOT" swiftc -swift-version 5 -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx13.0" \
    -framework SwiftUI -framework AppKit -framework QuickLookUI \
    "$PROJECT_DIR/mac-app/Sources/Core/FileAssessmentTypes.swift" \
    "$PROJECT_DIR/mac-app/Sources/Models/SorterModels.swift" \
    "$PROJECT_DIR/mac-app/Sources/Services/LaunchAgentManager.swift" \
    "$HARNESS" -o "$EXECUTABLE"

LIFECYCLE_ROOT="$ROOT" "$EXECUTABLE"
