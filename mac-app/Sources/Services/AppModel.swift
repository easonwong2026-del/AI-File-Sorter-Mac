import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // 始终提供可编辑配置，资源部署失败时按钮也不会静默失效。
    @Published var config: SorterConfig = .fallback {
        didSet { updateUnsavedChanges() }
    }
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var runtimeState: SorterRuntimeState = .stopped
    @Published var busy = false
    @Published var message = "正在准备…"
    @Published var logText = "暂无日志"
    @Published var healthReport = "尚未检查"
    @Published var pendingFiles: [PendingFile] = []
    @Published var pendingMoveDraft: PendingMoveDraft?
    @Published var historyRecords: [MoveHistory] = []
    @Published var organizingPlan: [OrganizingPlanItem] = []
    @Published var showOrganizingPlan = false
    @Published var ruleTestFileName = "2026年7月_项目合同.pdf"
    @Published var ruleTestResult = "输入文件名后点击测试"
    @Published var ruleDiagnostics = "尚未检查规则"
    @Published var showQuitConfirmation = false

    var automationEnabled: Bool { runtimeState.isServiceEnabled }

    let applicationSupportDirectory: URL
    let engineDirectory: URL
    let configURL: URL
    let logsDirectory: URL
    private var recoveredFromBackup = false
    private let ignoredDefaultsKey = "ignoredUnmatchedSignatures"
    private let recentTargetsDefaultsKey = "recentTargetFolders"
    private var pendingWatchSource: DispatchSourceFileSystemObject?
    private var pendingWatchedPath = ""
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var savedConfigData = Data()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI-File-Sorter-Mac", isDirectory: true)
        applicationSupportDirectory = base
        engineDirectory = base.appendingPathComponent("Engine", isDirectory: true)
        configURL = engineDirectory.appendingPathComponent("config.json")
        logsDirectory = engineDirectory.appendingPathComponent("logs", isDirectory: true)

        do {
            try deployEngine()
            try loadConfig()
            captureSavedConfig()
            refreshStatus()
            refreshPendingFiles()
            startPendingWatcher()
            if automationEnabled && launchAgentNeedsFixedPathMigration()
                && Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/AI File Sorter.app" {
                installAndStart()
            } else {
                message = automationEnabled ? "自动整理已启用" : "自动整理尚未启用"
            }
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
        config.configVersion = 9
        if FileManager.default.fileExists(atPath: configURL.path) && !recoveredFromBackup {
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: configURL, to: backup)
        }
        try encoder.encode(config).write(to: configURL, options: .atomic)
        recoveredFromBackup = false
        captureSavedConfig()
        refreshPendingFiles()
        startPendingWatcher()
        if showConfirmation { message = "设置已保存；修改监听文件夹后请点击“重新安装并启动”" }
    }

    func refreshStatus() {
        guard !busy else { return }
        let result = Self.runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/com.ai.filesorter"]
        )
        runtimeState = result.status == 0 ? .running : .stopped
    }

    // 识别 2.0.1 及更早版本指向 Application Support 副本的服务，打开新版时自动迁移。
    private func launchAgentNeedsFixedPathMigration() -> Bool {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ai.filesorter.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], let executable = arguments.first else {
            return true
        }
        return URL(fileURLWithPath: executable).standardizedFileURL != bundledAgentURL.standardizedFileURL
    }

    func installAndStart() {
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/AI File Sorter.app" else {
            message = "请先把 AI File Sorter.app 移到系统“应用程序”文件夹，再安装自动整理服务"
            return
        }
        do { try saveConfig(showConfirmation: false) }
        catch { message = "保存失败：\(error.localizedDescription)"; return }
        let watchPath = NSString(string: config.watchFolder).expandingTildeInPath
        let agentURL = bundledAgentURL
        let organizationMode = config.organizationMode
        let automaticScanIntervalHours = config.automaticScanIntervalHours
        runBackground(title: "正在安装并启用原生自动整理…") { [configURL] in
            Self.installNativeAgent(
                agentURL: agentURL,
                configURL: configURL,
                watchPath: watchPath,
                organizationMode: organizationMode,
                automaticScanIntervalHours: automaticScanIntervalHours
            )
        }
    }

    func stopAutomation() {
        runBackground(title: "正在停止自动整理…") {
            Self.runProcess(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/com.ai.filesorter"])
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
        runtimeState = .scanning
        generateOrganizingPlan()
        runtimeState = organizingPlan.isEmpty ? (automationEnabled ? .running : .stopped) : .awaitingConfirmation
        showOrganizingPlan = true
    }

    private func runBackground(
        title: String,
        operation: @escaping () -> ProcessResult,
        completion: ((ProcessResult) -> Void)? = nil
    ) {
        busy = true
        if title.contains("扫描") { runtimeState = .scanning }
        else if title.contains("整理") || title.contains("移动") || title.contains("撤销") { runtimeState = .organizing }
        message = title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = operation()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.refreshStatus()
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

    // 待分类是常驻收件箱，不弹窗；保留用户尚未保存的关键词和目标编辑。
    func refreshPendingFiles() {
        guard !busy else { return }
        let folder = URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath, isDirectory: true)
        let files = supportedFiles(in: folder)
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredDefaultsKey) ?? [])
        let existing = Dictionary(uniqueKeysWithValues: pendingFiles.map { ($0.path, $0) })
        let mode = OrganizationMode(rawValue: config.organizationMode) ?? .review
        pendingFiles = files.lazy.filter { self.fileEligibility($0) == .eligible }
            .filter {
                switch mode {
                case .review: return self.matchesAnyRule(fileURL: $0)
                case .manual, .automatic: return !self.matchesAnyRule(fileURL: $0)
                }
            }
            .filter { !ignored.contains(self.fileSignatureKey($0)) }
            .prefix(200).map { file in
            if let preserved = existing[file.path] { return preserved }
            let match = matchingRule(fileURL: file)
            let keyword = match?.element.keywords.first(where: {
                file.lastPathComponent.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }) ?? suggestedKeyword(for: file)
            return PendingFile(
                path: file.path,
                fileName: file.lastPathComponent,
                keyword: keyword,
                target: match?.element.target ?? "~/Documents/资料库/\(keyword)"
            )
        }
    }

    private func matchesAnyRule(fileURL: URL) -> Bool {
        matchingRule(fileURL: fileURL) != nil
    }

    private func matchingRule(fileName: String) -> (offset: Int, element: SorterRule)? {
        config.rules.enumerated().first { _, rule in rule.matches(fileName: fileName) }
    }

    private func matchingRule(fileURL: URL) -> (offset: Int, element: SorterRule)? {
        config.rules.enumerated().first { _, rule in rule.matches(fileURL: fileURL) }
    }

    private func fileSignatureKey(_ file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000_000)
        return "\(file.path)|\(size)|\(modified)"
    }

    private func pathMatches(_ file: URL, configuredPath: String) -> Bool {
        let expanded = NSString(string: configuredPath).expandingTildeInPath
        let configured = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let candidate = file.standardizedFileURL.path
        let prefix = configured == "/" ? "/" : (configured.hasSuffix("/") ? configured : configured + "/")
        return candidate == configured || candidate.hasPrefix(prefix)
    }

    private func fileEligibility(_ file: URL) -> FileEligibility {
        if config.excludedPaths.contains(where: { pathMatches(file, configuredPath: $0) }) { return .excluded }
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isUserImmutableKey]
        guard let values = try? file.resourceValues(forKeys: keys) else { return .recentlyModified }
        if values.isUserImmutable == true { return .locked }
        let now = Date()
        let modified = values.contentModificationDate ?? values.creationDate ?? now
        let ageReference = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? modified
        if config.retentionDays > 0,
           now.timeIntervalSince(ageReference) < Double(config.retentionDays) * 86_400 { return .tooYoung }
        if config.recentModificationProtectionHours > 0,
           now.timeIntervalSince(modified) < Double(config.recentModificationProtectionHours) * 3_600 { return .recentlyModified }
        return .eligible
    }

    private func fileAgeDays(_ file: URL) -> Int {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? file.resourceValues(forKeys: keys)
        let reference = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max() ?? Date()
        return max(0, Int(Date().timeIntervalSince(reference) / 86_400))
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

    private func supportedFiles(in folder: URL) -> [URL] {
        let supported = Set(config.supportedExtensions.map { $0.lowercased() })
        let temporarySuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files.filter {
            let regular = (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            let lowerName = $0.lastPathComponent.lowercased()
            return regular && !$0.lastPathComponent.hasPrefix(".")
                && !temporarySuffixes.contains(where: { lowerName.hasSuffix($0) })
                && supported.contains("." + $0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
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
            ruleTestResult = "未匹配任何启用的规则，文件会进入待分类。"
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
            let folder = URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath, isDirectory: true)
            let files = supportedFiles(in: folder)
            let affected = files.filter { file in imported.contains(where: { $0.matches(fileURL: file) }) }.count
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
            预计影响当前监听目录：\(affected) 个文件

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
        guard !items.isEmpty else { message = "请选择仍在待分类列表中的文件"; return }
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
        let folder = URL(fileURLWithPath: NSString(string: config.watchFolder).expandingTildeInPath, isDirectory: true)
        organizingPlan = supportedFiles(in: folder).prefix(300).compactMap { file in
            guard fileEligibility(file) == .eligible else { return nil }
            guard let match = matchingRule(fileURL: file) else { return nil }
            let target = URL(
                fileURLWithPath: NSString(string: match.element.target).expandingTildeInPath,
                isDirectory: true
            )
            let destination = target.appendingPathComponent(renamedFileName(file.lastPathComponent, rule: match.element))
            let status: String
            if FileManager.default.fileExists(atPath: destination.path) {
                status = "重名，将自动编号"
            } else if FileManager.default.fileExists(atPath: target.path), !FileManager.default.isWritableFile(atPath: target.path) {
                status = "目标不可写"
            } else {
                status = "可以整理"
            }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let fileSize = UInt64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate ?? values?.creationDate ?? Date()
            return OrganizingPlanItem(
                id: file.path, sourcePath: file.path, fileName: file.lastPathComponent,
                ruleName: match.element.name, destinationPath: destination.path,
                status: status, fileSize: fileSize, modifiedAt: modifiedAt,
                ageDays: fileAgeDays(file), selected: status != "目标不可写"
            )
        }
        message = organizingPlan.isEmpty ? "当前没有会被规则整理的文件" : "已生成 \(organizingPlan.count) 项整理计划"
    }

    func executeOrganizingPlan() {
        let selectedItems = organizingPlan.filter(\.selected)
        var missing = 0
        var changed = 0
        let paths = selectedItems.compactMap { item -> String? in
            guard FileManager.default.fileExists(atPath: item.sourcePath) else { missing += 1; return nil }
            let values = try? URL(fileURLWithPath: item.sourcePath).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if UInt64(values?.fileSize ?? 0) != item.fileSize || values?.contentModificationDate != item.modifiedAt { changed += 1 }
            return item.sourcePath
        }
        guard !paths.isEmpty else { message = "请至少选择一个可以整理的文件"; return }
        if missing > 0 || changed > 0 {
            let alert = NSAlert()
            alert.messageText = "整理前文件状态发生变化"
            alert.informativeText = "不存在：\(missing) 个；最近被修改：\(changed) 个。不存在的文件会跳过，已修改的文件仍可继续整理。"
            alert.addButton(withTitle: "仍然执行")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                message = "已取消本次整理"
                return
            }
        }
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
        var rows: [String] = []
        let agent = bundledAgentURL
        let native = Self.runProcess(executable: agent.path, arguments: ["--config", configURL.path, "--check-config"])
        rows.append(native.status == 0 ? "✓ 原生整理引擎从 App 固定位置运行" : "✕ 原生整理引擎不可用，请重新安装 App")

        let installed = Bundle.main.bundleURL.path == "/Applications/AI File Sorter.app"
        rows.append(installed ? "✓ App 已安装在固定位置 /Applications" : "△ 建议将 App 移到 /Applications 后重新安装服务")

        let manager = FileManager.default
        let watchPath = NSString(string: config.watchFolder).expandingTildeInPath
        let watchOK = manager.isReadableFile(atPath: watchPath) && manager.isWritableFile(atPath: watchPath)
        rows.append(watchOK ? "✓ 监听文件夹可读写：\(watchPath)" : "✕ 监听文件夹不可读写：\(watchPath)")

        var unavailableTargets = 0
        for rule in config.rules {
            let target = NSString(string: rule.target).expandingTildeInPath
            var probe = URL(fileURLWithPath: target, isDirectory: true)
            while !manager.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
            if !manager.isWritableFile(atPath: probe.path) { unavailableTargets += 1 }
        }
        rows.append(unavailableTargets == 0 ? "✓ 所有规则的目标路径可创建或写入" : "✕ \(unavailableTargets) 条规则的目标路径没有写入权限")

        refreshStatus()
        rows.append(automationEnabled ? "✓ 自动整理服务已加载" : "△ 自动整理服务尚未加载")
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

    nonisolated private static func installNativeAgent(
        agentURL: URL,
        configURL: URL,
        watchPath: String,
        organizationMode: String,
        automaticScanIntervalHours: Int
    ) -> ProcessResult {
        let manager = FileManager.default
        let agents = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = agents.appendingPathComponent("com.ai.filesorter.plist")
        let logs = configURL.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        do {
            try manager.createDirectory(at: agents, withIntermediateDirectories: true)
            try manager.createDirectory(at: logs, withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "Label": "com.ai.filesorter",
                "ProgramArguments": [agentURL.path, "--config", configURL.path],
                "RunAtLoad": true,
                "WatchPaths": [watchPath, configURL.path],
                "WorkingDirectory": configURL.deletingLastPathComponent().path,
                "ProcessType": "Background",
                "ThrottleInterval": 5,
                "StandardOutPath": logs.appendingPathComponent("launchd.out.log").path,
                "StandardErrorPath": logs.appendingPathComponent("launchd.err.log").path,
            ]
            if organizationMode == "automatic", automaticScanIntervalHours > 0 {
                plist["StartInterval"] = max(60, automaticScanIntervalHours * 3_600)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            _ = runProcess(executable: "/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/com.ai.filesorter"])
            let result = runProcess(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
            if result.status == 0 {
                // 旧版本曾把 Agent 复制到这里；新服务加载成功后再清理，避免中断迁移。
                let oldAgent = configURL.deletingLastPathComponent().appendingPathComponent("AIFileSorterAgent")
                try? manager.removeItem(at: oldAgent)
                return ProcessResult(status: 0, output: "原生自动整理已从 App 固定位置启动。")
            }
            return result
        } catch {
            return ProcessResult(status: 1, output: error.localizedDescription)
        }
    }
}

