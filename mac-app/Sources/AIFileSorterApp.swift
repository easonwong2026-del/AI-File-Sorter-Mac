// AI File Sorter 原生 macOS 前端：管理规则、启动状态、存量整理和日志。

import AppKit
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var previewURL: URL?

    func show(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path), let panel = QLPreviewPanel.shared() else { return }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        model.showQuitConfirmation = true
        return .terminateLater
    }
}

struct RenameOptions: Codable, Equatable {
    var enabled: Bool
    var template: String
    var dateFormat: String

    enum CodingKeys: String, CodingKey {
        case enabled, template
        case dateFormat = "date_format"
    }
}

enum OrganizationMode: String, CaseIterable, Identifiable {
    case manual
    case review
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "仅手动整理"
        case .review: return "自动扫描，整理前确认"
        case .automatic: return "完全自动整理"
        }
    }

    var detail: String {
        switch self {
        case .manual: return "后台不会自动移动文件，只保留手动扫描和整理。"
        case .review: return "后台只负责发现符合条件的文件，确认后才会移动。"
        case .automatic: return "后台会按规则自动整理符合安全条件的文件。"
        }
    }
}

enum SorterRuntimeState: String {
    case stopped
    case running
    case temporarilyPaused
    case scanning
    case awaitingConfirmation
    case organizing
    case error

    var isServiceEnabled: Bool {
        switch self {
        case .running, .scanning, .awaitingConfirmation, .organizing: return true
        case .stopped, .temporarilyPaused, .error: return false
        }
    }

    var title: String {
        switch self {
        case .stopped: return "文件整理已停止"
        case .running: return "文件整理运行中"
        case .temporarilyPaused: return "文件整理已临时暂停"
        case .scanning: return "正在扫描文件"
        case .awaitingConfirmation: return "等待确认整理"
        case .organizing: return "正在整理文件"
        case .error: return "整理服务出现问题"
        }
    }

    var detail: String {
        switch self {
        case .stopped: return "不会自动扫描或移动任何文件。"
        case .running: return "后台会按当前模式处理文件。"
        case .temporarilyPaused: return "暂停结束后会恢复之前的整理模式。"
        case .scanning: return "正在读取文件状态，不会跳过安全检查。"
        case .awaitingConfirmation: return "文件已经列入待整理列表，等待你的确认。"
        case .organizing: return "正在执行已确认的文件操作。"
        case .error: return "请打开设置中的环境检查或查看技术日志。"
        }
    }
}

private func splitRuleList(_ value: String) -> [String] {
    value.split(whereSeparator: { $0 == "," || $0 == "，" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

struct SorterRule: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var matchMode: String
    var keywords: [String]
    var excludeKeywords: [String]
    var extensions: [String]
    var nameRegex: String
    var minimumSizeMB: Double?
    var maximumSizeMB: Double?
    var modifiedOlderThanDays: Int?
    var modifiedNewerThanDays: Int?
    var finderTags: [String]
    var target: String

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, keywords, target, extensions
        case nameRegex = "name_regex"
        case minimumSizeMB = "minimum_size_mb"
        case maximumSizeMB = "maximum_size_mb"
        case modifiedOlderThanDays = "modified_older_than_days"
        case modifiedNewerThanDays = "modified_newer_than_days"
        case finderTags = "finder_tags"
        case matchMode = "match_mode"
        case excludeKeywords = "exclude_keywords"
    }

    init(
        id: UUID = UUID(), name: String = "未命名规则", enabled: Bool = true, matchMode: String = "any",
        keywords: [String], excludeKeywords: [String] = [], extensions: [String] = [],
        nameRegex: String = "", minimumSizeMB: Double? = nil, maximumSizeMB: Double? = nil,
        modifiedOlderThanDays: Int? = nil, modifiedNewerThanDays: Int? = nil,
        finderTags: [String] = [], target: String
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchMode = matchMode
        self.keywords = keywords
        self.excludeKeywords = excludeKeywords
        self.extensions = extensions
        self.nameRegex = nameRegex
        self.minimumSizeMB = minimumSizeMB
        self.maximumSizeMB = maximumSizeMB
        self.modifiedOlderThanDays = modifiedOlderThanDays
        self.modifiedNewerThanDays = modifiedNewerThanDays
        self.finderTags = finderTags
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchMode = try container.decodeIfPresent(String.self, forKey: .matchMode) ?? "any"
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? keywords.first ?? "未命名规则"
        excludeKeywords = try container.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? []
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        nameRegex = try container.decodeIfPresent(String.self, forKey: .nameRegex) ?? ""
        minimumSizeMB = try container.decodeIfPresent(Double.self, forKey: .minimumSizeMB)
        maximumSizeMB = try container.decodeIfPresent(Double.self, forKey: .maximumSizeMB)
        modifiedOlderThanDays = try container.decodeIfPresent(Int.self, forKey: .modifiedOlderThanDays)
        modifiedNewerThanDays = try container.decodeIfPresent(Int.self, forKey: .modifiedNewerThanDays)
        finderTags = try container.decodeIfPresent([String].self, forKey: .finderTags) ?? []
        target = try container.decode(String.self, forKey: .target)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(matchMode, forKey: .matchMode)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(excludeKeywords, forKey: .excludeKeywords)
        try container.encode(extensions, forKey: .extensions)
        if !nameRegex.isEmpty { try container.encode(nameRegex, forKey: .nameRegex) }
        try container.encodeIfPresent(minimumSizeMB, forKey: .minimumSizeMB)
        try container.encodeIfPresent(maximumSizeMB, forKey: .maximumSizeMB)
        try container.encodeIfPresent(modifiedOlderThanDays, forKey: .modifiedOlderThanDays)
        try container.encodeIfPresent(modifiedNewerThanDays, forKey: .modifiedNewerThanDays)
        if !finderTags.isEmpty { try container.encode(finderTags, forKey: .finderTags) }
        try container.encode(target, forKey: .target)
    }

    func matches(fileName: String) -> Bool {
        matchesBasic(fileName: fileName)
    }

    func matches(fileURL: URL) -> Bool {
        guard matchesBasic(fileName: fileURL.lastPathComponent) else { return false }
        guard usesMetadataConditions else { return true }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys) else { return false }
        let sizeMB = Double(values.fileSize ?? 0) / 1_048_576
        if let minimumSizeMB, sizeMB < minimumSizeMB { return false }
        if let maximumSizeMB, sizeMB > maximumSizeMB { return false }
        if modifiedOlderThanDays != nil || modifiedNewerThanDays != nil {
            guard let modified = values.contentModificationDate else { return false }
            let age = Date().timeIntervalSince(modified) / 86_400
            if let modifiedOlderThanDays, age < Double(modifiedOlderThanDays) { return false }
            if let modifiedNewerThanDays, age > Double(modifiedNewerThanDays) { return false }
        }
        if !finderTags.isEmpty {
            let actual = Set((values.tagNames ?? []).map { $0.lowercased() })
            if !finderTags.contains(where: { actual.contains($0.lowercased()) }) { return false }
        }
        return true
    }

    private func matchesBasic(fileName: String) -> Bool {
        guard enabled else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if excludeKeywords.contains(where: { fileName.range(of: $0, options: options) != nil }) { return false }
        if !nameRegex.isEmpty,
           fileName.range(of: nameRegex, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if !extensions.isEmpty {
            let ext = "." + URL(fileURLWithPath: fileName).pathExtension.lowercased()
            if !extensions.contains(where: { ($0.hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()) == ext }) { return false }
        }
        if keywords.isEmpty { return !extensions.isEmpty || !nameRegex.isEmpty }
        return matchMode == "all"
            ? keywords.allSatisfy { fileName.range(of: $0, options: options) != nil }
            : keywords.contains { fileName.range(of: $0, options: options) != nil }
    }

    var usesMetadataConditions: Bool {
        minimumSizeMB != nil || maximumSizeMB != nil || modifiedOlderThanDays != nil
            || modifiedNewerThanDays != nil || !finderTags.isEmpty
    }

    var summaryText: String {
        var parts: [String] = []
        if !keywords.isEmpty { parts.append(keywords.joined(separator: "、")) }
        if !extensions.isEmpty { parts.append("扩展名：\(extensions.joined(separator: "、"))") }
        if !nameRegex.isEmpty { parts.append("正则：\(nameRegex)") }
        if usesMetadataConditions { parts.append("含大小/日期/标签条件") }
        return parts.isEmpty ? "尚未设置匹配条件" : parts.joined(separator: " · ")
    }
}

struct RuleExport: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let rules: [SorterRule]

    enum CodingKeys: String, CodingKey {
        case rules
        case formatVersion = "format_version"
        case exportedAt = "exported_at"
    }

    init(formatVersion: Int = 1, exportedAt: Date = Date(), rules: [SorterRule]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        rules = try c.decode([SorterRule].self, forKey: .rules)
    }
}

struct RuleValidationIssue: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct SorterConfig: Codable, Equatable {
    var configVersion: Int
    var note: String?
    var watchFolder: String
    var logFile: String
    var stateFile: String
    var historyFile: String
    var scanIntervalSeconds: Double
    var stableSeconds: Double
    var eventIdleSeconds: Double
    var maxEventRuntimeSeconds: Double
    var processExistingOnFirstStart: Bool
    var moveMethod: String
    var rename: RenameOptions
    var supportedExtensions: [String]
    var organizationMode: String
    var retentionDays: Int
    var recentModificationProtectionHours: Int
    var automaticScanIntervalHours: Int
    var excludedPaths: [String]
    var rules: [SorterRule]

    enum CodingKeys: String, CodingKey {
        case configVersion = "_config_version"
        case note = "_说明"
        case watchFolder = "watch_folder"
        case logFile = "log_file"
        case stateFile = "state_file"
        case historyFile = "history_file"
        case scanIntervalSeconds = "scan_interval_seconds"
        case stableSeconds = "stable_seconds"
        case eventIdleSeconds = "event_idle_seconds"
        case maxEventRuntimeSeconds = "max_event_runtime_seconds"
        case processExistingOnFirstStart = "process_existing_on_first_start"
        case moveMethod = "move_method"
        case rename
        case supportedExtensions = "supported_extensions"
        case organizationMode = "organization_mode"
        case retentionDays = "retention_days"
        case recentModificationProtectionHours = "recent_modification_protection_hours"
        case automaticScanIntervalHours = "automatic_scan_interval_hours"
        case excludedPaths = "excluded_paths"
        case rules
    }

    init(
        configVersion: Int, note: String?, watchFolder: String, logFile: String, stateFile: String, historyFile: String,
        scanIntervalSeconds: Double, stableSeconds: Double, eventIdleSeconds: Double,
        maxEventRuntimeSeconds: Double, processExistingOnFirstStart: Bool, moveMethod: String,
        rename: RenameOptions, supportedExtensions: [String], organizationMode: String,
        retentionDays: Int, recentModificationProtectionHours: Int, automaticScanIntervalHours: Int,
        excludedPaths: [String], rules: [SorterRule]
    ) {
        self.configVersion = configVersion
        self.note = note
        self.watchFolder = watchFolder
        self.logFile = logFile
        self.stateFile = stateFile
        self.historyFile = historyFile
        self.scanIntervalSeconds = scanIntervalSeconds
        self.stableSeconds = stableSeconds
        self.eventIdleSeconds = eventIdleSeconds
        self.maxEventRuntimeSeconds = maxEventRuntimeSeconds
        self.processExistingOnFirstStart = processExistingOnFirstStart
        self.moveMethod = moveMethod
        self.rename = rename
        self.supportedExtensions = supportedExtensions
        self.organizationMode = organizationMode
        self.retentionDays = retentionDays
        self.recentModificationProtectionHours = recentModificationProtectionHours
        self.automaticScanIntervalHours = automaticScanIntervalHours
        self.excludedPaths = excludedPaths
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.fallback
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        configVersion = storedVersion
        note = try c.decodeIfPresent(String.self, forKey: .note)
        watchFolder = try c.decodeIfPresent(String.self, forKey: .watchFolder) ?? d.watchFolder
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile) ?? d.logFile
        stateFile = try c.decodeIfPresent(String.self, forKey: .stateFile) ?? d.stateFile
        historyFile = try c.decodeIfPresent(String.self, forKey: .historyFile) ?? d.historyFile
        scanIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .scanIntervalSeconds) ?? d.scanIntervalSeconds
        stableSeconds = try c.decodeIfPresent(Double.self, forKey: .stableSeconds) ?? d.stableSeconds
        eventIdleSeconds = try c.decodeIfPresent(Double.self, forKey: .eventIdleSeconds) ?? d.eventIdleSeconds
        maxEventRuntimeSeconds = try c.decodeIfPresent(Double.self, forKey: .maxEventRuntimeSeconds) ?? d.maxEventRuntimeSeconds
        processExistingOnFirstStart = try c.decodeIfPresent(Bool.self, forKey: .processExistingOnFirstStart) ?? d.processExistingOnFirstStart
        let storedMethod = try c.decodeIfPresent(String.self, forKey: .moveMethod) ?? d.moveMethod
        moveMethod = storedMethod == "python" ? "native" : storedMethod
        rename = try c.decodeIfPresent(RenameOptions.self, forKey: .rename) ?? d.rename
        supportedExtensions = try c.decodeIfPresent([String].self, forKey: .supportedExtensions) ?? d.supportedExtensions
        if storedVersion < 4 {
            for item in [".csv", ".tsv"] where !supportedExtensions.contains(item) { supportedExtensions.append(item) }
        }
        let storedMode = try c.decodeIfPresent(String.self, forKey: .organizationMode) ?? d.organizationMode
        organizationMode = OrganizationMode(rawValue: storedMode)?.rawValue ?? (storedVersion < 9 ? OrganizationMode.review.rawValue : d.organizationMode)
        retentionDays = max(0, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays)
        recentModificationProtectionHours = max(0, try c.decodeIfPresent(Int.self, forKey: .recentModificationProtectionHours) ?? d.recentModificationProtectionHours)
        automaticScanIntervalHours = max(0, try c.decodeIfPresent(Int.self, forKey: .automaticScanIntervalHours) ?? d.automaticScanIntervalHours)
        excludedPaths = (try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? d.excludedPaths)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        rules = try c.decodeIfPresent([SorterRule].self, forKey: .rules) ?? d.rules
        configVersion = 9
    }

    static let fallback = SorterConfig(
        configVersion: 9,
        note: "内置默认配置；所有预置规则均可在图形界面修改或删除。",
        watchFolder: "~/Downloads",
        logFile: "logs/sorter.log",
        stateFile: "logs/state.json",
        historyFile: "logs/history.json",
        scanIntervalSeconds: 2,
        stableSeconds: 4,
        eventIdleSeconds: 8,
        maxEventRuntimeSeconds: 900,
        processExistingOnFirstStart: false,
        moveMethod: "native",
        rename: RenameOptions(enabled: false, template: "{date}_{original_name}", dateFormat: "%Y-%m-%d"),
        supportedExtensions: [
            ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv", ".tsv", ".ppt", ".pptx",
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tif", ".tiff",
            ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".zip", ".rar", ".7z", ".tar", ".gz",
            ".dmg", ".pkg",
        ],
        organizationMode: OrganizationMode.review.rawValue,
        retentionDays: 7,
        recentModificationProtectionHours: 24,
        automaticScanIntervalHours: 24,
        excludedPaths: [],
        rules: [
            SorterRule(name: "财务票据", keywords: ["发票", "收据", "账单", "invoice", "receipt"], extensions: ["pdf", "jpg", "jpeg", "png", "heic"], target: "~/Documents/下载整理/财务票据"),
            SorterRule(name: "合同与协议", keywords: ["合同", "协议", "contract", "agreement"], extensions: ["pdf", "doc", "docx"], target: "~/Documents/下载整理/合同与协议"),
            SorterRule(name: "屏幕截图", keywords: ["截屏", "屏幕快照", "screenshot"], extensions: ["jpg", "jpeg", "png", "heic", "webp"], target: "~/Pictures/截图"),
            SorterRule(name: "下载图片", keywords: [], extensions: ["jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff"], target: "~/Pictures/下载图片"),
            SorterRule(name: "下载视频", keywords: [], extensions: ["mp4", "mov", "m4v", "avi", "mkv"], target: "~/Movies/下载视频"),
            SorterRule(name: "压缩文件", keywords: [], extensions: ["zip", "rar", "7z", "tar", "gz"], target: "~/Documents/下载整理/压缩文件"),
            SorterRule(name: "安装包", keywords: [], extensions: ["dmg", "pkg"], target: "~/Documents/下载整理/安装包"),
            SorterRule(name: "办公文档", keywords: [], extensions: ["pdf", "doc", "docx", "xls", "xlsx", "csv", "tsv", "ppt", "pptx"], target: "~/Documents/下载整理/办公文档"),
        ]
    )
}

struct ProcessResult {
    let status: Int32
    let output: String
}

// 待分类条目只保留界面需要的轻量字段，避免缓存文件内容。
struct PendingFile: Identifiable {
    var id: String { path }
    let path: String
    let fileName: String
    var keyword: String
    var target: String
    var selected = true
}

// 单个与批量整理共用同一份草稿，避免“最近目录”“批量移动”“建立规则”各走一套逻辑。
struct PendingMoveDraft: Identifiable {
    let id = UUID()
    let paths: [String]
    let fileNames: [String]
    let suggestedKeyword: String
    let suggestedTarget: String
}

enum FileEligibility: Equatable {
    case eligible
    case excluded
    case tooYoung
    case recentlyModified
    case locked
}

struct MoveHistory: Identifiable, Codable {
    let id: String
    let timestamp: Date
    var originalPath: String
    let destinationPath: String
    let reason: String
    var undone: Bool
    let batchID: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, originalPath, destinationPath, reason, undone
        case batchID = "batch_id"
    }
}

// 整理计划只缓存路径与短文本，不读取文件内容，关闭窗口后即可释放。
struct OrganizingPlanItem: Identifiable {
    let id: String
    let sourcePath: String
    let fileName: String
    let ruleName: String
    let destinationPath: String
    let status: String
    let fileSize: UInt64
    let modifiedAt: Date
    let ageDays: Int
    var selected: Bool
}

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

struct StatusCard: View {
    @ObservedObject var model: AppModel

    private var stateColor: Color {
        switch model.runtimeState {
        case .running, .awaitingConfirmation: return .green
        case .scanning, .organizing: return .blue
        case .temporarilyPaused: return .orange
        case .stopped, .error: return .orange
        }
    }

    private var stateIcon: String {
        switch model.runtimeState {
        case .running: return "checkmark.circle.fill"
        case .awaitingConfirmation: return "checkmark.circle.fill"
        case .scanning: return "magnifyingglass.circle.fill"
        case .organizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .temporarilyPaused: return "pause.circle.fill"
        case .stopped: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: stateIcon)
                .font(.system(size: 34))
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.runtimeState.title).font(.title3.bold())
                Text("当前模式：\(OrganizationMode(rawValue: model.config.organizationMode)?.title ?? "需要检查") · \(model.runtimeState.detail)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(
                get: { model.automationEnabled },
                set: { enabled in enabled ? model.installAndStart() : model.stopAutomation() }
            ))
            .toggleStyle(.switch)
            .disabled(model.busy)
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

// 兼容 macOS 13 的轻量空状态，避免引入仅 macOS 14 可用的 ContentUnavailableView。
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var detail = ""

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("设置").font(.largeTitle.bold())
                        if model.hasUnsavedChanges {
                            Text("未保存")
                                .font(.caption.bold()).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    Text("管理自动整理、监听目录、重命名和系统权限。")
                        .foregroundStyle(.secondary)
                }
                StatusCard(model: model)

                GroupBox("基本设置") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("监听文件夹").frame(width: 110, alignment: .leading)
                            TextField("~/Downloads", text: Binding(
                                get: { model.config.watchFolder }, set: { model.config.watchFolder = $0 }
                            ))
                            Button("选择…") {
                                model.chooseFolder(current: model.config.watchFolder) { model.config.watchFolder = $0 }
                            }
                        }
                        Picker("整理模式", selection: Binding(
                            get: { model.config.organizationMode },
                            set: { model.config.organizationMode = $0 }
                        )) {
                            ForEach(OrganizationMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Text((OrganizationMode(rawValue: model.config.organizationMode) ?? .review).detail)
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                        GroupBox("整理安全") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("文件保留时间").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.retentionDays },
                                        set: { model.config.retentionDays = max(0, $0) }
                                    ), in: 0...365) {
                                        Text(model.config.retentionDays == 0 ? "不延迟" : "\(model.config.retentionDays) 天")
                                            .monospacedDigit()
                                    }
                                    Text("新文件先保留，0 表示关闭").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("最近修改保护").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.recentModificationProtectionHours },
                                        set: { model.config.recentModificationProtectionHours = max(0, $0) }
                                    ), in: 0...720) {
                                        Text(model.config.recentModificationProtectionHours == 0 ? "不保护" : "\(model.config.recentModificationProtectionHours) 小时")
                                            .monospacedDigit()
                                    }
                                    Text("防止仍在编辑的文件被处理").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("自动扫描间隔").frame(width: 110, alignment: .leading)
                                    Stepper(value: Binding(
                                        get: { model.config.automaticScanIntervalHours },
                                        set: { model.config.automaticScanIntervalHours = max(0, $0) }
                                    ), in: 0...168) {
                                        Text(model.config.automaticScanIntervalHours == 0 ? "仅响应目录变化" : "每 \(model.config.automaticScanIntervalHours) 小时")
                                            .monospacedDigit()
                                    }
                                    Text("用于定期重新检查达到保留时间的文件").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("排除路径").frame(width: 110, alignment: .leading)
                                    TextField("多个路径用逗号分隔，例如 ~/Downloads/保留", text: Binding(
                                        get: { model.config.excludedPaths.joined(separator: ", ") },
                                        set: { model.config.excludedPaths = splitRuleList($0) }
                                    ))
                                }
                                Text("目标文件夹不能位于监听文件夹内；临时后缀、隐藏文件和排除路径始终跳过。")
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                            }
                            .padding(6)
                        }
                        Toggle("第一次启用时也整理 Downloads 中已有的文件", isOn: Binding(
                            get: { model.config.processExistingOnFirstStart },
                            set: { model.config.processExistingOnFirstStart = $0 }
                        ))
                        Toggle("自动添加日期前缀，例如 2026-07-16_文件名.pdf", isOn: Binding(
                            get: { model.config.rename.enabled }, set: { model.config.rename.enabled = $0 }
                        ))
                        if model.config.rename.enabled {
                            HStack {
                                Text("重命名模板").frame(width: 110, alignment: .leading)
                                TextField("{date}_{original_name}", text: Binding(
                                    get: { model.config.rename.template }, set: { model.config.rename.template = $0 }
                                ))
                            }
                            HStack {
                                Text("日期格式").frame(width: 110, alignment: .leading)
                                TextField("%Y-%m-%d", text: Binding(
                                    get: { model.config.rename.dateFormat }, set: { model.config.rename.dateFormat = $0 }
                                ))
                                Text("预览：\(model.renamedFileName("示例文件.pdf"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("可用变量：{date}、{original_name}、{extension}、{category}、{keyword}")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                        }
                        Picker("移动方式", selection: Binding(
                            get: { model.config.moveMethod }, set: { model.config.moveMethod = $0 }
                        )) {
                                Text("原生文件系统（推荐）").tag("native")
                            Text("Finder / AppleScript").tag("finder")
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("文件稳定等待")
                            Slider(value: Binding(
                                get: { model.config.stableSeconds }, set: { model.config.stableSeconds = $0 }
                            ), in: 1...15, step: 1)
                            Text("\(Int(model.config.stableSeconds)) 秒").monospacedDigit().frame(width: 46, alignment: .trailing)
                        }
                    }
                    .padding(10)
                }

                GroupBox("环境与权限") {
                    HStack(alignment: .top) {
                        Text(model.healthReport).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("开始检查") { model.runHealthCheck() }
                    }
                    .padding(10)
                }

                HStack(spacing: 10) {
                    Button("保存设置") { _ = model.saveCurrentConfiguration() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.hasUnsavedChanges)
                    if model.hasUnsavedChanges {
                        Text("按 ⌘S 保存修改").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("重新部署自动整理服务") { model.installAndStart() }.disabled(model.busy)
                }
                Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(22)
        }
    }
}

// 待分类收件箱把偶发单次移动与长期规则整理明确分开，不再用弹窗打断用户。
struct PendingInboxView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPath: String?
    @State private var showingPlan = false

    private var selectedCount: Int { model.pendingFiles.count(where: \.selected) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待分类").font(.title2.bold())
                        HStack(spacing: 7) {
                            Text("\(model.pendingFiles.count) 个文件").font(.caption).foregroundStyle(.secondary)
                            if selectedCount > 0 {
                                Text("已选 \(selectedCount) 项")
                                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    Spacer()
                    Button("整理计划") {
                        model.generateOrganizingPlan()
                        showingPlan = true
                    }
                    Button { model.refreshPendingFiles() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新")
                }.padding(16)
                Divider()
                if model.pendingFiles.isEmpty {
                    EmptyStateView(title: "已整理完毕", systemImage: "checkmark.circle", detail: "新的未匹配文件会出现在这里。")
                } else {
                    List(selection: $selectedPath) {
                        ForEach($model.pendingFiles) { $item in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $item.selected).labelsHidden()
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.fileName).lineLimit(1)
                                    Text(item.keyword).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(item.path)
                        }
                    }.listStyle(.sidebar)
                }
                Divider()
                HStack {
                    Text(selectedCount == 0 ? "勾选文件后可批量处理" : "将处理 \(selectedCount) 个所选文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("忽略 \(selectedCount) 项") { model.ignoreSelectedPending() }
                        .help("忽略所选的 \(selectedCount) 个文件")
                        .disabled(selectedCount == 0 || model.busy)
                    Button("整理 \(selectedCount) 项…") { model.moveSelectedOnce() }
                        .buttonStyle(.borderedProminent)
                        .help("整理所选的 \(selectedCount) 个文件")
                        .disabled(selectedCount == 0 || model.busy)
                }
                .padding(12)
                if model.busy {
                    ProgressView().controlSize(.small).padding(.bottom, 4)
                }
                Text(model.message)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .frame(minWidth: 270, idealWidth: 310)

            pendingDetail
        }
        .onAppear { if selectedPath == nil { selectedPath = model.pendingFiles.first?.path } }
        .onChange(of: model.pendingFiles.map(\.path)) { paths in
            if selectedPath == nil || !paths.contains(selectedPath ?? "") {
                selectedPath = paths.first
            }
        }
        .sheet(item: $model.pendingMoveDraft) { draft in
            PendingMoveSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $showingPlan) {
            OrganizingPlanView(model: model, isPresented: $showingPlan)
        }
    }

    @ViewBuilder private var pendingDetail: some View {
        if let path = selectedPath, let index = model.pendingFiles.firstIndex(where: { $0.path == path }) {
            let item = model.pendingFiles[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28)).foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.fileName).font(.title2.bold()).textSelection(.enabled)
                            Text(NSString(string: item.path).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Toggle("加入所选", isOn: Binding(
                            get: { model.pendingFiles[index].selected },
                            set: { model.pendingFiles[index].selected = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .help("将当前文件加入底部的批量整理或忽略操作")
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("建议整理到", systemImage: "folder")
                            .font(.headline)
                        Text(NSString(string: item.target).abbreviatingWithTildeInPath)
                            .font(.title3.weight(.medium)).textSelection(.enabled).lineLimit(2)
                        Text("整理时可改用最近目录或 Finder 选择其他位置，并可选择保存为自动规则。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

                    Divider()
                    HStack {
                        Button("快速预览") { model.quickLookPending(item) }
                            .keyboardShortcut(.space, modifiers: [])
                        Button("在 Finder 显示") { model.revealPending(item) }
                    }
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
            }
        } else {
            EmptyStateView(title: "选择一个文件", systemImage: "doc.text.magnifyingglass", detail: "查看建议位置或建立自动规则。")
        }
    }
}

// 统一整理面板：目标选择与“是否保留规则”在一个地方完成，单个和批量操作完全一致。
struct PendingMoveSheet: View {
    @ObservedObject var model: AppModel
    let draft: PendingMoveDraft
    @State private var target: String
    @State private var saveAsRule = false
    @State private var keyword: String

    init(model: AppModel, draft: PendingMoveDraft) {
        self.model = model
        self.draft = draft
        _target = State(initialValue: draft.suggestedTarget)
        _keyword = State(initialValue: draft.suggestedKeyword)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("整理 \(draft.paths.count) 个文件").font(.title2.bold())
                Text(draft.fileNames.prefix(3).joined(separator: "、") + (draft.fileNames.count > 3 ? " 等" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            GroupBox("1. 移动到哪里") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("目标文件夹", text: $target)
                        Button("选择…") {
                            model.chooseFolder(current: target) { target = $0 }
                        }
                    }
                    if !model.recentTargetFolders.isEmpty {
                        HStack {
                            Text("最近目录").font(.caption).foregroundStyle(.secondary)
                            Menu("选择最近使用的目录") {
                                ForEach(model.recentTargetFolders, id: \.self) { value in
                                    Button(NSString(string: value).abbreviatingWithTildeInPath) { target = value }
                                }
                            }
                        }
                    }
                    Text(NSString(string: target).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(8)
            }

            GroupBox("2. 是否记住这次整理") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $saveAsRule) {
                        Text("只移动这一次").tag(false)
                        Text("保存自动规则，以后自动整理类似文件").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    if saveAsRule {
                        TextField("文件名关键词", text: $keyword)
                        Text("未来文件名包含“\(keyword.isEmpty ? "请填写关键词" : keyword)”且扩展名相同时，将自动移动到上面的目录。当前待分类中预计匹配 \(model.matchingPendingCount(keyword: keyword)) 个。")
                            .font(.caption).foregroundStyle(.secondary)
                        if draft.paths.count > 1 && draft.suggestedKeyword.isEmpty {
                            Label("所选文件没有可靠的共同关键词，请确认后手动填写。", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.padding(8)
            }

            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Spacer()
                Button("取消") { model.pendingMoveDraft = nil }.keyboardShortcut(.cancelAction)
                Button(saveAsRule ? "移动并保存规则" : "移动") {
                    _ = model.confirmPendingMove(draft: draft, target: target, saveAsRule: saveAsRule, keyword: keyword)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (saveAsRule && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 570)
    }
}

struct OrganizingPlanView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    private var selectedItems: [OrganizingPlanItem] { model.organizingPlan.filter(\.selected) }

    private var selectedSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(selectedItems.reduce(0) { $0 + $1.fileSize }, UInt64(Int64.max))), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("整理计划").font(.title2.bold())
                    Text("确认来源、规则和目标后再执行；取消不会移动任何文件。")
                        .foregroundStyle(.secondary)
                    Text("\(model.organizingPlan.count) 项 · 已选 \(selectedItems.count) 项 · \(selectedSizeText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") {
                    for index in model.organizingPlan.indices where model.organizingPlan[index].status != "目标不可写" {
                        model.organizingPlan[index].selected = true
                    }
                }
                Button("全不选") {
                    for index in model.organizingPlan.indices { model.organizingPlan[index].selected = false }
                }
            }

            if model.organizingPlan.isEmpty {
                EmptyStateView(title: "没有可执行项目", systemImage: "checkmark.circle", detail: "当前文件没有命中启用的规则。")
            } else {
                List {
                    ForEach($model.organizingPlan) { $item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: $item.selected).labelsHidden()
                                .disabled(item.status == "目标不可写")
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.fileName).font(.headline).lineLimit(1)
                                    Text(item.ruleName).font(.caption)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text("→ \(NSString(string: item.destinationPath).abbreviatingWithTildeInPath)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("文件年龄 \(item.ageDays) 天 · \(ByteCountFormatter.string(fromByteCount: Int64(min(item.fileSize, UInt64(Int64.max))), countStyle: .file)) · 修改于 \(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(item.status).font(.caption)
                                .foregroundStyle(item.status == "可以整理" ? Color.secondary : Color.orange)
                        }.padding(.vertical, 5)
                    }
                }.listStyle(.inset)
            }

            HStack {
                Text("已选择 \(selectedItems.count) 项 · \(selectedSizeText)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { isPresented = false }
                Button("确认整理") {
                    model.executeOrganizingPlan()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.organizingPlan.contains(where: \.selected))
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 540)
        .onDisappear { if !model.busy { model.organizingPlan = [] } }
    }
}

struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var showingPreview = false
    @State private var showingDiagnostics = false
    @State private var expandedRuleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                    VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("自动化规则（\(model.config.rules.count)）").font(.title2.bold())
                        if model.hasUnsavedChanges {
                            Text("未保存")
                                .font(.caption.bold()).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    Text("规则按顺序匹配。点击一条规则展开编辑，常用信息保持简洁。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("规则管理") {
                    Button("导出规则…") { model.exportRules() }
                    Button("导入规则…") { model.importRules() }
                    Button("复制给 AI 的规则需求模板") { model.copyAIRulePrompt() }
                    Divider()
                    Button("恢复上次备份") { model.restoreRuleBackup() }
                    Button("恢复默认规则") { model.restoreDefaultRules() }
                }
                Button("检查冲突") {
                    model.analyzeRuleConflicts()
                    showingDiagnostics = true
                }
                Button {
                    model.generateOrganizingPlan()
                    showingPreview = true
                } label: { Label("整理计划", systemImage: "checklist") }
                Button {
                    withAnimation {
                        model.config.rules.insert(
                            SorterRule(name: "新规则", keywords: ["新关键词"], target: "~/Documents/下载整理/新分类"),
                            at: 0
                        )
                        expandedRuleID = model.config.rules.first?.id
                    }
                    model.message = "已在顶部添加新规则；编辑后请点击“保存规则”"
                } label: { Label("添加规则", systemImage: "plus") }
            }

            List {
                ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { index, rule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("启用", isOn: Binding(
                                get: { rule.enabled },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].enabled = value
                                    }
                                }
                            )).toggleStyle(.switch).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).font(.headline)
                                Text(rule.summaryText)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                withAnimation { expandedRuleID = expandedRuleID == rule.id ? nil : rule.id }
                            } label: {
                                Image(systemName: expandedRuleID == rule.id ? "chevron.up" : "chevron.down")
                            }.buttonStyle(.borderless).help("展开或收起")
                            Button {
                                if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                    var copy = model.config.rules[current]
                                    copy.id = UUID()
                                    model.config.rules.insert(copy, at: current + 1)
                                }
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("复制规则")
                            Button(role: .destructive) {
                                model.config.rules.removeAll { $0.id == rule.id }
                                model.message = "规则已删除；点击“保存规则”后生效"
                            } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        if expandedRuleID == rule.id {
                        HStack {
                            Text("名称").frame(width: 72, alignment: .leading)
                            TextField("规则名称", text: Binding(
                                get: { rule.name },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].name = value
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("匹配方式").frame(width: 72, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { rule.matchMode },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].matchMode = value
                                    }
                                }
                            )) {
                                Text("任意关键词").tag("any")
                                Text("全部关键词").tag("all")
                            }.pickerStyle(.segmented).frame(maxWidth: 280)
                        }
                        HStack {
                            Text("关键词").frame(width: 72, alignment: .leading)
                            TextField("合同, invoice, 项目名称", text: Binding(
                                get: { rule.keywords.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].keywords = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("排除词").frame(width: 72, alignment: .leading)
                            TextField("模板, 草稿（可留空）", text: Binding(
                                get: { rule.excludeKeywords.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].excludeKeywords = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        HStack {
                            Text("扩展名").frame(width: 72, alignment: .leading)
                            TextField("pdf, docx（留空表示全部支持类型）", text: Binding(
                                get: { rule.extensions.joined(separator: ", ") },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].extensions = splitRuleList(value)
                                    }
                                }
                            ))
                        }
                        DisclosureGroup("更多条件（可选）") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("名称正则").frame(width: 72, alignment: .leading)
                                    TextField(#"例如 ^项目.*\.pdf$"#, text: Binding(
                                        get: { rule.nameRegex },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].nameRegex = value
                                            }
                                        }
                                    ))
                                }
                                HStack {
                                    Text("文件大小").frame(width: 72, alignment: .leading)
                                    TextField("最小 MB", value: Binding(
                                        get: { rule.minimumSizeMB },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].minimumSizeMB = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    Text("至").foregroundStyle(.secondary)
                                    TextField("最大 MB", value: Binding(
                                        get: { rule.maximumSizeMB },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].maximumSizeMB = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                }
                                HStack {
                                    Text("修改时间").frame(width: 72, alignment: .leading)
                                    TextField("早于天数", value: Binding(
                                        get: { rule.modifiedOlderThanDays },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].modifiedOlderThanDays = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    TextField("最近天数", value: Binding(
                                        get: { rule.modifiedNewerThanDays },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].modifiedNewerThanDays = value
                                            }
                                        }
                                    ), format: .number).frame(width: 110)
                                    Text("留空表示不限").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("Finder 标签").frame(width: 72, alignment: .leading)
                                    TextField("工作, 重要（任一标签命中）", text: Binding(
                                        get: { rule.finderTags.joined(separator: ", ") },
                                        set: { value in
                                            if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.config.rules[current].finderTags = splitRuleList(value)
                                            }
                                        }
                                    ))
                                }
                            }.padding(.top, 6)
                        }
                        HStack {
                            Text("目标").frame(width: 72, alignment: .leading)
                            TextField("~/Documents/资料库/分类", text: Binding(
                                get: { rule.target },
                                set: { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].target = value
                                    }
                                }
                            ))
                            Button("选择…") {
                                model.chooseFolder(current: rule.target) { value in
                                    if let current = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.config.rules[current].target = value
                                    }
                                }
                            }
                        }
                        let issues = model.ruleValidationIssues(for: rule, at: index)
                        if !issues.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(issues) { issue in
                                    Label(issue.text, systemImage: issue.isError ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(issue.isError ? .red : .orange)
                                }
                            }
                            .padding(.leading, 72)
                        }
                        }
                    }
                    .padding(.vertical, 8)
                    .opacity(rule.enabled ? 1 : 0.58)
                }
                .onMove { source, destination in model.config.rules.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.inset)

            HStack {
                Button("保存规则") { _ = model.saveCurrentConfiguration() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !model.hasUnsavedChanges)
                if model.hasUnsavedChanges {
                    Text("按 ⌘S 保存修改").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.message).font(.callout).foregroundStyle(.secondary)
            }

            GroupBox("文件名测试") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("输入完整文件名，例如 Samsung_S95F_报价单.pdf", text: $model.ruleTestFileName)
                        Button("测试") { model.testRuleMatch() }
                    }
                    Text(model.ruleTestResult).font(.callout).textSelection(.enabled)
                }.padding(6)
            }

            if showingDiagnostics {
                GroupBox("规则检查结果") {
                    HStack(alignment: .top) {
                        Text(model.ruleDiagnostics).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("关闭") { showingDiagnostics = false }
                    }.padding(6)
                }
            }
        }
        .padding(22)
        .sheet(isPresented: $showingPreview) {
            OrganizingPlanView(model: model, isPresented: $showingPreview)
        }
    }
}

struct LogsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行日志").font(.title2.bold())
                Spacer()
                Button("打开日志文件夹") { model.openLogsFolder() }
                Button("刷新") { model.refreshLog() }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(model.logText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("打开 Downloads") { model.openDownloadsFolder() }
                Spacer()
                Text(model.runtimeState.title).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .onAppear { model.refreshLog() }
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var showingLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("整理记录（\(model.historyRecords.count)）").font(.title2.bold())
                    Text("最多保留最近 500 条移动记录；撤销时如原位置已有同名文件，会自动避免覆盖。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即整理") { model.sortExistingNow() }.disabled(model.busy)
                Button("撤销最近批次") { model.undoLatestBatch() }
                    .disabled(model.busy || model.latestUndoableBatchID == nil)
                Button("技术日志") { showingLogs = true }
                Button("刷新") { model.refreshHistory() }
            }
            if model.historyRecords.isEmpty {
                EmptyStateView(title: "暂无整理历史", systemImage: "clock.arrow.circlepath")
            } else {
                List(model.historyRecords) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(URL(fileURLWithPath: record.destinationPath).lastPathComponent).font(.headline)
                            Text(record.reason).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            if record.undone { Text("已撤销").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("原位置：\(NSString(string: record.originalPath).abbreviatingWithTildeInPath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("目标：\(NSString(string: record.destinationPath).abbreviatingWithTildeInPath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Button("在 Finder 中显示") { model.revealHistoryFile(record) }
                            Button("撤销") { model.undoMove(record) }
                                .disabled(record.undone || model.busy || !FileManager.default.fileExists(atPath: record.destinationPath))
                        }
                    }
                    .padding(.vertical, 7)
                }
                .listStyle(.inset)
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(22)
        .onAppear { model.refreshHistory() }
        .sheet(isPresented: $showingLogs) {
            LogsView(model: model).frame(minWidth: 760, minHeight: 520)
        }
    }
}

enum SidebarSection: String, Hashable {
    case pending, rules, activity, settings
}

// 2.3 使用稳定的侧边栏信息架构，把日常整理与低频设置明确分开。
struct SidebarContentView: View {
    @ObservedObject var model: AppModel
    @State private var section: SidebarSection? = .pending
    @State private var requestedSection: SidebarSection?
    @State private var showingNavigationConfirmation = false
    @AppStorage("didShowWelcomeV23") private var didShowWelcome = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { section },
                    set: { requested in
                        guard let requested, requested != section else { return }
                        if model.hasUnsavedChanges {
                            requestedSection = requested
                            showingNavigationConfirmation = true
                        } else {
                            section = requested
                        }
                    }
                )) {
                    Section("整理") {
                        Label {
                            HStack {
                                Text("待分类")
                                Spacer()
                                if !model.pendingFiles.isEmpty {
                                    Text("\(model.pendingFiles.count)")
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        } icon: { Image(systemName: "tray.full") }
                        .tag(SidebarSection.pending)
                        Label("自动化规则", systemImage: "list.bullet.rectangle").tag(SidebarSection.rules)
                        Label("整理记录", systemImage: "clock.arrow.circlepath").tag(SidebarSection.activity)
                    }
                    Section("应用") {
                        Label("设置", systemImage: "gearshape").tag(SidebarSection.settings)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.automationEnabled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.runtimeState.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            switch section ?? .pending {
            case .pending: PendingInboxView(model: model)
            case .rules: RulesView(model: model)
            case .activity: HistoryView(model: model)
            case .settings: OverviewView(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: Binding(
            get: { !didShowWelcome },
            set: { if !$0 { didShowWelcome = true } }
        )) {
            WelcomeView { didShowWelcome = true }
        }
        .sheet(isPresented: $model.showOrganizingPlan) {
            OrganizingPlanView(model: model, isPresented: $model.showOrganizingPlan)
        }
        .alert("未保存的修改", isPresented: $showingNavigationConfirmation) {
            Button("保存并继续") {
                if model.saveCurrentConfiguration() { section = requestedSection }
                requestedSection = nil
            }
            Button("放弃修改", role: .destructive) {
                model.discardUnsavedChanges()
                section = requestedSection
                requestedSection = nil
            }
            Button("取消", role: .cancel) { requestedSection = nil }
        } message: {
            Text("切换页面前请保存设置，或放弃本次未保存的修改。")
        }
        .alert("未保存的修改", isPresented: $model.showQuitConfirmation) {
            Button("保存并退出") {
                if model.saveCurrentConfiguration() { NSApp.reply(toApplicationShouldTerminate: true) }
                else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
            Button("放弃修改", role: .destructive) {
                model.discardUnsavedChanges()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            Button("取消", role: .cancel) { NSApp.reply(toApplicationShouldTerminate: false) }
        } message: {
            Text("退出前请保存设置，或放弃本次未保存的修改。")
        }
    }
}

// 首次引导只解释核心工作流，避免把高级设置一次性塞给新用户。
struct WelcomeView: View {
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 42)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 AI File Sorter").font(.title.bold())
                    Text("先处理待分类文件，再把重复动作变成自动化规则。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Label("“待分类”支持一次性移动，也能顺手建立长期规则。", systemImage: "1.circle.fill")
                Label("内置规则是图片、视频、压缩包等通用方案，可随时修改。", systemImage: "2.circle.fill")
                Label("也可以让外部 AI 根据你的目录生成 JSON，再从规则页导入。", systemImage: "3.circle.fill")
            }

            GroupBox {
                Label("应用默认不上传文件名、目录或内容，也不会自动调用任何 AI 服务。", systemImage: "hand.raised.fill")
                    .font(.callout).foregroundStyle(.secondary).padding(6)
            }

            HStack {
                Spacer()
                Button("开始使用") { finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 610)
    }
}

@main
struct AIFileSorterApplication: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup("AI File Sorter") {
            SidebarContentView(model: model)
                .onAppear { applicationDelegate.model = model }
        }
            .windowStyle(.titleBar)
            .defaultSize(width: 900, height: 700)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandGroup(replacing: .saveItem) {
                    Button("保存当前设置") { _ = model.saveCurrentConfiguration() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.hasUnsavedChanges)
                }
            }

        MenuBarExtra("AI File Sorter", systemImage: model.automationEnabled ? "folder.fill.badge.checkmark" : "folder.badge.gearshape") {
            Text(model.runtimeState.title)
            Text((OrganizationMode(rawValue: model.config.organizationMode) ?? .review).title)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("立即扫描（不移动）") { model.scanOnly() }
                .disabled(model.busy)
            Button("立即整理现有文件") { model.sortExistingNow() }
                .disabled(model.busy)
            if model.automationEnabled {
                Button("停止整理") { model.stopAutomation() }
            } else {
                Button("开始整理") { model.installAndStart() }
            }
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("打开 Downloads") { model.openDownloadsFolder() }
            Divider()
            Button("退出控制面板") { NSApp.terminate(nil) }
        }
    }
}
