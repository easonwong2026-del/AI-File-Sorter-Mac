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
        try Data("agent".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        enum HarnessError: Error {
            case removalDenied
        }

        var loaded = false
        var failBootstrap = false
        var failBootout = false
        var failRemoval = false
        var bootstrapCount = 0
        var bootoutCount = 0
        let executor: LaunchAgentManager.CommandExecutor = { command in
            switch command.arguments.first {
            case "print":
                return loaded
                    ? LaunchAgentCommandResult(status: 0, output: "service loaded")
                    : LaunchAgentCommandResult(status: 1, output: "Could not find service")
            case "bootstrap":
                bootstrapCount += 1
                if failBootstrap {
                    return LaunchAgentCommandResult(status: 1, output: "bootstrap permission denied")
                }
                loaded = true
                return LaunchAgentCommandResult(status: 0, output: "")
            case "bootout":
                bootoutCount += 1
                if failBootout {
                    return LaunchAgentCommandResult(status: 1, output: "bootout permission denied")
                }
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

        let logsDirectory = configURL.deletingLastPathComponent()
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let configBytes = Data(#"{"sentinel":"config"}"#.utf8)
        let historyURL = logsDirectory.appendingPathComponent("history.json")
        let stateURL = logsDirectory.appendingPathComponent("state.json")
        let historyBytes = Data(#"{"sentinel":"history"}"#.utf8)
        let stateBytes = Data(#"{"sentinel":"state"}"#.utf8)
        try configBytes.write(to: configURL)
        try historyBytes.write(to: historyURL)
        try stateBytes.write(to: stateURL)

        let itemRemover: LaunchAgentManager.ItemRemover = { url in
            if failRemoval {
                throw HarnessError.removalDenied
            }
            try FileManager.default.removeItem(at: url)
        }

        func checkUserDataIsIntact(_ context: String) throws {
            let currentConfig = try Data(contentsOf: configURL)
            let currentHistory = try Data(contentsOf: historyURL)
            let currentState = try Data(contentsOf: stateURL)
            check(currentConfig == configBytes, "\(context)：config 不应被修改")
            check(currentHistory == historyBytes, "\(context)：history 不应被删除或修改")
            check(currentState == stateBytes, "\(context)：state 不应被删除或修改")
        }

        let managedManager = LaunchAgentManager(
            homeDirectory: home,
            fixedApplicationURL: app,
            userID: 501,
            commandExecutor: executor,
            itemRemover: itemRemover
        )

        _ = try managedManager.enable(configuration)
        check(loaded, "enable 应 bootstrap 服务")
        check(FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "enable 应生成 plist")
        let plistData = try Data(contentsOf: managedManager.launchAgentPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        check((plist["StartInterval"] as? NSNumber)?.intValue == 3600, "StartInterval 应与配置一致")

        // bootout 成功但 plist remove 失败：原服务必须自动恢复为 loaded，且原 plist 保留。
        bootstrapCount = 0
        bootoutCount = 0
        failRemoval = true
        let removeFailure = managedManager.disableTransaction(configuration: configuration)
        check(removeFailure.outcome == .failedButRestored, "remove 失败且恢复成功应返回结构化结果")
        check(removeFailure.wasRestored, "remove 失败后应标记为已恢复")
        check(removeFailure.snapshot.originalConfiguration == configuration, "关闭事务应保存原配置快照")
        check(loaded && removeFailure.after.loaded, "remove 失败后原服务应恢复为 loaded")
        check(bootstrapCount == 1, "bootout 成功后恢复必须重新 bootstrap 原服务")
        check(FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "恢复成功时原 plist 必须保留")
        let restoredPlist = try Data(contentsOf: managedManager.launchAgentPlistURL)
        check(restoredPlist == plistData, "恢复成功时 plist 内容必须与原始快照一致")
        try checkUserDataIsIntact("remove 失败恢复")

        // bootout 失败：不得删除 plist，且原 loaded 状态应保持。
        failRemoval = false
        failBootout = true
        bootstrapCount = 0
        let bootoutFailure = managedManager.disableTransaction(configuration: configuration)
        check(bootoutFailure.outcome == .failedButRestored, "bootout 失败且原状态保持时应返回恢复成功")
        check(bootoutFailure.failure != nil, "bootout 失败应保留原始错误")
        check(loaded && bootoutFailure.after.loaded, "bootout 失败后服务应仍为 loaded")
        check(FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "bootout 失败不得删除 plist")
        check(bootstrapCount == 0, "bootout 未改变 loaded 状态时不应重复 bootstrap")
        try checkUserDataIsIntact("bootout 失败恢复")

        // bootout 成功、remove 失败，但 rollback bootstrap 失败：必须准确报告恢复失败。
        failBootout = false
        failRemoval = true
        failBootstrap = true
        let rollbackFailure = managedManager.disableTransaction(configuration: configuration)
        check(rollbackFailure.outcome == .failedAndRestoreFailed, "rollback bootstrap 失败应返回恢复失败")
        check(rollbackFailure.restorationFailure != nil, "恢复失败应包含恢复错误")
        check(!loaded && !rollbackFailure.after.loaded, "恢复 bootstrap 失败时不得谎报服务已恢复")
        check(FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "恢复失败仍应保留原 plist 供后续恢复")
        let failedRestorePlist = try Data(contentsOf: managedManager.launchAgentPlistURL)
        check(failedRestorePlist == plistData, "恢复失败时仍应保留原始 plist 内容")
        try checkUserDataIsIntact("rollback bootstrap 失败")

        failBootstrap = false
        failRemoval = false
        _ = try managedManager.enable(configuration)
        check(loaded, "测试完整关闭前应重新启用服务")

        // 完整成功关闭：服务停止、plist 删除，用户配置/history/state 仍在。
        let successfulClose = managedManager.disableTransaction(configuration: configuration)
        check(successfulClose.outcome == .closedSuccessfully, "完整关闭应返回成功结果")
        check(!loaded && !successfulClose.after.loaded, "完整关闭应停止服务")
        check(!FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "完整关闭应删除 plist")
        try checkUserDataIsIntact("完整成功关闭")

        // 原服务未加载但 plist 存在：不应误 bootstrap，仍可安全完成关闭。
        let dormantPlist = try managedManager.plistData(for: configuration)
        try dormantPlist.write(to: managedManager.launchAgentPlistURL)
        bootoutCount = 0
        let dormantClose = managedManager.disableTransaction(configuration: configuration)
        check(dormantClose.outcome == .closedSuccessfully, "原未加载但 plist 存在时应成功关闭")
        check(!loaded && !dormantClose.after.loaded, "原未加载服务不应被 bootstrap")
        check(bootoutCount == 0, "原未加载服务不应执行 bootout")
        check(!FileManager.default.fileExists(atPath: managedManager.launchAgentPlistURL.path), "原未加载关闭后 plist 应删除")
        try checkUserDataIsIntact("原未加载但 plist 存在")

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
        _ = try managedManager.enable(configuration)
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
