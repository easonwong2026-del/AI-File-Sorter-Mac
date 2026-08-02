import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

enum AppServiceStatus: String {
    case notEnabled
    case running
    case scanning
    case awaitingConfirmation
    case organizing
    case stopping
    case paused
    case configNotSynced
    case permissionError
    case agentError

    var title: String {
        switch self {
        case .notEnabled: return "未启用"
        case .running: return "正常运行"
        case .scanning: return "扫描中"
        case .awaitingConfirmation: return "等待确认"
        case .organizing: return "整理中"
        case .stopping: return "正在停止"
        case .paused: return "已暂停"
        case .configNotSynced: return "配置不同步"
        case .permissionError: return "权限异常"
        case .agentError: return "整理服务错误"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .scanning, .awaitingConfirmation, .organizing: return true
        case .notEnabled, .stopping, .paused, .configNotSynced, .permissionError, .agentError: return false
        }
    }

    var detail: String {
        switch self {
        case .notEnabled: return "后台不会自动扫描或移动文件。"
        case .running: return "后台服务已加载，按当前方式工作。"
        case .scanning: return "正在读取文件状态。"
        case .awaitingConfirmation: return "整理建议已生成，等待你确认。"
        case .organizing: return "正在执行已确认的文件操作。"
        case .stopping: return "正在停止后台服务并移除 LaunchAgent。"
        case .paused: return "后台服务已暂停。"
        case .configNotSynced: return "服务配置与当前设置不一致。"
        case .permissionError: return "监听目录或目标目录权限异常。"
        case .agentError: return "原生整理引擎报告了错误。"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // 始终提供可编辑配置，资源部署失败时按钮也不会静默失效。
    @Published var config: SorterConfig = .fallback {
        didSet { updateUnsavedChanges() }
    }
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var runtimeState: SorterRuntimeState = .stopped
    @Published private(set) var serviceStatus: AppServiceStatus = .notEnabled
    @Published var busy = false
    @Published var message = "正在准备…"
    @Published var logText = "暂无日志"
    @Published var healthReport = "尚未检查"
    @Published var pendingFiles: [PendingFile] = []
    @Published private(set) var inboxSnapshot: FileAssessmentDocument?
    @Published private(set) var scanError: String?
    @Published var pendingMoveDraft: PendingMoveDraft?
    @Published var historyRecords: [MoveHistory] = []
    @Published var organizingPlan: [OrganizingPlanItem] = []
    @Published var showOrganizingPlan = false
    @Published var ruleTestFileName = "2026年7月_项目合同.pdf"
    @Published var ruleTestResult = "输入文件名后点击测试"
    @Published var ruleDiagnostics = "尚未检查规则"
    @Published var showQuitConfirmation = false

    /// 后台服务开关是持久化期望状态，与当前整理模式和运行状态分离。
    var automationEnabled: Bool { config.automationEnabled }

    var inboxFileCount: Int {
        inboxSnapshot?.items.count ?? pendingFiles.count
    }

    let applicationSupportDirectory: URL
    let engineDirectory: URL
    let configURL: URL
    let logsDirectory: URL
    let launchAgentManager: LaunchAgentManager
    private var recoveredFromBackup = false
    private let ignoredDefaultsKey = "ignoredUnmatchedSignatures"
    private let recentTargetsDefaultsKey = "recentTargetFolders"
    private var pendingWatchSource: DispatchSourceFileSystemObject?
    private var pendingWatchedPath = ""
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var savedConfigData = Data()
    private var lastAgentError = ""
    private var scanGeneration = 0
    private var statusGeneration = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI-File-Sorter-Mac", isDirectory: true)
        applicationSupportDirectory = base
        engineDirectory = base.appendingPathComponent("Engine", isDirectory: true)
        configURL = engineDirectory.appendingPathComponent("config.json")
        logsDirectory = engineDirectory.appendingPathComponent("logs", isDirectory: true)
        launchAgentManager = LaunchAgentManager()

        do {
            try deployEngine()
            try loadConfig()
            migrateLegacyAgentIfNeeded()
            captureSavedConfig()
            cleanupDisabledAutomationIfNeeded()
            cleanupLegacyAgentIfSafe()
            refreshStatus()
            refreshPendingFiles()
            startPendingWatcher()
            message = automationEnabled ? "后台服务已启用" : "后台服务尚未启用"
        } catch {
            message = "初始化失败：\(error.localizedDescription)"
        }
    }

    deinit {
        pendingRefreshWorkItem?.cancel()
        pendingWatchSource?.cancel()
    }

    private func deployEngine() throws {
        let manager = FileManager.default
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "AIFileSorter", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 App 资源目录"])
        }
        let bundledEngine = resources.appendingPathComponent("Engine", isDirectory: true)
        try manager.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        // 后台组件直接从固定的 App 包内运行，不再复制到 Application Support。
        // Application Support 仅保存用户配置、状态与日志，升级 App 时权限身份更稳定。
        for legacy in ["main.py", "sorter.py", "logger.py", "ai_classifier.py", "install.sh", "start.sh", "stop.sh"] {
            try? manager.removeItem(at: engineDirectory.appendingPathComponent(legacy))
        }

        if !manager.fileExists(atPath: configURL.path) {
            try manager.copyItem(at: bundledEngine.appendingPathComponent("config.json"), to: configURL)
        }
    }

    func loadConfig() throws {
        let decoder = JSONDecoder()
        do {
            config = try decoder.decode(SorterConfig.self, from: Data(contentsOf: configURL))
        } catch {
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json")
            guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
            config = try decoder.decode(SorterConfig.self, from: Data(contentsOf: backup))
            recoveredFromBackup = true
            message = "当前配置损坏，已从备份恢复"
        }

        if config.automationStateNeedsMigration {
            let observation = launchAgentManager.inspect().legacyAutomationStateObservation
            let migration = config.migrateAutomationEnabled(using: observation)
            if case let .migrated(enabled, usedSafeDefault) = migration {
                if let data = encodedConfig() {
                    try? data.write(to: configURL, options: .atomic)
                }
                message = usedSafeDefault
                    ? "旧配置未能确认后台服务状态，已安全迁移为关闭"
                    : (enabled ? "已根据现有后台服务迁移为启用" : "已将旧配置迁移为后台服务关闭")
            }
        }
    }

    private func migrateLegacyAgentIfNeeded() {
        guard config.automationEnabled else { return }
        let configuration = makeLaunchAgentConfiguration()
        let inspection = launchAgentManager.inspect(configuration: configuration)
        guard inspection.plistExists, inspection.argumentsMatch != true else { return }
        do {
            _ = try launchAgentManager.enable(configuration)
            message = "已将旧后台组件迁移到当前 App 内的 Apple Silicon Agent"
        } catch {
            lastAgentError = error.localizedDescription
            setServiceStatus(.agentError, detail: "旧后台组件迁移失败：\(error.localizedDescription)")
            message = "旧后台组件迁移失败：\(error.localizedDescription)"
        }
    }

    private func cleanupLegacyAgentIfSafe() {
        let legacy = engineDirectory.appendingPathComponent("AIFileSorterAgent")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let inspection = launchAgentManager.inspect()
        let arguments = inspection.plist["ProgramArguments"] as? [String] ?? []
        guard !arguments.contains(legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    private func encodedConfig() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(config)
    }

    private func captureSavedConfig() {
        savedConfigData = encodedConfig() ?? Data()
        hasUnsavedChanges = false
    }

    private func updateUnsavedChanges() {
        guard !savedConfigData.isEmpty else { return }
        hasUnsavedChanges = encodedConfig() != savedConfigData
    }

    func discardUnsavedChanges() {
        do {
            try loadConfig()
            captureSavedConfig()
            message = "已放弃未保存的修改"
        } catch {
            message = "无法恢复上次保存的设置：\(error.localizedDescription)"
        }
    }

    func saveCurrentConfiguration() -> Bool {
        do {
            try saveConfig()
            return true
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func ruleValidationIssues(for rule: SorterRule, at index: Int) -> [RuleValidationIssue] {
        var issues: [RuleValidationIssue] = []
        let label = "规则 \(index + 1)"
        if rule.keywords.isEmpty && rule.extensions.isEmpty && rule.nameRegex.isEmpty {
            issues.append(.init(text: "至少填写关键词、扩展名或名称正则之一", isError: true))
        }
        if !rule.nameRegex.isEmpty, (try? NSRegularExpression(pattern: rule.nameRegex, options: [.caseInsensitive])) == nil {
            issues.append(.init(text: "名称正则无效", isError: true))
        }
        if let minimum = rule.minimumSizeMB, let maximum = rule.maximumSizeMB, minimum > maximum {
            issues.append(.init(text: "最小文件大小不能大于最大文件大小", isError: true))
        }
        if [rule.minimumSizeMB, rule.maximumSizeMB].compactMap({ $0 }).contains(where: { $0 < 0 })
            || [rule.modifiedOlderThanDays, rule.modifiedNewerThanDays].compactMap({ $0 }).contains(where: { $0 < 0 }) {
            issues.append(.init(text: "文件大小和修改天数不能为负数", isError: true))
        }
        if rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(text: "需要选择目标文件夹", isError: true))
        } else {
            let watch = URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath).standardizedFileURL
            let target = URL(fileURLWithPath: NSString(string: rule.target).expandingTildeInPath).standardizedFileURL
            let watchPath = watch.path.hasSuffix("/") ? watch.path : watch.path + "/"
            if target == watch || target.path.hasPrefix(watchPath) {
                issues.append(.init(text: "目标不能位于监听文件夹内", isError: true))
            }
        }

        guard rule.enabled else { return issues }
        let priorRules = config.rules.prefix(index).filter(\.enabled)
        let keywords = Set(rule.keywords.map { $0.lowercased() })
        for prior in priorRules {
            let shared = keywords.intersection(prior.keywords.map { $0.lowercased() })
            let extensionsOverlap = rule.extensions.isEmpty || prior.extensions.isEmpty
                || !Set(rule.extensions.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
                    .isDisjoint(with: Set(prior.extensions.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }))
            if !shared.isEmpty && extensionsOverlap {
                issues.append(.init(text: "可能被前面的“\(prior.name)”优先命中（共享关键词：\(shared.sorted().joined(separator: "、"))）", isError: false))
                break
            }
        }
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(text: "\(label) 未命名，建议填写便于识别的名称", isError: false))
        }
        return issues
    }

    func saveConfig(showConfirmation: Bool = true) throws {
        for (index, rule) in config.rules.enumerated() where rule.enabled {
            if let issue = ruleValidationIssues(for: rule, at: index).first(where: \.isError) {
                throw NSError(domain: "AIFileSorter", code: 10, userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1)：\(issue.text)"])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        config.configVersion = SorterConfig.currentConfigVersion
        let previousConfigData = savedConfigData.isEmpty
            ? (try? Data(contentsOf: configURL)) ?? Data()
            : savedConfigData
        let previousConfig = try? JSONDecoder().decode(SorterConfig.self, from: previousConfigData)
        let launchAgentNeedsSync = previousConfig == nil
            || previousConfig?.watchFolder != config.watchFolder
            || previousConfig?.organizationMode != config.organizationMode
            || previousConfig?.automaticScanIntervalHours != config.automaticScanIntervalHours
        let launchAgentBeforeSave = inspectLaunchAgent()
        var didSyncLaunchAgent = false
        if FileManager.default.fileExists(atPath: configURL.path) && !recoveredFromBackup {
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: configURL, to: backup)
        }
        let newConfigData = try encoder.encode(config)
        do {
            // 配置期望状态为关闭时，先清理任何残留服务，避免写出“关闭但会重启”的半完成状态。
            if !config.automationEnabled && (launchAgentBeforeSave.plistExists || launchAgentBeforeSave.loaded) {
                _ = try launchAgentManager.disable()
            }
            try newConfigData.write(to: configURL, options: .atomic)
            if config.automationEnabled && launchAgentNeedsSync
                && (launchAgentBeforeSave.plistExists || launchAgentBeforeSave.loaded) {
                if let targetProblem = targetPermissionProblems().first {
                    throw NSError(
                        domain: "AIFileSorter",
                        code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "后台服务目标目录不可用：\(targetProblem)"]
                    )
                }
                _ = try launchAgentManager.enable(makeLaunchAgentConfiguration())
                didSyncLaunchAgent = true
            }
        } catch {
            if !previousConfigData.isEmpty {
                try? previousConfigData.write(to: configURL, options: .atomic)
            }
            if let previousConfig {
                config = previousConfig
                if previousConfig.automationEnabled {
                    _ = try? launchAgentManager.enable(makeLaunchAgentConfiguration(for: previousConfig))
                }
            }
            captureSavedConfig()
            refreshPendingFiles()
            startPendingWatcher(force: true)
            lastAgentError = error.localizedDescription
            if launchAgentNeedsSync && (launchAgentBeforeSave.plistExists || launchAgentBeforeSave.loaded) {
                setServiceStatus(.agentError, detail: "配置未应用，已保留上次保存的配置")
                message = "同步失败，已保留原配置：\(error.localizedDescription)"
            }
            throw error
        }
        recoveredFromBackup = false
        captureSavedConfig()
        refreshPendingFiles()
        startPendingWatcher(force: true)
        refreshStatus()
        if showConfirmation {
            message = didSyncLaunchAgent
                ? "设置已保存，后台服务已自动同步"
                : (config.automationEnabled ? "设置已保存；后台服务配置未发生变化" : "设置已保存；后台服务尚未启用")
        }
    }

    func refreshStatus() {
        guard !busy else { return }
        statusGeneration += 1
        let generation = statusGeneration
        let expectedEnabled = config.automationEnabled
        let watchUsable = watchFolderIsUsable
        let manager = launchAgentManager
        let configuration = makeLaunchAgentConfiguration()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let inspection = manager.inspect(configuration: configuration)
            DispatchQueue.main.async {
                guard let self, generation == self.statusGeneration else { return }
                self.applyServiceStatus(
                    inspection,
                    expectedEnabled: expectedEnabled,
                    watchUsable: watchUsable
                )
            }
        }
    }

    private func applyServiceStatus(
        _ inspection: LaunchAgentInspection,
        expectedEnabled: Bool,
        watchUsable: Bool
    ) {
        if !expectedEnabled {
            if inspection.plistExists || inspection.loaded {
                setServiceStatus(.agentError, detail: "配置显示后台服务已关闭，但仍发现残留服务")
            } else {
                setServiceStatus(.notEnabled)
            }
        } else if !watchUsable {
            setServiceStatus(.permissionError, detail: "监听目录不可读写")
        } else if (inspection.plistExists || inspection.loaded) && !inspection.agentAvailable {
            setServiceStatus(.agentError, detail: inspection.agentError ?? "固定应用内后台组件不可用")
        } else if !inspection.loaded || inspection.matchesConfiguration != true {
            setServiceStatus(.configNotSynced, detail: "后台服务尚未使用当前配置")
        } else if let error = inspection.launchctlError {
            lastAgentError = error
            setServiceStatus(.agentError, detail: error)
        } else {
            lastAgentError = ""
            setServiceStatus(.running)
        }
    }

    func installAndStart() {
        if let targetProblem = targetPermissionProblems().first {
            setServiceStatus(.permissionError, detail: targetProblem)
            message = "无法启用后台服务：\(targetProblem)"
            return
        }
        let previousConfigData = savedConfigData
        let previousConfig = config
        config.automationEnabled = false
        do { try saveConfig(showConfirmation: false) }
        catch { config = previousConfig; message = "保存失败：\(error.localizedDescription)"; return }
        setServiceStatus(.paused, detail: "正在加载后台服务")
        runBackground(title: "正在安装并启用后台服务…", operation: { [launchAgentManager] in
            do {
                _ = try launchAgentManager.enable(self.makeLaunchAgentConfiguration())
                return ProcessResult(status: 0, output: "LaunchAgent 已加载")
            } catch {
                return ProcessResult(status: 1, output: error.localizedDescription)
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            guard result.status == 0 else {
                self.config = previousConfig
                if !previousConfigData.isEmpty {
                    try? previousConfigData.write(to: self.configURL, options: .atomic)
                }
                self.captureSavedConfig()
                self.refreshPendingFiles()
                self.startPendingWatcher(force: true)
                self.message = "启用失败，后台服务保持关闭：\(Self.cleanProcessOutput(result.output))"
                return
            }

            self.config.automationEnabled = true
            do {
                try self.saveConfig(showConfirmation: false)
                self.message = "后台服务已启用，并会跨重启保持"
            } catch {
                self.config = previousConfig
                _ = try? self.launchAgentManager.disable()
                self.captureSavedConfig()
                self.setServiceStatus(.agentError, detail: "启用状态保存失败，后台服务已回滚")
                self.message = "启用失败，后台服务已回滚：\(error.localizedDescription)"
            }
        })
    }

    func stopAutomation() {
        let previousConfigData = savedConfigData
        let previousConfig = config
        let launchAgentConfiguration = makeLaunchAgentConfiguration(for: previousConfig)
        setServiceStatus(.stopping)
        runBackground(title: "正在停止后台服务…", operation: { [launchAgentManager] in
            let result = launchAgentManager.disableTransaction(configuration: launchAgentConfiguration)
            switch result.outcome {
            case .closedSuccessfully:
                return ProcessResult(status: 0, output: "LaunchAgent 已停止并移除")
            case .failedButRestored:
                return ProcessResult(status: 2, output: "关闭失败，但原状态已恢复：\(result.error?.localizedDescription ?? "未知错误")")
            case .failedAndRestoreFailed:
                return ProcessResult(status: 3, output: "关闭失败且恢复失败：\(result.error?.localizedDescription ?? "未知错误")")
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            guard result.status == 0 else {
                self.config = previousConfig
                if result.status >= 3 {
                    self.setServiceStatus(.agentError, detail: Self.cleanProcessOutput(result.output))
                } else {
                    self.refreshStatus()
                }
                self.message = result.status >= 3
                    ? "停止失败且状态未能确认：\(Self.cleanProcessOutput(result.output))"
                    : "停止失败，后台服务已恢复原状态：\(Self.cleanProcessOutput(result.output))"
                return
            }
            self.config.automationEnabled = false
            do {
                try self.saveConfig(showConfirmation: false)
                self.message = "后台服务已关闭；LaunchAgent 已移除"
            } catch {
                self.config = previousConfig
                if !previousConfigData.isEmpty {
                    try? previousConfigData.write(to: self.configURL, options: .atomic)
                }
                self.captureSavedConfig()
                do {
                    _ = try self.launchAgentManager.enable(self.makeLaunchAgentConfiguration(for: previousConfig))
                    self.refreshStatus()
                } catch {
                    self.setServiceStatus(.agentError, detail: "关闭状态保存失败，后台服务恢复也失败")
                }
                self.message = "关闭失败，已尽量恢复之前状态：\(error.localizedDescription)"
            }
        })
    }

    private func cleanupDisabledAutomationIfNeeded() {
        guard !config.automationEnabled else { return }
        let inspection = launchAgentManager.inspect()
        guard inspection.plistExists || inspection.loaded else { return }
        do {
            _ = try launchAgentManager.disable()
            message = "已清理关闭配置留下的后台服务残留"
        } catch {
            lastAgentError = error.localizedDescription
            setServiceStatus(.agentError, detail: "后台服务关闭配置与实际状态不一致")
            message = "无法清理已关闭的后台服务：\(error.localizedDescription)"
        }
    }

    func sortExistingNow() {
        do { try saveConfig(showConfirmation: false) }
        catch { message = "保存失败：\(error.localizedDescription)"; return }
        let agentURL = bundledAgentURL
        runBackground(title: "正在整理 Downloads 中的现有文件…", operation: { [engineDirectory, configURL] in
            Self.runProcess(
                executable: agentURL.path,
                arguments: ["--config", configURL.path, "--once"],
                workingDirectory: engineDirectory
            )
        }, completion: { [weak self] result in
            guard result.status == 0 else { return }
            self?.refreshPendingFiles()
        })
    }

    func scanOnly() {
        guard !busy else { return }
        setServiceStatus(.scanning)
        showOrganizingPlan = true
        refreshPendingFiles { [weak self] in
            guard let self else { return }
            self.generatePlanFromSnapshot()
            if self.organizingPlan.isEmpty {
                self.refreshStatus()
            } else {
                self.setServiceStatus(.awaitingConfirmation)
            }
        }
    }

    private func runBackground(
        title: String,
        operation: @escaping () -> ProcessResult,
        completion: ((ProcessResult) -> Void)? = nil
    ) {
        busy = true
        if title.contains("扫描") { setServiceStatus(.scanning) }
        else if title.contains("整理") || title.contains("移动") || title.contains("撤销") { setServiceStatus(.organizing) }
        message = title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = operation()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if result.status == 0 {
                    self.refreshStatus()
                } else {
                    self.lastAgentError = Self.cleanProcessOutput(result.output)
                    self.setServiceStatus(.agentError, detail: self.lastAgentError)
                }
                self.refreshLog()
                self.refreshPendingFiles()
                self.refreshHistory()
                self.startPendingWatcher()
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.message = result.status == 0
                    ? (text.isEmpty ? "操作完成" : text)
                    : (text.isEmpty ? "操作失败，请查看错误日志" : text)
                completion?(result)
            }
        }
    }

    // App 包内后台组件的唯一位置。安装到 /Applications 后 LaunchAgent 会始终从该固定路径启动。
    private var bundledAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent("com.ai.filesorter.agent")
    }

    private var fixedAppURL: URL {
        launchAgentManager.fixedApplicationURL
    }

    private var launchAgentURL: URL {
        launchAgentManager.agentURL
    }

    private var expandedWatchPath: String {
        URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private var watchFolderIsUsable: Bool {
        var isDirectory = ObjCBool(false)
        let manager = FileManager.default
        guard manager.fileExists(atPath: expandedWatchPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return manager.isReadableFile(atPath: expandedWatchPath) && manager.isWritableFile(atPath: expandedWatchPath)
    }

    private func makeLaunchAgentConfiguration(for value: SorterConfig? = nil) -> LaunchAgentConfiguration {
        let source = value ?? config
        let watchURL = URL(
            fileURLWithPath: NSString(string: source.watchFolder).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        let interval = source.organizationMode == OrganizationMode.automatic.rawValue
            && source.automaticScanIntervalHours > 0
            ? max(60, source.automaticScanIntervalHours * 3_600)
            : nil
        return launchAgentManager.makeConfiguration(
            configURL: configURL,
            watchPath: watchURL,
            startIntervalSeconds: interval
        )
    }

    private struct AppLaunchAgentInspection {
        let plistExists: Bool
        let plistReadable: Bool
        let loaded: Bool
        let plist: [String: Any]
        let launchctlOutput: String
        let launchctlError: String?
        let agentAvailable: Bool
        let agentError: String
        let labelMatches: Bool
        let argumentsMatch: Bool
        let configPathMatches: Bool
        let watchPathsMatch: Bool
        let startIntervalMatches: Bool

        var matchesCurrentConfiguration: Bool {
            plistReadable && labelMatches && argumentsMatch && configPathMatches
                && watchPathsMatch && startIntervalMatches
        }
    }

    private func inspectLaunchAgent() -> AppLaunchAgentInspection {
        let inspected = launchAgentManager.inspect(configuration: makeLaunchAgentConfiguration())
        return AppLaunchAgentInspection(
            plistExists: inspected.plistExists,
            plistReadable: inspected.plistReadable,
            loaded: inspected.loaded,
            plist: inspected.plist,
            launchctlOutput: inspected.launchctlOutput,
            launchctlError: inspected.launchctlError,
            agentAvailable: inspected.agentAvailable,
            agentError: inspected.agentError ?? "固定应用内后台组件不可用",
            labelMatches: inspected.labelMatches == true,
            argumentsMatch: inspected.argumentsMatch == true,
            configPathMatches: inspected.configPathMatches == true,
            watchPathsMatch: inspected.watchPathsMatch == true,
            startIntervalMatches: inspected.startIntervalMatches == true
        )
    }

    private func setServiceStatus(_ status: AppServiceStatus, detail: String? = nil) {
        serviceStatus = status
        switch status {
        case .notEnabled:
            runtimeState = .stopped
        case .running:
            runtimeState = .running
        case .scanning:
            runtimeState = .scanning
        case .awaitingConfirmation:
            runtimeState = .awaitingConfirmation
        case .organizing:
            runtimeState = .organizing
        case .stopping:
            runtimeState = .temporarilyPaused
        case .paused:
            runtimeState = .temporarilyPaused
        case .configNotSynced, .permissionError, .agentError:
            runtimeState = .error
        }
        if let detail, !detail.isEmpty {
            message = "状态：\(status.title)；\(detail)"
        }
    }

    nonisolated private static func cleanProcessOutput(_ output: String) -> String {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "没有返回详细错误" : String(cleaned.suffix(1_000))
    }

    func assessmentStatusTitle(_ status: FileProcessingStatus) -> String {
        switch status {
        case .moved: return "已完成"
        case .ready: return "可以整理"
        case .awaitingConfirmation: return "等待确认"
        case .automaticPending: return "自动整理待处理"
        case .waitingRetention: return "保留期等待"
        case .recentlyModified: return "最近修改保护"
        case .unstable: return "仍在写入"
        case .excluded: return "已排除"
        case .temporary: return "临时文件"
        case .hidden: return "隐藏文件"
        case .locked: return "已锁定"
        case .unsupported: return "不支持"
        case .unmatched: return "未匹配"
        case .invalidTarget: return "目标无效"
        case .destinationInWatchFolder: return "目标位于监听目录"
        case .permissionError: return "权限异常"
        case .metadataUnavailable: return "无法读取元数据"
        case .missing: return "文件已不存在"
        case .notRegularFile: return "不是普通文件"
        case .sameLocation: return "目标与来源相同"
        case .failed: return "执行失败"
        case .sourceOutsideWatchFolder: return "来源不在监听目录"
        case .symlink: return "符号链接已跳过"
        }
    }

    private func targetPermissionProblems() -> [String] {
        let manager = FileManager.default
        return config.rules.enumerated().compactMap { index, rule in
            let raw = rule.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "规则 \(index + 1) 目标为空" }
            let target = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath).standardizedFileURL
            var isDirectory = ObjCBool(false)
            if manager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue && manager.isWritableFile(atPath: target.path) else {
                    return "规则 \(index + 1)：\(target.path) 不可写"
                }
                return nil
            }
            var parent = target.deletingLastPathComponent()
            while !manager.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            return manager.isWritableFile(atPath: parent.path) ? nil : "规则 \(index + 1)：\(target.path) 的父目录不可写"
        }
    }

    private func recentErrorSummary(launchctlError: String?) -> String? {
        var errors: [String] = []
        if let launchctlError { errors.append(launchctlError) }
        let files = [
            logsDirectory.appendingPathComponent("launchd.err.log"),
            logsDirectory.appendingPathComponent("sorter.log"),
        ]
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let content = String(decoding: data.suffix(20_000), as: UTF8.self)
            let matches = content.split(whereSeparator: \.isNewline).filter { line in
                let lower = line.lowercased()
                return lower.contains("error") || lower.contains("failed") || lower.contains("failure")
                    || line.contains("失败") || line.contains("错误") || line.contains("权限")
            }
            errors.append(contentsOf: matches.suffix(3).map(String.init))
        }
        guard !errors.isEmpty else { return nil }
        return errors.suffix(4).joined(separator: " | ")
    }

    // 收件箱只消费 Agent 的一次性结构化评估；扫描失败时保留上一次成功快照。
    func refreshPendingFiles(completion: (() -> Void)? = nil) {
        guard !busy else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let agent = bundledAgentURL
        let configPath = configURL.path
        let workingDirectory = engineDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runProcess(
                executable: agent.path,
                arguments: ["--config", configPath, "--scan-json"],
                workingDirectory: workingDirectory
            )
            let decoded: Result<FileAssessmentDocument, Error>
            if result.status != 0 {
                decoded = .failure(NSError(
                    domain: "AIFileSorter",
                    code: Int(result.status),
                    userInfo: [NSLocalizedDescriptionKey: Self.cleanProcessOutput(result.output)]
                ))
            } else {
                do {
                    let document = try JSONDecoder().decode(FileAssessmentDocument.self, from: Data(result.output.utf8))
                    guard document.schemaVersion == 2 else {
                        throw NSError(
                            domain: "AIFileSorter",
                            code: 41,
                            userInfo: [NSLocalizedDescriptionKey: "不支持的扫描结果 schema_version：\(document.schemaVersion)"]
                        )
                    }
                    decoded = .success(document)
                } catch {
                    decoded = .failure(error)
                }
            }
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                switch decoded {
                case let .success(document):
                    self.inboxSnapshot = document
                    self.scanError = nil
                    self.rebuildPendingFiles(from: document)
                    if !self.busy { self.refreshStatus() }
                    completion?()
                case let .failure(error):
                    self.scanError = error.localizedDescription
                    self.lastAgentError = error.localizedDescription
                    // 不清空 pendingFiles/inboxSnapshot，让界面保留上一次成功结果并显示错误。
                    self.message = "收件箱扫描失败，已保留上次成功快照：\(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildPendingFiles(from document: FileAssessmentDocument) {
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredDefaultsKey) ?? [])
        let existing = Dictionary(uniqueKeysWithValues: pendingFiles.map { ($0.path, $0) })
        pendingFiles = document.items.prefix(300).map { item in
            let isIgnored = fileSignatureKey(for: item).map(ignored.contains) == true
            let permissions = AssessmentActionPermissions(
                canManualMove: item.canManualMove,
                canIncludeInPlan: item.canIncludeInPlan,
                canAutoMoveNow: item.canAutoMoveNow
            )
            return PendingFile.rebuilding(
                assessment: item,
                previous: existing[item.path],
                suggestedKeyword: suggestedKeyword(for: URL(fileURLWithPath: item.path)),
                ignored: isIgnored,
                permissions: permissions
            )
        }
    }

    private func matchingRule(fileName: String) -> (offset: Int, element: SorterRule)? {
        config.rules.enumerated().first { _, rule in rule.matches(fileName: fileName) }
    }

    private func fileSignatureKey(_ file: URL) -> String? {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize,
              let modified = AssessmentTimestamp.modifiedNanoseconds(at: file) else { return nil }
        return "\(file.path)|\(size)|\(modified)"
    }

    private func fileSignatureKey(for item: FileAssessmentItem) -> String? {
        guard let modified = item.modifiedNs else { return nil }
        return "\(item.path)|\(item.fileSize)|\(modified)"
    }

    // 去掉日期、版本号和常见下载噪声，优先保留最能代表文件内容的名称片段。
    private func suggestedKeyword(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let separators = CharacterSet(charactersIn: "_-—–()（）[]【】 ")
        let ignored = Set(["final", "new", "copy", "副本", "文件", "资料", "下载", "最新版"])
        let candidates = stem.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard value.count >= 2, !ignored.contains(value.lowercased()) else { return false }
                guard value.range(of: #"^v?\d+(?:[.\-]\d+)*$"#, options: .regularExpression) == nil else { return false }
                guard value.range(of: #"^\d{4}[.\-年]?\d{0,2}[.\-月]?\d{0,2}日?$"#, options: .regularExpression) == nil else { return false }
                return true
            }
        let result = candidates.max { lhs, rhs in lhs.count < rhs.count } ?? stem
        return String(result.prefix(40))
    }


    // 使用系统目录事件代替固定间隔轮询；0.5 秒合并连续下载事件，降低重复扫描。
    private func startPendingWatcher(force: Bool = false) {
        let path = NSString(string: config.watchFolder).expandingTildeInPath
        if !force, pendingWatchSource != nil, pendingWatchedPath == path { return }
        pendingWatchSource?.cancel()
        pendingWatchSource = nil
        pendingWatchedPath = path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingRefreshWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refreshPendingFiles() }
                self.pendingRefreshWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        pendingWatchSource = source
        source.resume()
    }

    private func swiftDateFormat(_ value: String) -> String {
        value.replacingOccurrences(of: "%Y", with: "yyyy")
            .replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd")
            .replacingOccurrences(of: "%H", with: "HH")
            .replacingOccurrences(of: "%M", with: "mm")
            .replacingOccurrences(of: "%S", with: "ss")
    }

    func renamedFileName(_ original: String, rule: SorterRule? = nil) -> String {
        guard config.rename.enabled else { return original }
        let file = URL(fileURLWithPath: original)
        let formatter = DateFormatter()
        formatter.dateFormat = swiftDateFormat(config.rename.dateFormat)
        let ext = file.pathExtension
        let matchedKeyword = rule?.keywords.first(where: {
            original.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) ?? "关键词"
        let category = rule.map {
            URL(fileURLWithPath: NSString(string: $0.target).expandingTildeInPath).lastPathComponent
        } ?? "分类"
        var result = config.rename.template
            .replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))
            .replacingOccurrences(of: "{original_name}", with: file.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{keyword}", with: matchedKeyword)
        if !ext.isEmpty && !result.lowercased().hasSuffix("." + ext.lowercased()) { result += "." + ext }
        return URL(fileURLWithPath: result).lastPathComponent
    }

    func testRuleMatch() {
        let name = ruleTestFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { ruleTestResult = "请输入一个文件名"; return }
        guard let match = matchingRule(fileName: name) else {
            ruleTestResult = "未匹配任何启用的规则，文件会进入收件箱。"
            return
        }
        let rule = match.element
        let condition: String
        if !rule.keywords.isEmpty { condition = rule.matchMode == "all" ? "全部关键词" : "任意关键词" }
        else if !rule.extensions.isEmpty { condition = "扩展名 \(rule.extensions.joined(separator: "、"))" }
        else { condition = "名称正则" }
        let metadataNote = rule.usesMetadataConditions ? "\n注意：大小、日期和 Finder 标签需要在“整理计划”中用真实文件验证。" : ""
        ruleTestResult = "匹配规则 \(match.offset + 1)：\(rule.name)（\(condition)）\n→ \(NSString(string: rule.target).expandingTildeInPath)/\(renamedFileName(name, rule: rule))\(metadataNote)"
    }

    func analyzeRuleConflicts() {
        var rows: [String] = []
        let active = config.rules.enumerated().filter { $0.element.enabled }
        for (index, rule) in active {
            let duplicates = Dictionary(grouping: rule.keywords.map { $0.lowercased() }, by: { $0 }).filter { $0.value.count > 1 }.keys
            if !duplicates.isEmpty { rows.append("△ 规则 \(index + 1) 内有重复关键词：\(duplicates.sorted().joined(separator: "、"))") }
            let short = rule.keywords.filter { $0.count < 2 }
            if !short.isEmpty { rows.append("△ 规则 \(index + 1) 关键词过短，可能误匹配：\(short.joined(separator: "、"))") }
            if rule.extensions.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                rows.append("△ 规则 \(index + 1) 包含空扩展名条件")
            }
        }
        for leftPosition in active.indices {
            for rightPosition in active.indices where rightPosition > leftPosition {
                let left = active[leftPosition]
                let right = active[rightPosition]
                let leftWords = Set(left.element.keywords.map { $0.lowercased() })
                let rightWords = Set(right.element.keywords.map { $0.lowercased() })
                let shared = leftWords.intersection(rightWords)
                if !shared.isEmpty {
                    rows.append("△ 规则 \(left.offset + 1) 与规则 \(right.offset + 1) 共享关键词：\(shared.sorted().joined(separator: "、"))；前面的规则优先")
                }
            }
        }
        ruleDiagnostics = rows.isEmpty ? "✓ 未发现明显的重复、遮挡或高风险关键词。" : rows.joined(separator: "\n")
        message = rows.isEmpty ? "规则检查通过" : "发现 \(rows.count) 个需要确认的规则问题"
    }

    func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI-File-Sorter-Rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let package = RuleExport(formatVersion: 1, exportedAt: Date(), rules: config.rules)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(package).write(to: url, options: .atomic)
            message = "已导出 \(config.rules.count) 条规则"
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }

    func importRules() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let package = try decoder.decode(RuleExport.self, from: data)
            guard package.formatVersion == 1 else {
                throw NSError(domain: "AIFileSorter", code: 20, userInfo: [NSLocalizedDescriptionKey: "暂不支持规则格式版本 \(package.formatVersion)"])
            }
            let imported = package.rules
            guard !imported.isEmpty else {
                throw NSError(domain: "AIFileSorter", code: 21, userInfo: [NSLocalizedDescriptionKey: "导入文件没有规则"])
            }
            let previous = config.rules
            let existingNames = Set(previous.map { $0.name.lowercased() })
            let duplicateNames = imported.filter { existingNames.contains($0.name.lowercased()) }.count
            let missingTargets = imported.filter {
                !FileManager.default.fileExists(atPath: NSString(string: $0.target).expandingTildeInPath)
            }.count
            let invalidRegex = imported.filter {
                !$0.nameRegex.isEmpty && (try? NSRegularExpression(pattern: $0.nameRegex)) == nil
            }.count
            let alert = NSAlert()
            alert.messageText = "审核 \(imported.count) 条导入规则"
            alert.informativeText = """
            当前规则：\(previous.count) 条
            同名规则：\(duplicateNames) 条
            尚未创建的目标目录：\(missingTargets) 个（执行时会自动创建）
            无效正则表达式：\(invalidRegex) 条
            导入后会由原生 Agent 重新评估当前监听目录中的文件

            “替换”会用导入内容覆盖当前规则；“追加”会保留当前规则并把新规则放到末尾。
            """
            alert.addButton(withTitle: "审核后替换")
            alert.addButton(withTitle: "审核后追加")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { config.rules = imported }
            else if response == .alertSecondButtonReturn {
                config.rules.append(contentsOf: imported.map { rule in
                    var copy = rule; copy.id = UUID(); return copy
                })
            } else { return }
            do { try saveConfig(showConfirmation: false) }
            catch { config.rules = previous; throw error }
            message = "规则导入并保存成功"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    // 复制给外部 AI 的开放格式提示词；App 自身不联网，也不会把目录信息上传。
    func copyAIRulePrompt() {
        let prompt = """
        请作为 macOS 文件整理专家，根据我接下来提供的文件夹结构、常见文件名和分类习惯，为 AI File Sorter 设计规则。

        当前监听目录：\(config.watchFolder)

        请只返回一个可保存为 .json 并直接导入的 JSON 对象，不要使用 Markdown 代码围栏。格式如下：
        {
          "format_version": 1,
          "rules": [
            {
              "name": "清晰的规则名称",
              "enabled": true,
              "match_mode": "any",
              "keywords": ["关键词1", "关键词2"],
              "exclude_keywords": [],
              "extensions": ["pdf", "docx"],
              "name_regex": "",
              "minimum_size_mb": null,
              "maximum_size_mb": null,
              "modified_older_than_days": null,
              "modified_newer_than_days": null,
              "finder_tags": [],
              "target": "~/Documents/目标目录"
            }
          ]
        }

        规则按顺序匹配，请把更具体的规则放在前面。match_mode 只能是 any 或 all；target 使用 ~ 开头的 macOS 路径；关键词、扩展名和 name_regex 至少填写一项。大小单位为 MB，修改时间单位为天；没有高级条件时使用 null、空字符串或空数组。不要臆造我未提供的目录。

        我会在下一条消息提供目录结构和样例文件名，请先等我提供资料。
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        message = "已复制 AI 规则需求模板；粘贴给 ChatGPT、Codex 或其他 AI 即可"
    }

    func restoreRuleBackup() {
        let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json")
        let previous = config.rules
        do {
            let old = try JSONDecoder().decode(SorterConfig.self, from: Data(contentsOf: backup))
            config.rules = old.rules
            do { try saveConfig(showConfirmation: false) }
            catch { config.rules = previous; throw error }
            message = "已恢复上一次保存前的规则"
        } catch { message = "没有可恢复的规则备份，或备份已损坏" }
    }

    func restoreDefaultRules() {
        let alert = NSAlert()
        alert.messageText = "恢复 8 条通用默认规则？"
        alert.informativeText = "当前规则会先由配置备份机制保存。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let previous = config.rules
        config.rules = SorterConfig.fallback.rules
        do { try saveConfig(showConfirmation: false); message = "默认规则已恢复" }
        catch { config.rules = previous; message = "恢复失败：\(error.localizedDescription)" }
    }

    var recentTargetFolders: [String] {
        UserDefaults.standard.stringArray(forKey: recentTargetsDefaultsKey) ?? []
    }

    private func rememberTarget(_ target: String) {
        var values = recentTargetFolders.filter { $0 != target }
        values.insert(target, at: 0)
        UserDefaults.standard.set(Array(values.prefix(8)), forKey: recentTargetsDefaultsKey)
    }

    func matchingPendingCount(keyword: String) -> Int {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }
        return pendingFiles.count { $0.fileName.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // 单文件、批量文件和最近目录都从这里进入统一确认流程。
    func beginPendingMove(paths: [String], preferredTarget: String? = nil) {
        let items = paths.compactMap { path in pendingFiles.first(where: { $0.path == path }) }
        guard !items.isEmpty else { message = "请选择仍在收件箱中的文件"; return }
        let keywords = Set(items.map { $0.keyword.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let commonKeyword = keywords.count == 1 ? keywords.first ?? "" : (items.count == 1 ? items[0].keyword : "")
        pendingMoveDraft = PendingMoveDraft(
            paths: items.map(\.path),
            fileNames: items.map(\.fileName),
            suggestedKeyword: commonKeyword,
            suggestedTarget: preferredTarget ?? recentTargetFolders.first ?? items.first?.target ?? "~/Documents"
        )
    }

    func revealPending(_ item: PendingFile) {
        guard FileManager.default.fileExists(atPath: item.path) else { message = "文件已不存在"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func quickLookPending(_ item: PendingFile) {
        guard FileManager.default.fileExists(atPath: item.path) else { message = "文件已不存在"; return }
        QuickLookCoordinator.shared.show(path: item.path)
    }

    func moveSelectedOnce() {
        let paths = pendingFiles.filter(\.selected).map(\.path)
        guard !paths.isEmpty else { message = "请先勾选要整理的文件"; return }
        beginPendingMove(paths: paths)
    }

    // 返回 false 时保留确认面板，让用户直接修正输入。
    func confirmPendingMove(draft: PendingMoveDraft, target: String, saveAsRule: Bool, keyword: String) -> Bool {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { message = "请先选择目标文件夹"; return false }
        let watch = URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath).standardizedFileURL
        let destination = URL(fileURLWithPath: NSString(string: cleanTarget).expandingTildeInPath).standardizedFileURL
        guard watch != destination else { message = "目标不能与监听文件夹相同"; return false }
        if saveAsRule {
            guard !cleanKeyword.isEmpty else { message = "要保存自动规则，请填写用于识别类似文件的关键词"; return false }
            if config.rules.contains(where: { $0.keywords.contains { $0.caseInsensitiveCompare(cleanKeyword) == .orderedSame } }) {
                message = "关键词“\(cleanKeyword)”已有规则；请修改关键词，或关闭“保存自动规则”"
                return false
            }
        }

        let extensions = Array(Set(draft.paths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }.filter { !$0.isEmpty })).sorted()
        let rule = saveAsRule ? SorterRule(name: cleanKeyword, keywords: [cleanKeyword], extensions: extensions, target: cleanTarget) : nil
        pendingMoveDraft = nil
        performOneTimeMove(paths: draft.paths, target: cleanTarget, ruleAfterSuccess: rule)
        return true
    }

    private func performOneTimeMove(paths: [String], target: String, ruleAfterSuccess: SorterRule?) {
        let agent = bundledAgentURL
        runBackground(title: "正在整理所选的 \(paths.count) 个文件…", operation: { [configURL, engineDirectory] in
            Self.runProcess(
                executable: agent.path,
                arguments: ["--config", configURL.path, "--move-many", target] + paths,
                workingDirectory: engineDirectory
            )
        }, completion: { [weak self] result in
            guard let self, result.status == 0 else { return }
            self.rememberTarget(target)
            guard let ruleAfterSuccess else {
                self.message = "已完成单次整理；没有保存自动规则"
                return
            }
            self.config.rules.insert(ruleAfterSuccess, at: 0)
            do {
                try self.saveConfig(showConfirmation: false)
                self.message = "整理完成，并已保存规则“\(ruleAfterSuccess.name)”"
            } catch {
                self.config.rules.removeAll { $0.id == ruleAfterSuccess.id }
                self.message = "文件已移动，但规则保存失败：\(error.localizedDescription)"
            }
        })
    }

    func ignorePending(_ paths: [String]) {
        var ignored = UserDefaults.standard.stringArray(forKey: ignoredDefaultsKey) ?? []
        let signatures = paths.compactMap { path -> String? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return fileSignatureKey(URL(fileURLWithPath: path))
        }
        ignored.append(contentsOf: signatures)
        UserDefaults.standard.set(Array(ignored.suffix(1000)), forKey: ignoredDefaultsKey)
        refreshPendingFiles()
        message = "已忽略 \(signatures.count) 个文件；文件仍保留在原位置"
    }

    func ignoreSelectedPending() {
        ignorePending(pendingFiles.filter(\.selected).map(\.path))
    }

    func refreshHistory() {
        let url = logsDirectory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([MoveHistory].self, from: data) else {
            historyRecords = []
            return
        }
        historyRecords = Array(records.reversed().prefix(500))
    }

    func undoMove(_ record: MoveHistory) {
        let agent = bundledAgentURL
        runBackground(title: "正在撤销整理…") { [configURL, engineDirectory] in
            Self.runProcess(executable: agent.path, arguments: ["--config", configURL.path, "--undo", record.id], workingDirectory: engineDirectory)
        }
    }

    func revealHistoryFile(_ record: MoveHistory) {
        let path = record.undone ? record.originalPath : record.destinationPath
        guard FileManager.default.fileExists(atPath: path) else { message = "文件已经不在记录的位置"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func refreshLog() {
        let url = logsDirectory.appendingPathComponent("sorter.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            logText = "暂无整理记录。下载一个能命中规则的文件后，这里会显示结果。"
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 40_000 ? size - 40_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let content = String(decoding: data, as: UTF8.self)
        logText = content.isEmpty ? "暂无整理记录。" : content
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDirectory)
    }

    func openDownloadsFolder() {
        let raw = config.watchFolder
        NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true))
    }

    func generateOrganizingPlan() {
        refreshPendingFiles { [weak self] in self?.generatePlanFromSnapshot() }
    }

    private func generatePlanFromSnapshot() {
        organizingPlan = pendingFiles.prefix(300).compactMap { pending in
            let assessment = pending.assessment
            guard pending.canIncludeInPlan, !pending.ignored, !assessment.ruleName.isEmpty else { return nil }
            let modifiedAt = AssessmentTimestamp.date(from: assessment.modifiedAt)
            let ageDays = modifiedAt.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) }
            let status = assessmentStatusTitle(assessment.status)
            return OrganizingPlanItem(
                id: assessment.path,
                assessment: assessment,
                sourcePath: assessment.path,
                fileName: assessment.fileName,
                ruleName: assessment.ruleName,
                destinationPath: assessment.destinationPath.isEmpty ? assessment.targetFolder : assessment.destinationPath,
                status: status,
                fileSize: assessment.fileSize,
                modifiedAt: modifiedAt,
                ageDays: ageDays,
                canManualMove: assessment.canManualMove,
                canIncludeInPlan: assessment.canIncludeInPlan,
                canAutoMoveNow: assessment.canAutoMoveNow,
                selected: assessment.canIncludeInPlan && assessment.canAutoMoveNow
            )
        }
        message = organizingPlan.isEmpty ? "当前没有会被规则整理的文件" : "已生成 \(organizingPlan.count) 项整理计划"
    }

    func executeOrganizingPlan() {
        let selectedItems = organizingPlan.filter(\.selected)
        let paths = selectedItems.map(\.sourcePath)
        guard !paths.isEmpty else { message = "请至少选择一个可以整理的文件"; return }
        do { try saveConfig(showConfirmation: false) }
        catch { message = "保存失败：\(error.localizedDescription)"; return }
        let agent = bundledAgentURL
        runBackground(title: "正在执行整理计划…", operation: { [configURL, engineDirectory] in
            Self.runProcess(
                executable: agent.path,
                arguments: ["--config", configURL.path, "--sort-paths"] + paths,
                workingDirectory: engineDirectory
            )
        }, completion: { [weak self] _ in
            self?.organizingPlan = []
        })
    }

    var latestUndoableBatchID: String? {
        historyRecords.first(where: { !$0.undone && $0.batchID != nil })?.batchID
    }

    func undoLatestBatch() {
        guard let batchID = latestUndoableBatchID else { message = "没有可撤销的整理批次"; return }
        let agent = bundledAgentURL
        runBackground(title: "正在撤销最近一次批量整理…") { [configURL, engineDirectory] in
            Self.runProcess(
                executable: agent.path,
                arguments: ["--config", configURL.path, "--undo-batch", batchID],
                workingDirectory: engineDirectory
            )
        }
    }

    func runHealthCheck() {
        let manager = FileManager.default
        let inspection = inspectLaunchAgent()
        var rows: [String] = []
        let fixedAppExists = manager.fileExists(atPath: fixedAppURL.path)
        let runningFromFixedApp = Bundle.main.bundleURL.standardizedFileURL == fixedAppURL.standardizedFileURL
        rows.append(runningFromFixedApp && fixedAppExists
            ? "✓ 应用位于固定路径：\(fixedAppURL.path)"
            : "✕ 应用必须从固定路径运行：\(fixedAppURL.path)")

        rows.append(inspection.agentAvailable
            ? "✓ 原生整理组件可执行"
            : "✕ 原生整理组件不可用：\(inspection.agentError)")
        if fixedAppExists && inspection.agentAvailable {
            let native = Self.runProcess(executable: launchAgentURL.path, arguments: ["--config", configURL.path, "--check-config"])
            rows.append(native.status == 0
                ? "✓ 整理组件配置检查通过"
                : "✕ 整理组件配置检查失败：\(Self.cleanProcessOutput(native.output))")
        } else {
            rows.append("△ 未执行整理组件检查：固定应用或整理组件不可用")
        }

        rows.append(inspection.plistExists && inspection.plistReadable
            ? "✓ 后台服务配置存在"
            : "△ 后台服务配置未加载或不可读")
        rows.append(inspection.loaded ? "✓ 后台服务已加载" : "△ 后台服务当前未加载")

        let arguments = (inspection.plist["ProgramArguments"] as? [String] ?? []).joined(separator: " ")
        rows.append(inspection.argumentsMatch
            ? "✓ 后台服务启动路径正确"
            : "✕ 后台服务启动路径不匹配：\(arguments.isEmpty ? "缺失" : arguments)")
        rows.append(inspection.configPathMatches
            ? "✓ 后台服务使用当前配置"
            : "✕ 后台服务配置路径不匹配")

        let watchPaths = (inspection.plist["WatchPaths"] as? [String] ?? []).joined(separator: "、")
        rows.append(inspection.watchPathsMatch
            ? "✓ 监听目录配置正确"
            : "✕ 监听目录配置不匹配：\(watchPaths.isEmpty ? "缺失" : watchPaths)")

        let expectedInterval = config.organizationMode == "automatic" && config.automaticScanIntervalHours > 0
            ? max(60, config.automaticScanIntervalHours * 3_600)
            : nil
        let actualInterval = (inspection.plist["StartInterval"] as? NSNumber)?.intValue
            ?? (inspection.plist["StartInterval"] as? Int)
        let intervalText = expectedInterval.map(String.init) ?? "未设置"
        let actualIntervalText = actualInterval.map(String.init) ?? "未设置"
        rows.append(inspection.startIntervalMatches
            ? "✓ 定期检查间隔：\(intervalText) 秒"
            : "✕ 定期检查间隔不匹配：当前 \(actualIntervalText)，期望 \(intervalText)")

        rows.append(watchFolderIsUsable
            ? "✓ 监听目录可读写：\(expandedWatchPath)"
            : "✕ 监听目录不可读写：\(expandedWatchPath)")
        let targetProblems = targetPermissionProblems()
        rows.append(targetProblems.isEmpty
            ? "✓ 所有规则目标路径可创建或写入"
            : "✕ 目标路径权限异常：\(targetProblems.joined(separator: "；"))")

        if let recentErrors = recentErrorSummary(launchctlError: inspection.launchctlError) {
            rows.append("✕ 最近错误：\(recentErrors)")
        } else {
            rows.append("✓ 最近错误：未发现")
        }

        refreshStatus()
        if let nativeFailure = rows.first(where: { $0.hasPrefix("✕ 整理组件配置检查失败") }) {
            lastAgentError = nativeFailure
            setServiceStatus(.agentError, detail: nativeFailure)
        } else if !targetProblems.isEmpty || !watchFolderIsUsable {
            setServiceStatus(.permissionError, detail: "请检查监听目录和规则目标路径权限")
        } else if inspection.plistExists && !inspection.matchesCurrentConfiguration {
            setServiceStatus(.configNotSynced, detail: "后台服务配置与当前设置不一致")
        }
        rows.append("当前服务状态：\(serviceStatus.title)")
        healthReport = rows.joined(separator: "\n")
        message = rows.contains(where: { $0.hasPrefix("✕") }) ? "自检发现需要处理的问题" : "环境与权限检查完成"
    }

    func chooseFolder(current: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        let expanded = NSString(string: current).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if panel.runModal() == .OK, let selected = panel.url { completion(selected.path) }
    }

    nonisolated private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil
    ) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessResult(status: 1, output: error.localizedDescription)
        }
    }

}
