import Foundation
import Darwin

/// 一个可注入的 launchctl 命令，避免生命周期逻辑必须操作当前用户的真实服务。
public struct LaunchAgentCommand: Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL?

    public init(executable: String, arguments: [String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct LaunchAgentCommandResult: Equatable {
    public let status: Int32
    public let output: String
    public let didExecute: Bool

    public init(status: Int32, output: String = "", didExecute: Bool = true) {
        self.status = status
        self.output = output
        self.didExecute = didExecute
    }

    public var succeeded: Bool { didExecute && status == 0 }
}

public enum LaunchAgentLoadState: String, Equatable {
    case loaded
    case notLoaded
    case unavailable
}

/// LaunchAgent 中与用户配置相关的值。服务是否启用由 enable/disable 事务决定，
/// 不由 organizationMode 推导。
public struct LaunchAgentConfiguration: Equatable, Sendable {
    public let configURL: URL
    public let watchPath: URL
    public let startIntervalSeconds: Int?

    public init(configURL: URL, watchPath: URL, startIntervalSeconds: Int? = nil) {
        self.configURL = configURL.standardizedFileURL
        self.watchPath = watchPath.standardizedFileURL
        self.startIntervalSeconds = startIntervalSeconds
    }

    public var configPath: String { configURL.path }

    public var watchPaths: [URL] {
        [watchPath, configURL]
    }

    public var watchPathStrings: [String] {
        watchPaths.map(\.path)
    }

    public var workingDirectory: URL {
        configURL.deletingLastPathComponent()
    }

    public var logsDirectory: URL {
        workingDirectory.appendingPathComponent("logs", isDirectory: true)
    }
}

public enum LaunchAgentManagerError: Error, LocalizedError {
    case fixedApplicationMissing(URL)
    case agentMissing(URL)
    case agentNotExecutable(URL)
    case configMissing(URL)
    case configUnreadable(URL)
    case watchFolderMissing(URL)
    case watchFolderNotDirectory(URL)
    case watchFolderNotReadable(URL)
    case watchFolderNotWritable(URL)
    case directoryUnavailable(URL)
    case directoryNotReadable(URL)
    case directoryNotWritable(URL)
    case plistUnreadable(URL)
    case invalidStartInterval(Int)
    case invalidPlist(String)
    case serviceProbeUnavailable(String)
    case commandFailed(action: String, status: Int32, output: String)
    case serviceStillLoaded
    case plistDeletionFailed(URL, reason: String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .fixedApplicationMissing(url):
            return "找不到固定位置的应用：\(url.path)"
        case let .agentMissing(url):
            return "找不到应用内后台组件：\(url.path)"
        case let .agentNotExecutable(url):
            return "应用内后台组件不可执行：\(url.path)"
        case let .configMissing(url):
            return "找不到后台服务配置：\(url.path)"
        case let .configUnreadable(url):
            return "无法读取后台服务配置：\(url.path)"
        case let .watchFolderMissing(url):
            return "找不到监听目录：\(url.path)"
        case let .watchFolderNotDirectory(url):
            return "监听路径不是目录：\(url.path)"
        case let .watchFolderNotReadable(url):
            return "监听目录不可读：\(url.path)"
        case let .watchFolderNotWritable(url):
            return "监听目录不可写：\(url.path)"
        case let .directoryUnavailable(url):
            return "无法准备目录：\(url.path)"
        case let .directoryNotReadable(url):
            return "目录不可读：\(url.path)"
        case let .directoryNotWritable(url):
            return "目录不可写：\(url.path)"
        case let .plistUnreadable(url):
            return "无法读取现有 LaunchAgent 配置：\(url.path)"
        case let .invalidStartInterval(value):
            return "StartInterval 无效：\(value)"
        case let .invalidPlist(detail):
            return "LaunchAgent plist 校验失败：\(detail)"
        case let .serviceProbeUnavailable(detail):
            return "无法确认后台服务当前状态：\(detail)"
        case let .commandFailed(action, status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "后台服务\(action)失败（\(status)）：\(detail.isEmpty ? "没有返回详细错误" : detail)"
        case .serviceStillLoaded:
            return "后台服务停止后仍显示为已加载"
        case let .plistDeletionFailed(url, reason):
            return "删除 LaunchAgent 配置失败：\(url.path)（\(reason)）"
        case let .rollbackFailed(reason):
            return "关闭后台服务后恢复原状态失败：\(reason)"
        }
    }
}

public struct LaunchAgentInspection {
    public let plistExists: Bool
    public let plistReadable: Bool
    public let plist: [String: Any]
    public let loadState: LaunchAgentLoadState
    public let launchctlOutput: String
    public let launchctlError: String?
    public let agentAvailable: Bool
    public let agentError: String?
    public let matchesConfiguration: Bool?
    public let labelMatches: Bool?
    public let argumentsMatch: Bool?
    public let configPathMatches: Bool?
    public let watchPathsMatch: Bool?
    public let startIntervalMatches: Bool?

    public var loaded: Bool { loadState == .loaded }

    public var serviceProbeSucceeded: Bool {
        loadState != .unavailable
    }

    /// 供 v9 配置迁移使用：旧配置只根据 plist 是否存在或服务是否已加载判断。
    public var legacyAutomationStateObservation: LegacyAutomationStateObservation {
        LegacyAutomationStateObservation(
            plistExists: plistExists,
            serviceLoaded: loaded,
            serviceProbeSucceeded: serviceProbeSucceeded
        )
    }
}

/// `disableTransaction()` 开始时保存的服务状态和完整 plist 快照。
///
/// AppModel 的 SorterConfig 快照仍由调用方自己保存；这里的
/// `originalConfiguration` 是本次 LaunchAgent 配置上下文，供回滚诊断和
/// 调用方在恢复配置时使用。
public struct LaunchAgentDisableSnapshot {
    public let before: LaunchAgentInspection
    public let plistData: Data?
    public let originalConfiguration: LaunchAgentConfiguration?

    public init(
        before: LaunchAgentInspection,
        plistData: Data?,
        originalConfiguration: LaunchAgentConfiguration? = nil
    ) {
        self.before = before
        self.plistData = plistData
        self.originalConfiguration = originalConfiguration
    }

    public var serviceWasLoaded: Bool {
        before.loadState == .loaded
    }

    public var plistExisted: Bool {
        before.plistExists
    }
}

/// `disableTransaction()` 的结果必须让调用方区分“已关闭”和“关闭失败但原状态已恢复”。
public enum LaunchAgentDisableOutcome: String, Equatable {
    case closedSuccessfully = "closed_successfully"
    case failedButRestored = "failed_but_restored"
    case failedAndRestoreFailed = "failed_and_restore_failed"
}

public struct LaunchAgentDisableResult {
    public let outcome: LaunchAgentDisableOutcome
    public let before: LaunchAgentInspection
    public let after: LaunchAgentInspection
    public let snapshot: LaunchAgentDisableSnapshot
    public let failure: LaunchAgentManagerError?
    public let restorationFailure: LaunchAgentManagerError?

    public var succeeded: Bool {
        outcome == .closedSuccessfully
    }

    public var wasRestored: Bool {
        outcome == .failedButRestored
    }

    public var shouldKeepAutomationEnabled: Bool {
        outcome != .closedSuccessfully
    }

    public var error: LaunchAgentManagerError? {
        restorationFailure ?? failure
    }
}

public final class LaunchAgentManager: @unchecked Sendable {
    public typealias CommandExecutor = (LaunchAgentCommand) -> LaunchAgentCommandResult
    public typealias ItemRemover = (URL) throws -> Void
    public typealias Configuration = LaunchAgentConfiguration
    public typealias Inspection = LaunchAgentInspection

    public static let serviceLabel = "com.ai.filesorter"
    public static let launchctlPath = "/bin/launchctl"
    public static let defaultFixedApplicationURL = URL(
        fileURLWithPath: "/Applications/AI File Sorter.app",
        isDirectory: true
    )

    public let homeDirectory: URL
    public let fixedApplicationURL: URL
    public let agentURL: URL
    public let launchAgentsDirectory: URL
    public let launchAgentPlistURL: URL
    public let userID: UInt32

    // 与 AppModel 现有命名保持兼容；这些路径仍全部由固定 App 和注入 HOME 派生。
    public var fixedAppURL: URL { fixedApplicationURL }
    public var launchAgentURL: URL { agentURL }
    public var plistURL: URL { launchAgentPlistURL }

    private let fileManager: FileManager
    private let commandExecutor: CommandExecutor
    private let itemRemover: ItemRemover

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fixedApplicationURL: URL = URL(fileURLWithPath: "/Applications/AI File Sorter.app", isDirectory: true),
        userID: UInt32? = nil,
        fileManager: FileManager = .default,
        commandExecutor: CommandExecutor? = nil,
        itemRemover: ItemRemover? = nil
    ) {
        let normalizedHome = homeDirectory.standardizedFileURL
        let normalizedApp = fixedApplicationURL.standardizedFileURL
        self.homeDirectory = normalizedHome
        self.fixedApplicationURL = normalizedApp
        self.agentURL = normalizedApp
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent("com.ai.filesorter.agent")
        self.launchAgentsDirectory = normalizedHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.launchAgentPlistURL = normalizedHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.serviceLabel + ".plist")
        self.userID = userID ?? UInt32(getuid())
        self.fileManager = fileManager
        self.commandExecutor = commandExecutor ?? Self.runCommand
        self.itemRemover = itemRemover ?? { url in
            try fileManager.removeItem(at: url)
        }
    }

    public func makeConfiguration(
        configURL: URL,
        watchPath: URL,
        startIntervalSeconds: Int? = nil
    ) -> LaunchAgentConfiguration {
        LaunchAgentConfiguration(
            configURL: configURL,
            watchPath: watchPath,
            startIntervalSeconds: startIntervalSeconds
        )
    }

    public func makeConfiguration(
        configURL: URL,
        watchPath: String,
        startIntervalSeconds: Int? = nil
    ) -> LaunchAgentConfiguration {
        makeConfiguration(
            configURL: configURL,
            watchPath: URL(fileURLWithPath: NSString(string: watchPath).expandingTildeInPath),
            startIntervalSeconds: startIntervalSeconds
        )
    }

    /// 只读取 plist 并探测服务，不会写入 LaunchAgents，也不会 bootstrap/bootout。
    public func inspect(
        configuration: LaunchAgentConfiguration? = nil
    ) -> LaunchAgentInspection {
        let plistExists = fileManager.fileExists(atPath: launchAgentPlistURL.path)
        var plist: [String: Any] = [:]
        var plistReadable = !plistExists
        if plistExists,
           let data = try? Data(contentsOf: launchAgentPlistURL),
           let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = decoded
            plistReadable = true
        }

        let commandResult = commandExecutor(
            LaunchAgentCommand(
                executable: Self.launchctlPath,
                arguments: ["print", serviceDomain]
            )
        )
        let loadState = Self.loadState(for: commandResult)
        let agentAvailable = fileManager.isExecutableFile(atPath: agentURL.path)
        let agentError: String?
        if !fileManager.fileExists(atPath: agentURL.path) {
            agentError = "固定应用内找不到可执行整理组件：\(agentURL.path)"
        } else if !agentAvailable {
            agentError = "固定应用内整理组件没有执行权限：\(agentURL.path)"
        } else {
            agentError = nil
        }

        let comparison = configuration.map {
            compare(plist: plist, readable: plistReadable, with: $0)
        }
        return LaunchAgentInspection(
            plistExists: plistExists,
            plistReadable: plistReadable,
            plist: plist,
            loadState: loadState,
            launchctlOutput: commandResult.output,
            launchctlError: Self.launchctlError(for: commandResult, loadState: loadState),
            agentAvailable: agentAvailable,
            agentError: agentError,
            matchesConfiguration: comparison?.matches,
            labelMatches: comparison?.label,
            argumentsMatch: comparison?.arguments,
            configPathMatches: comparison?.configPath,
            watchPathsMatch: comparison?.watchPaths,
            startIntervalMatches: comparison?.startInterval
        )
    }

    /// 生成固定格式的 plist 数据，不写磁盘、不执行 launchctl。
    public func plistData(for configuration: LaunchAgentConfiguration) throws -> Data {
        let plist = try plistDictionary(for: configuration)
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        } catch {
            throw LaunchAgentManagerError.invalidPlist(error.localizedDescription)
        }
        try validatePlist(data, for: configuration)
        return data
    }

    /// 返回将要写入的 Foundation plist 字典，便于纯逻辑测试和自检展示。
    public func plistDictionary(for configuration: LaunchAgentConfiguration) throws -> [String: Any] {
        guard let interval = configuration.startIntervalSeconds else {
            return basePlist(for: configuration)
        }
        guard interval >= 0 else {
            throw LaunchAgentManagerError.invalidStartInterval(interval)
        }
        var plist = basePlist(for: configuration)
        if interval > 0 {
            plist["StartInterval"] = interval
        }
        return plist
    }

    public func validatePlist(
        _ data: Data,
        for configuration: LaunchAgentConfiguration
    ) throws {
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw LaunchAgentManagerError.invalidPlist(error.localizedDescription)
        }
        guard let dictionary = propertyList as? [String: Any] else {
            throw LaunchAgentManagerError.invalidPlist("顶层不是字典")
        }
        try validatePlist(dictionary, for: configuration)
    }

    public func validatePlist(
        _ plist: [String: Any],
        for configuration: LaunchAgentConfiguration
    ) throws {
        let expected = try plistDictionary(for: configuration)
        let expectedArguments = expected["ProgramArguments"] as? [String] ?? []
        let actualArguments = plist["ProgramArguments"] as? [String] ?? []
        guard plist["Label"] as? String == Self.serviceLabel else {
            throw LaunchAgentManagerError.invalidPlist("Label 不匹配")
        }
        guard actualArguments == expectedArguments else {
            throw LaunchAgentManagerError.invalidPlist("ProgramArguments 不匹配")
        }
        guard (plist["RunAtLoad"] as? Bool) == true else {
            throw LaunchAgentManagerError.invalidPlist("RunAtLoad 必须为 true")
        }
        let actualWatchPaths = (plist["WatchPaths"] as? [String] ?? []).sorted()
        let expectedWatchPaths = (expected["WatchPaths"] as? [String] ?? []).sorted()
        guard actualWatchPaths == expectedWatchPaths else {
            throw LaunchAgentManagerError.invalidPlist("WatchPaths 不匹配")
        }
        guard plist["WorkingDirectory"] as? String == expected["WorkingDirectory"] as? String else {
            throw LaunchAgentManagerError.invalidPlist("WorkingDirectory 不匹配")
        }
        guard plist["ProcessType"] as? String == "Background" else {
            throw LaunchAgentManagerError.invalidPlist("ProcessType 不匹配")
        }
        guard (plist["ThrottleInterval"] as? NSNumber)?.intValue == 5 else {
            throw LaunchAgentManagerError.invalidPlist("ThrottleInterval 不匹配")
        }

        let expectedInterval = (expected["StartInterval"] as? NSNumber)?.intValue
        let actualInterval = (plist["StartInterval"] as? NSNumber)?.intValue
        if let expectedInterval {
            guard actualInterval == expectedInterval else {
                throw LaunchAgentManagerError.invalidPlist("StartInterval 不匹配")
            }
        } else {
            guard plist["StartInterval"] == nil else {
                throw LaunchAgentManagerError.invalidPlist("不应设置 StartInterval")
            }
        }
        guard plist["StandardOutPath"] as? String == expected["StandardOutPath"] as? String,
              plist["StandardErrorPath"] as? String == expected["StandardErrorPath"] as? String else {
            throw LaunchAgentManagerError.invalidPlist("日志路径不匹配")
        }
    }

    /// 原子写入 plist、bootstrap，并在成功后再次检查服务加载和配置一致性。
    @discardableResult
    public func enable(
        _ configuration: LaunchAgentConfiguration
    ) throws -> LaunchAgentInspection {
        try validateEnableInputs(configuration)
        let before = inspect(configuration: configuration)
        guard before.loadState != .unavailable else {
            throw LaunchAgentManagerError.serviceProbeUnavailable(
                before.launchctlError ?? "launchctl print 无法执行"
            )
        }

        let previousPlistData: Data?
        if before.plistExists {
            guard before.plistReadable,
                  let data = try? Data(contentsOf: launchAgentPlistURL) else {
                throw LaunchAgentManagerError.plistUnreadable(launchAgentPlistURL)
            }
            previousPlistData = data
        } else {
            previousPlistData = nil
        }
        let newPlistData = try plistData(for: configuration)

        do {
            try ensureDirectory(at: launchAgentsDirectory)
            try ensureDirectory(at: configuration.logsDirectory)
            try newPlistData.write(to: launchAgentPlistURL, options: .atomic)

            if before.loaded {
                let bootout = runBootout()
                guard bootout.succeeded else {
                    throw LaunchAgentManagerError.commandFailed(
                        action: "卸载",
                        status: bootout.status,
                        output: bootout.output
                    )
                }
            }

            let bootstrap = runBootstrap()
            guard bootstrap.succeeded else {
                throw LaunchAgentManagerError.commandFailed(
                    action: "加载",
                    status: bootstrap.status,
                    output: bootstrap.output
                )
            }

            let after = inspect(configuration: configuration)
            guard after.loaded else {
                throw LaunchAgentManagerError.serviceProbeUnavailable(
                    after.launchctlError ?? "bootstrap 后服务未显示为已加载"
                )
            }
            guard after.matchesConfiguration == true else {
                throw LaunchAgentManagerError.invalidPlist("bootstrap 后配置检查不一致")
            }
            return after
        } catch {
            rollback(
                previousPlistData: previousPlistData,
                serviceWasLoaded: before.loaded
            )
            throw error
        }
    }

    /// `bootstrap` 是 enable 的语义别名，保留给调用方表达 LaunchAgent 操作名称。
    @discardableResult
    public func bootstrap(
        _ configuration: LaunchAgentConfiguration
    ) throws -> LaunchAgentInspection {
        try enable(configuration)
    }

    /// 执行关闭事务并返回结构化结果。
    ///
    /// 事务开始时保存服务加载状态和原始 plist（即 LaunchAgent 的完整配置快照）。
    /// 任何 bootout、删除或最终状态校验失败都会尝试恢复这份快照；原服务若曾加载，
    /// 且当前已不再加载，则会用原 plist 重新 bootstrap，并再次验证加载状态。
    @discardableResult
    public func disableTransaction(
        configuration: LaunchAgentConfiguration? = nil
    ) -> LaunchAgentDisableResult {
        let before = inspect()
        let originalPlistData: Data? = before.plistExists
            ? try? Data(contentsOf: launchAgentPlistURL)
            : nil
        let snapshot = DisableSnapshot(
            before: before,
            plistData: originalPlistData,
            originalConfiguration: configuration
        )

        if before.plistExists && originalPlistData == nil {
            let failure = LaunchAgentManagerError.plistUnreadable(launchAgentPlistURL)
            return makeDisableResult(
                outcome: .failedButRestored,
                snapshot: snapshot,
                after: inspect(),
                failure: failure,
                restorationFailure: nil
            )
        }

        guard before.loadState != .unavailable else {
            let failure = LaunchAgentManagerError.serviceProbeUnavailable(
                before.launchctlError ?? "关闭前无法确认服务状态"
            )
            return makeDisableResult(
                outcome: .failedButRestored,
                snapshot: snapshot,
                after: inspect(),
                failure: failure,
                restorationFailure: nil
            )
        }

        do {
            if snapshot.serviceWasLoaded {
                let bootout = runBootout()
                guard bootout.succeeded else {
                    throw LaunchAgentManagerError.commandFailed(
                        action: "卸载",
                        status: bootout.status,
                        output: bootout.output
                    )
                }
                try requireNotLoaded(inspect(), action: "bootout")
            }

            try removePlistIfPresent()
            let after = inspect()
            try requireNotLoaded(after, action: "关闭")
            guard !after.plistExists else {
                throw LaunchAgentManagerError.plistDeletionFailed(
                    launchAgentPlistURL,
                    reason: "关闭后 plist 仍然存在"
                )
            }
            return makeDisableResult(
                outcome: .closedSuccessfully,
                snapshot: snapshot,
                after: after,
                failure: nil,
                restorationFailure: nil
            )
        } catch let error as LaunchAgentManagerError {
            return restoreAfterDisableFailure(snapshot, failure: error)
        } catch {
            return restoreAfterDisableFailure(
                snapshot,
                failure: .rollbackFailed(error.localizedDescription)
            )
        }
    }

    /// 兼容现有调用方的 throwing 包装。需要展示准确失败状态的调用方应使用
    /// `disableTransaction()` 并根据 `outcome` 更新 UI/配置。
    @discardableResult
    public func disable() throws -> LaunchAgentInspection {
        let result = disableTransaction()
        guard result.succeeded else {
            throw result.restorationFailure ?? result.failure
                ?? LaunchAgentManagerError.rollbackFailed("关闭事务未完成")
        }
        return result.after
    }

    /// `bootout` 是 disable 的语义别名，包含删除 plist 的完整关闭事务。
    @discardableResult
    public func bootout() throws -> LaunchAgentInspection {
        try disable()
    }

    private var serviceDomain: String {
        "gui/\(userID)/\(Self.serviceLabel)"
    }

    private var userDomain: String {
        "gui/\(userID)"
    }

    private func basePlist(for configuration: LaunchAgentConfiguration) -> [String: Any] {
        let logs = configuration.logsDirectory
        return [
            "Label": Self.serviceLabel,
            "ProgramArguments": [agentURL.path, "--config", configuration.configPath],
            "RunAtLoad": true,
            "WatchPaths": configuration.watchPathStrings,
            "WorkingDirectory": configuration.workingDirectory.path,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": logs.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("launchd.err.log").path,
        ]
    }

    private func compare(
        plist: [String: Any],
        readable: Bool,
        with configuration: LaunchAgentConfiguration
    ) -> (matches: Bool, label: Bool, arguments: Bool, configPath: Bool, watchPaths: Bool, startInterval: Bool) {
        guard readable else {
            return (false, false, false, false, false, false)
        }
        let expected = (try? plistDictionary(for: configuration)) ?? [:]
        let label = plist["Label"] as? String == expected["Label"] as? String
        let arguments = plist["ProgramArguments"] as? [String] == expected["ProgramArguments"] as? [String]
        let actualArguments = plist["ProgramArguments"] as? [String] ?? []
        let configPath = actualArguments.count >= 3 && actualArguments[2] == configuration.configPath
        let watchPaths = (plist["WatchPaths"] as? [String] ?? []).sorted()
            == (expected["WatchPaths"] as? [String] ?? []).sorted()
        let expectedInterval = (expected["StartInterval"] as? NSNumber)?.intValue
        let actualInterval = (plist["StartInterval"] as? NSNumber)?.intValue
        let startInterval = expectedInterval == nil
            ? plist["StartInterval"] == nil
            : expectedInterval == actualInterval
        let fullyValid = (try? validatePlist(plist, for: configuration)) != nil
        return (
            fullyValid && label && arguments && configPath && watchPaths && startInterval,
            label,
            arguments,
            configPath,
            watchPaths,
            startInterval
        )
    }

    private func validateEnableInputs(_ configuration: LaunchAgentConfiguration) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: fixedApplicationURL.path, isDirectory: &isDirectory) else {
            throw LaunchAgentManagerError.fixedApplicationMissing(fixedApplicationURL)
        }
        guard isDirectory.boolValue else {
            throw LaunchAgentManagerError.fixedApplicationMissing(fixedApplicationURL)
        }
        guard fileManager.fileExists(atPath: agentURL.path) else {
            throw LaunchAgentManagerError.agentMissing(agentURL)
        }
        guard fileManager.isExecutableFile(atPath: agentURL.path) else {
            throw LaunchAgentManagerError.agentNotExecutable(agentURL)
        }
        guard fileManager.fileExists(atPath: configuration.configURL.path) else {
            throw LaunchAgentManagerError.configMissing(configuration.configURL)
        }
        guard fileManager.isReadableFile(atPath: configuration.configURL.path) else {
            throw LaunchAgentManagerError.configUnreadable(configuration.configURL)
        }

        var watchIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: configuration.watchPath.path, isDirectory: &watchIsDirectory) else {
            throw LaunchAgentManagerError.watchFolderMissing(configuration.watchPath)
        }
        guard watchIsDirectory.boolValue else {
            throw LaunchAgentManagerError.watchFolderNotDirectory(configuration.watchPath)
        }
        guard fileManager.isReadableFile(atPath: configuration.watchPath.path) else {
            throw LaunchAgentManagerError.watchFolderNotReadable(configuration.watchPath)
        }
        guard fileManager.isWritableFile(atPath: configuration.watchPath.path) else {
            throw LaunchAgentManagerError.watchFolderNotWritable(configuration.watchPath)
        }

        try validateWritableLocation(for: launchAgentsDirectory)
        try validateWritableLocation(for: configuration.workingDirectory)
        try validateWritableLocation(for: configuration.logsDirectory)
    }

    private func validateWritableLocation(for directory: URL) throws {
        guard let existing = nearestExistingDirectory(for: directory) else {
            throw LaunchAgentManagerError.directoryUnavailable(directory)
        }
        guard fileManager.isReadableFile(atPath: existing.path) else {
            throw LaunchAgentManagerError.directoryNotReadable(existing)
        }
        guard fileManager.isWritableFile(atPath: existing.path) else {
            throw LaunchAgentManagerError.directoryNotWritable(existing)
        }
    }

    private func nearestExistingDirectory(for directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    private func ensureDirectory(at directory: URL) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LaunchAgentManagerError.directoryUnavailable(directory)
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchAgentManagerError.directoryUnavailable(directory)
        }
    }

    private func runBootstrap() -> LaunchAgentCommandResult {
        commandExecutor(
            LaunchAgentCommand(
                executable: Self.launchctlPath,
                arguments: ["bootstrap", userDomain, launchAgentPlistURL.path]
            )
        )
    }

    private func runBootout() -> LaunchAgentCommandResult {
        commandExecutor(
            LaunchAgentCommand(
                executable: Self.launchctlPath,
                arguments: ["bootout", serviceDomain]
            )
        )
    }

    private typealias DisableSnapshot = LaunchAgentDisableSnapshot

    private func requireNotLoaded(
        _ inspection: LaunchAgentInspection,
        action: String
    ) throws {
        guard inspection.loadState == .notLoaded else {
            if inspection.loaded {
                throw LaunchAgentManagerError.serviceStillLoaded
            }
            throw LaunchAgentManagerError.serviceProbeUnavailable(
                inspection.launchctlError ?? "\(action) 后无法确认服务已停止"
            )
        }
    }

    private func removePlistIfPresent() throws {
        guard fileManager.fileExists(atPath: launchAgentPlistURL.path) else {
            return
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: launchAgentPlistURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw LaunchAgentManagerError.plistDeletionFailed(
                launchAgentPlistURL,
                reason: "目标不是普通 plist 文件"
            )
        }
        do {
            try itemRemover(launchAgentPlistURL)
        } catch {
            throw LaunchAgentManagerError.plistDeletionFailed(
                launchAgentPlistURL,
                reason: error.localizedDescription
            )
        }
        guard !fileManager.fileExists(atPath: launchAgentPlistURL.path) else {
            throw LaunchAgentManagerError.plistDeletionFailed(
                launchAgentPlistURL,
                reason: "删除后文件仍然存在"
            )
        }
    }

    private func restoreAfterDisableFailure(
        _ snapshot: DisableSnapshot,
        failure: LaunchAgentManagerError
    ) -> LaunchAgentDisableResult {
        do {
            try restorePlist(from: snapshot)

            var current = inspect()
            if snapshot.serviceWasLoaded {
                if !current.loaded {
                    let bootstrap = runBootstrap()
                    current = inspect()
                    if !current.loaded {
                        if !bootstrap.succeeded {
                            throw LaunchAgentManagerError.commandFailed(
                                action: "恢复加载",
                                status: bootstrap.status,
                                output: bootstrap.output
                            )
                        }
                        throw LaunchAgentManagerError.serviceProbeUnavailable(
                            current.launchctlError ?? "恢复 bootstrap 后服务未显示为已加载"
                        )
                    }
                }
            } else if current.loaded {
                let bootout = runBootout()
                guard bootout.succeeded else {
                    let afterBootoutFailure = inspect()
                    guard afterBootoutFailure.loadState == .notLoaded else {
                        throw LaunchAgentManagerError.commandFailed(
                            action: "恢复卸载",
                            status: bootout.status,
                            output: bootout.output
                        )
                    }
                    current = afterBootoutFailure
                    return try finishRestoredDisableFailure(
                        snapshot,
                        failure: failure,
                        after: current
                    )
                }
                current = inspect()
                guard current.loadState == .notLoaded else {
                    throw LaunchAgentManagerError.commandFailed(
                        action: "恢复卸载",
                        status: bootout.status,
                        output: bootout.output
                    )
                }
            }

            let after = inspect()
            return try finishRestoredDisableFailure(
                snapshot,
                failure: failure,
                after: after
            )
        } catch let restorationError as LaunchAgentManagerError {
            return makeDisableResult(
                outcome: .failedAndRestoreFailed,
                snapshot: snapshot,
                after: inspect(),
                failure: failure,
                restorationFailure: restorationError
            )
        } catch {
            let restorationError = LaunchAgentManagerError.rollbackFailed(error.localizedDescription)
            return makeDisableResult(
                outcome: .failedAndRestoreFailed,
                snapshot: snapshot,
                after: inspect(),
                failure: failure,
                restorationFailure: restorationError
            )
        }
    }

    private func finishRestoredDisableFailure(
        _ snapshot: DisableSnapshot,
        failure: LaunchAgentManagerError,
        after: LaunchAgentInspection
    ) throws -> LaunchAgentDisableResult {
        try verifyDisableSnapshot(snapshot, after: after)
        return makeDisableResult(
            outcome: .failedButRestored,
            snapshot: snapshot,
            after: after,
            failure: failure,
            restorationFailure: nil
        )
    }

    private func restorePlist(from snapshot: DisableSnapshot) throws {
        if snapshot.plistExisted {
            guard let plistData = snapshot.plistData else {
                throw LaunchAgentManagerError.rollbackFailed("原始 plist 内容不可读取")
            }
            do {
                try ensureDirectory(at: launchAgentsDirectory)
                try plistData.write(to: launchAgentPlistURL, options: .atomic)
                guard let restoredData = try? Data(contentsOf: launchAgentPlistURL),
                      restoredData == plistData else {
                    throw LaunchAgentManagerError.rollbackFailed("原始 plist 内容写回后校验不一致")
                }
            } catch let error as LaunchAgentManagerError {
                throw error
            } catch {
                throw LaunchAgentManagerError.rollbackFailed(
                    "写回原始 plist 失败：\(error.localizedDescription)"
                )
            }
        } else if fileManager.fileExists(atPath: launchAgentPlistURL.path) {
            do {
                try itemRemover(launchAgentPlistURL)
            } catch {
                throw LaunchAgentManagerError.rollbackFailed(
                    "移除事务期间生成的 plist 失败：\(error.localizedDescription)"
                )
            }
        }
    }

    private func verifyDisableSnapshot(
        _ snapshot: DisableSnapshot,
        after: LaunchAgentInspection
    ) throws {
        guard after.plistExists == snapshot.before.plistExists else {
            throw LaunchAgentManagerError.rollbackFailed("原始 plist 存在状态未恢复")
        }
        if snapshot.before.plistExists {
            guard let plistData = snapshot.plistData else {
                throw LaunchAgentManagerError.rollbackFailed("原始 plist 内容不可读取")
            }
            guard let restoredData = try? Data(contentsOf: launchAgentPlistURL),
                  restoredData == plistData else {
                throw LaunchAgentManagerError.rollbackFailed("原始 plist 内容未恢复")
            }
        }
        switch snapshot.before.loadState {
        case .loaded:
            guard after.loadState == .loaded else {
                throw LaunchAgentManagerError.rollbackFailed("原服务未恢复为已加载")
            }
        case .notLoaded:
            guard after.loadState == .notLoaded else {
                throw LaunchAgentManagerError.rollbackFailed("原服务未恢复为未加载")
            }
        case .unavailable:
            throw LaunchAgentManagerError.rollbackFailed("原服务状态不可确认")
        }
    }

    private func makeDisableResult(
        outcome: LaunchAgentDisableOutcome,
        snapshot: DisableSnapshot,
        after: LaunchAgentInspection,
        failure: LaunchAgentManagerError?,
        restorationFailure: LaunchAgentManagerError?
    ) -> LaunchAgentDisableResult {
        LaunchAgentDisableResult(
            outcome: outcome,
            before: snapshot.before,
            after: after,
            snapshot: snapshot,
            failure: failure,
            restorationFailure: restorationFailure
        )
    }

    private func rollback(previousPlistData: Data?, serviceWasLoaded: Bool) {
        _ = runBootout()
        if let previousPlistData {
            try? previousPlistData.write(to: launchAgentPlistURL, options: .atomic)
            if serviceWasLoaded {
                _ = runBootstrap()
            }
        } else if fileManager.fileExists(atPath: launchAgentPlistURL.path) {
            try? fileManager.removeItem(at: launchAgentPlistURL)
        }
    }

    private static func loadState(for result: LaunchAgentCommandResult) -> LaunchAgentLoadState {
        guard result.didExecute else { return .unavailable }
        if result.status == 0 { return .loaded }
        return isServiceNotLoaded(result) ? .notLoaded : .unavailable
    }

    private static func isServiceNotLoaded(_ result: LaunchAgentCommandResult) -> Bool {
        guard result.didExecute, result.status != 0 else { return false }
        let output = result.output.lowercased()
        let markers = [
            "could not find service",
            "service not found",
            "unknown service",
            "no such process",
            "not loaded",
            "couldn't find service",
        ]
        return markers.contains(where: output.contains)
    }

    private static func launchctlError(
        for result: LaunchAgentCommandResult,
        loadState: LaunchAgentLoadState
    ) -> String? {
        switch loadState {
        case .loaded:
            return nil
        case .notLoaded:
            return nil
        case .unavailable:
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "launchctl 无法确认服务状态" : detail
        }
    }

    private static func runCommand(_ command: LaunchAgentCommand) -> LaunchAgentCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return LaunchAgentCommandResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return LaunchAgentCommandResult(
                status: 1,
                output: error.localizedDescription,
                didExecute: false
            )
        }
    }
}
