import AppKit
import Combine
import Foundation
import Darwin
@preconcurrency import QuickLookUI
import SwiftUI

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
        case .manual: return "只提供整理建议"
        case .review: return "整理前让我确认"
        case .automatic: return "自动整理"
        }
    }

    var detail: String {
        switch self {
        case .manual: return "后台服务启用时只提供整理建议和单次整理入口，不会自动移动文件。"
        case .review: return "后台服务启用时生成整理建议，移动前需要你确认。"
        case .automatic: return "后台服务启用时，符合安全条件的文件会按规则自动整理。"
        }
    }
}

/// 用于把 v9 及更早配置中的“是否启用后台服务”从 LaunchAgent 运行状态迁移出来。
///
/// `serviceProbeSucceeded == false` 时仍然安全返回关闭，调用方可以在下一次安全保存时
/// 写入明确的 `automation_enabled: false`，而不会因为探测失败而启用服务。
public struct LegacyAutomationStateObservation: Equatable {
    public let plistExists: Bool
    public let serviceLoaded: Bool
    public let serviceProbeSucceeded: Bool

    public init(plistExists: Bool, serviceLoaded: Bool, serviceProbeSucceeded: Bool) {
        self.plistExists = plistExists
        self.serviceLoaded = serviceLoaded
        self.serviceProbeSucceeded = serviceProbeSucceeded
    }

    public var inferredAutomationEnabled: Bool {
        plistExists || serviceLoaded
    }

    public var usedSafeDefault: Bool {
        !inferredAutomationEnabled && !serviceProbeSucceeded
    }
}

enum AutomationStateMigrationResult: Equatable {
    case notRequired
    case migrated(enabled: Bool, usedSafeDefault: Bool)
}

enum SorterRuntimeState: String {
    case stopped
    case running
    case temporarilyPaused
    case scanning
    case awaitingConfirmation
    case organizing
    case error

    /// 兼容旧调用方的“活动中”提示；不代表持久化后台服务开关。
    /// 服务开关必须读取 `SorterConfig.automationEnabled`，整理模式也不能由此状态反推。
    var isServiceEnabled: Bool {
        switch self {
        case .running, .scanning, .awaitingConfirmation, .organizing: return true
        case .stopped, .temporarilyPaused, .error: return false
        }
    }

    var title: String {
        switch self {
        case .stopped: return "未启用"
        case .running: return "正常运行"
        case .temporarilyPaused: return "已暂停"
        case .scanning: return "正在扫描"
        case .awaitingConfirmation: return "等待确认"
        case .organizing: return "正在整理"
        case .error: return "Agent 错误"
        }
    }

    var detail: String {
        switch self {
        case .stopped: return "后台不会自动扫描或移动文件。"
        case .running: return "后台服务已加载，按当前方式工作。"
        case .temporarilyPaused: return "后台服务已暂停。"
        case .scanning: return "正在读取文件状态，不会跳过安全检查。"
        case .awaitingConfirmation: return "整理建议已生成，等待你的确认。"
        case .organizing: return "正在执行已确认的文件操作。"
        case .error: return "请打开设置中的环境检查或查看技术日志。"
        }
    }
}

func splitRuleList(_ value: String) -> [String] {
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
    static let currentConfigVersion = 10

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
    var automationEnabled: Bool
    var retentionDays: Int
    var recentModificationProtectionHours: Int
    var automaticScanIntervalHours: Int
    var excludedPaths: [String]
    var rules: [SorterRule]

    /// 该标记不写入 JSON，仅表示解码时没有发现 `automation_enabled`。
    /// AppModel 应在读取 LaunchAgent 状态后调用 `migrateAutomationEnabled(using:)`。
    var automationStateNeedsMigration: Bool

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
        case automationEnabled = "automation_enabled"
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
        excludedPaths: [String], rules: [SorterRule], automationEnabled: Bool = false,
        automationStateNeedsMigration: Bool = false
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
        self.automationEnabled = automationEnabled
        self.retentionDays = retentionDays
        self.recentModificationProtectionHours = recentModificationProtectionHours
        self.automaticScanIntervalHours = automaticScanIntervalHours
        self.excludedPaths = excludedPaths
        self.rules = rules
        self.automationStateNeedsMigration = automationStateNeedsMigration
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
        // 迁移后台服务状态时只看 LaunchAgent，不根据整理模式猜测，避免悄然改变用户选择。
        organizationMode = OrganizationMode(rawValue: storedMode)?.rawValue ?? d.organizationMode
        let storedAutomationEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationEnabled)
        automationEnabled = storedAutomationEnabled ?? false
        automationStateNeedsMigration = storedAutomationEnabled == nil
        retentionDays = max(0, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays)
        recentModificationProtectionHours = max(0, try c.decodeIfPresent(Int.self, forKey: .recentModificationProtectionHours) ?? d.recentModificationProtectionHours)
        automaticScanIntervalHours = max(0, try c.decodeIfPresent(Int.self, forKey: .automaticScanIntervalHours) ?? d.automaticScanIntervalHours)
        excludedPaths = (try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? d.excludedPaths)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        rules = try c.decodeIfPresent([SorterRule].self, forKey: .rules) ?? d.rules
        configVersion = Self.currentConfigVersion
    }

    /// 将旧配置的服务开关绑定到 LaunchAgent 的持久状态。
    ///
    /// `plistExists || serviceLoaded` 为真时迁移为开启；没有 plist 且探测成功时迁移为关闭；
    /// 探测不可用时同样安全迁移为关闭。调用方随后应在安全保存路径写出 v10。
    @discardableResult
    mutating func migrateAutomationEnabled(
        using observation: LegacyAutomationStateObservation
    ) -> AutomationStateMigrationResult {
        guard automationStateNeedsMigration else { return .notRequired }
        automationEnabled = observation.inferredAutomationEnabled
        automationStateNeedsMigration = false
        return .migrated(
            enabled: automationEnabled,
            usedSafeDefault: observation.usedSafeDefault
        )
    }

    static let fallback = SorterConfig(
        configVersion: currentConfigVersion,
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
        retentionDays: 0,
        recentModificationProtectionHours: 0,
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
        ],
        automationEnabled: false
    )
}

struct ProcessResult {
    let status: Int32
    let output: String
}

// 收件箱条目只保留 Agent 评估结果和界面选择状态，避免 App 重新判断文件资格。
struct PendingFile: Identifiable {
    let assessment: FileAssessmentItem
    var keyword: String
    var selected = true
    var ignored = false

    var id: String { assessment.path }
    var path: String { assessment.path }
    var fileName: String { assessment.fileName }
    var target: String { assessment.targetFolder }
    var extensionName: String { assessment.extension }
    var fileSize: UInt64 { assessment.fileSize }
    var modifiedAt: Date { ISO8601DateFormatter().date(from: assessment.modifiedAt) ?? Date() }
    var status: FileProcessingStatus { assessment.status }
    var canSelect: Bool { assessment.canSelect && !ignored }
}

// 单个与批量整理共用同一份草稿，避免“最近目录”“批量移动”“建立规则”各走一套逻辑。
struct PendingMoveDraft: Identifiable {
    let id = UUID()
    let paths: [String]
    let fileNames: [String]
    let suggestedKeyword: String
    let suggestedTarget: String
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
    let assessment: FileAssessmentItem
    let sourcePath: String
    let fileName: String
    let ruleName: String
    let destinationPath: String
    let status: String
    let fileSize: UInt64
    let modifiedAt: Date
    let ageDays: Int
    let canSelect: Bool
    var selected: Bool
}
