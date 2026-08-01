// AI File Sorter 2.0 原生后台引擎：无需 Python，负责稳定性检测、规则匹配、移动与状态记录。

import CryptoKit
import Darwin
import Foundation

struct AgentRename: Codable {
    var enabled: Bool = false
    var template: String = "{date}_{original_name}"
    var dateFormat: String = "%Y-%m-%d"
    enum CodingKeys: String, CodingKey { case enabled, template; case dateFormat = "date_format" }
}

struct AgentRule: Codable {
    var enabled = true
    var matchMode = "any"
    var keywords: [String]
    var excludeKeywords: [String] = []
    var extensions: [String] = []
    var nameRegex = ""
    var minimumSizeMB: Double?
    var maximumSizeMB: Double?
    var modifiedOlderThanDays: Int?
    var modifiedNewerThanDays: Int?
    var finderTags: [String] = []
    var target: String

    enum CodingKeys: String, CodingKey {
        case enabled, keywords, target, extensions
        case nameRegex = "name_regex"
        case minimumSizeMB = "minimum_size_mb"
        case maximumSizeMB = "maximum_size_mb"
        case modifiedOlderThanDays = "modified_older_than_days"
        case modifiedNewerThanDays = "modified_newer_than_days"
        case finderTags = "finder_tags"
        case matchMode = "match_mode"
        case excludeKeywords = "exclude_keywords"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchMode = try c.decodeIfPresent(String.self, forKey: .matchMode) ?? "any"
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        excludeKeywords = try c.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? []
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        nameRegex = try c.decodeIfPresent(String.self, forKey: .nameRegex) ?? ""
        minimumSizeMB = try c.decodeIfPresent(Double.self, forKey: .minimumSizeMB)
        maximumSizeMB = try c.decodeIfPresent(Double.self, forKey: .maximumSizeMB)
        modifiedOlderThanDays = try c.decodeIfPresent(Int.self, forKey: .modifiedOlderThanDays)
        modifiedNewerThanDays = try c.decodeIfPresent(Int.self, forKey: .modifiedNewerThanDays)
        finderTags = try c.decodeIfPresent([String].self, forKey: .finderTags) ?? []
        target = try c.decode(String.self, forKey: .target)
    }

    func matches(_ file: URL) -> Bool {
        guard enabled else { return false }
        let name = file.lastPathComponent
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if excludeKeywords.contains(where: { name.range(of: $0, options: options) != nil }) { return false }
        if !nameRegex.isEmpty,
           name.range(of: nameRegex, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if !extensions.isEmpty {
            let ext = "." + file.pathExtension.lowercased()
            if !extensions.contains(where: { ($0.hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()) == ext }) { return false }
        }
        if keywords.isEmpty && extensions.isEmpty && nameRegex.isEmpty { return false }
        let keywordMatch = keywords.isEmpty || (matchMode == "all"
            ? keywords.allSatisfy { name.range(of: $0, options: options) != nil }
            : keywords.contains { name.range(of: $0, options: options) != nil })
        guard keywordMatch else { return false }
        let needsMetadata = minimumSizeMB != nil || maximumSizeMB != nil || modifiedOlderThanDays != nil
            || modifiedNewerThanDays != nil || !finderTags.isEmpty
        guard needsMetadata else { return true }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        guard let values = try? file.resourceValues(forKeys: keys) else { return false }
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
}

enum FileProcessingStatus: Equatable {
    case eligible
    case moved
    case missing
    case notRegularFile
    case hidden
    case unsupported
    case temporary
    case excluded
    case locked
    case metadataUnavailable
    case sourceOutsideWatchFolder
    case retentionProtected
    case recentModificationProtected
    case unstable
    case noMatchingRule
    case sameLocation
    case destinationInWatchFolder
    case destinationCycle
    case invalidDestination
    case failed

    var label: String {
        switch self {
        case .eligible: return "可以整理"
        case .moved: return "成功"
        case .missing: return "文件已不存在"
        case .notRegularFile: return "不是普通文件"
        case .hidden: return "隐藏文件"
        case .unsupported: return "不支持的文件类型"
        case .temporary: return "临时下载文件"
        case .excluded: return "位于排除路径"
        case .locked: return "文件已锁定"
        case .metadataUnavailable: return "无法读取文件状态"
        case .sourceOutsideWatchFolder: return "来源不在监听目录内"
        case .retentionProtected: return "仍在保留期内"
        case .recentModificationProtected: return "最近修改保护中"
        case .unstable: return "文件仍在写入或状态发生变化"
        case .noMatchingRule: return "未分类"
        case .sameLocation: return "来源与目标相同"
        case .destinationInWatchFolder: return "目标位于监听目录内"
        case .destinationCycle: return "目标会形成整理循环"
        case .invalidDestination: return "目标目录无效"
        case .failed: return "失败"
        }
    }
}

enum FileProcessingIntent {
    case automatic
    case once
    case plan
    case confirmedMove(target: URL)
    case eligibility

    var bypassTimeProtection: Bool {
        if case .confirmedMove = self { return true }
        return false
    }

    var requiresStability: Bool {
        switch self {
        case .automatic, .once, .plan: return true
        case .confirmedMove, .eligibility: return false
        }
    }
}

struct AgentConfig: Codable {
    var watchFolder = "~/Downloads"
    var logFile = "logs/sorter.log"
    var stateFile = "logs/state.json"
    var historyFile = "logs/history.json"
    var scanInterval = 2.0
    var stableSeconds = 4.0
    var idleSeconds = 8.0
    var maxRuntime = 900.0
    var processExisting = false
    var moveMethod = "native"
    var rename = AgentRename()
    var extensions: [String] = []
    var organizationMode = "review"
    var retentionDays = 0
    var recentModificationProtectionHours = 0
    var automaticScanIntervalHours = 24
    var excludedPaths: [String] = []
    var rules: [AgentRule] = []

    enum CodingKeys: String, CodingKey {
        case watchFolder = "watch_folder", logFile = "log_file", stateFile = "state_file", historyFile = "history_file"
        case scanInterval = "scan_interval_seconds", stableSeconds = "stable_seconds"
        case idleSeconds = "event_idle_seconds", maxRuntime = "max_event_runtime_seconds"
        case processExisting = "process_existing_on_first_start", moveMethod = "move_method"
        case rename, extensions = "supported_extensions"
        case organizationMode = "organization_mode"
        case retentionDays = "retention_days"
        case recentModificationProtectionHours = "recent_modification_protection_hours"
        case automaticScanIntervalHours = "automatic_scan_interval_hours"
        case excludedPaths = "excluded_paths"
        case rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchFolder = try c.decodeIfPresent(String.self, forKey: .watchFolder) ?? watchFolder
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile) ?? logFile
        stateFile = try c.decodeIfPresent(String.self, forKey: .stateFile) ?? stateFile
        historyFile = try c.decodeIfPresent(String.self, forKey: .historyFile) ?? historyFile
        scanInterval = try c.decodeIfPresent(Double.self, forKey: .scanInterval) ?? scanInterval
        stableSeconds = try c.decodeIfPresent(Double.self, forKey: .stableSeconds) ?? stableSeconds
        idleSeconds = try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? idleSeconds
        maxRuntime = try c.decodeIfPresent(Double.self, forKey: .maxRuntime) ?? maxRuntime
        processExisting = try c.decodeIfPresent(Bool.self, forKey: .processExisting) ?? processExisting
        moveMethod = try c.decodeIfPresent(String.self, forKey: .moveMethod) ?? moveMethod
        rename = try c.decodeIfPresent(AgentRename.self, forKey: .rename) ?? rename
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? extensions
        let storedMode = try c.decodeIfPresent(String.self, forKey: .organizationMode) ?? organizationMode
        organizationMode = ["manual", "review", "automatic"].contains(storedMode) ? storedMode : "review"
        retentionDays = max(0, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays)
        recentModificationProtectionHours = max(0, try c.decodeIfPresent(Int.self, forKey: .recentModificationProtectionHours) ?? recentModificationProtectionHours)
        automaticScanIntervalHours = max(0, try c.decodeIfPresent(Int.self, forKey: .automaticScanIntervalHours) ?? automaticScanIntervalHours)
        excludedPaths = (try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? excludedPaths)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        rules = try c.decodeIfPresent([AgentRule].self, forKey: .rules) ?? rules
    }
}

struct FileSignature: Codable, Equatable {
    let size: UInt64
    let modified: Int64
}

struct FileProcessingAssessment {
    let status: FileProcessingStatus
    let source: URL
    let canonicalSource: URL
    let signature: FileSignature?
    let ruleIndex: Int?
    let rule: AgentRule?
    let target: URL?
    let detail: String

    var canMove: Bool { status == .eligible }

    func replacing(status: FileProcessingStatus, detail: String) -> FileProcessingAssessment {
        FileProcessingAssessment(
            status: status, source: source, canonicalSource: canonicalSource,
            signature: signature, ruleIndex: ruleIndex, rule: rule, target: target, detail: detail
        )
    }
}

struct StateRecord: Codable {
    let signature: FileSignature
    let reason: String
}

struct AgentState: Codable {
    var version = 2
    var initialized = false
    var rulesFingerprint = ""
    var files: [String: StateRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case version, initialized, files
        case rulesFingerprint = "rules_fingerprint"
    }
}

// 结构化整理历史用于界面展示和撤销；最多保留 500 条，避免长期占用磁盘。
struct MoveHistoryRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    var originalPath: String
    let destinationPath: String
    let reason: String
    var undone: Bool
    let batchID: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, reason, undone
        case originalPath = "originalPath"
        case destinationPath = "destinationPath"
        case batchID = "batch_id"
    }

    init(id: String, timestamp: Date, originalPath: String, destinationPath: String, reason: String, undone: Bool, batchID: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.originalPath = originalPath
        self.destinationPath = destinationPath; self.reason = reason; self.undone = undone; self.batchID = batchID
    }
}

final class SorterLogger {
    private let url: URL
    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func write(_ level: String = "INFO", _ message: String) {
        rotateIfNeeded()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) | \(level) | \(message)\n"
        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: data); return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue >= 5 * 1024 * 1024 else { return }
        let manager = FileManager.default
        for index in stride(from: 3, through: 1, by: -1) {
            let source = index == 1 ? url : URL(fileURLWithPath: url.path + ".\(index - 1)")
            let target = URL(fileURLWithPath: url.path + ".\(index)")
            try? manager.removeItem(at: target)
            if manager.fileExists(atPath: source.path) { try? manager.moveItem(at: source, to: target) }
        }
    }
}

private let temporaryFileSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp"]

private func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
}

private func pathIsInside(_ candidate: URL, root: URL) -> Bool {
    let rootPath = canonicalFileURL(root).path
    let candidatePath = canonicalFileURL(candidate).path
    let prefix = rootPath == "/" ? "/" : (rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
}

final class NativeSorter {
    let configURL: URL
    var config: AgentConfig
    let base: URL
    let logger: SorterLogger
    let stateURL: URL
    let historyURL: URL
    let watchURL: URL
    private let manager = FileManager.default

    init(configURL: URL) throws {
        self.configURL = configURL
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: configURL))
        config = decoded
        guard !decoded.rules.contains(where: { $0.enabled && (($0.keywords.isEmpty && $0.extensions.isEmpty && $0.nameRegex.isEmpty) || $0.target.isEmpty) }) else {
            throw NSError(domain: "AIFileSorter", code: 2, userInfo: [NSLocalizedDescriptionKey: "规则需要关键词、扩展名或正则表达式，以及目标目录"])
        }
        for (index, rule) in decoded.rules.enumerated() where rule.enabled {
            if !rule.nameRegex.isEmpty, (try? NSRegularExpression(pattern: rule.nameRegex)) == nil {
                throw NSError(domain: "AIFileSorter", code: 5, userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的正则表达式无效"])
            }
            if let minimum = rule.minimumSizeMB, let maximum = rule.maximumSizeMB, minimum > maximum {
                throw NSError(domain: "AIFileSorter", code: 6, userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的最小大小不能大于最大大小"])
            }
            if [rule.minimumSizeMB, rule.maximumSizeMB].compactMap({ $0 }).contains(where: { $0 < 0 })
                || [rule.modifiedOlderThanDays, rule.modifiedNewerThanDays].compactMap({ $0 }).contains(where: { $0 < 0 }) {
                throw NSError(domain: "AIFileSorter", code: 7, userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的大小和天数不能为负数"])
            }
        }
        let resolvedBase = configURL.deletingLastPathComponent()
        base = resolvedBase
        func resolveURL(_ value: String) -> URL {
            let expanded = NSString(string: value).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : resolvedBase.appendingPathComponent(expanded)
        }
        stateURL = resolveURL(decoded.stateFile)
        historyURL = resolveURL(decoded.historyFile)
        watchURL = resolveURL(decoded.watchFolder)
        logger = SorterLogger(url: resolveURL(decoded.logFile))
        if decoded.rules.contains(where: { $0.enabled && pathIsInside(resolveURL($0.target), root: watchURL) }) {
            throw NSError(domain: "AIFileSorter", code: 4, userInfo: [NSLocalizedDescriptionKey: "规则目标不能位于监听文件夹内"])
        }
        try manager.createDirectory(at: watchURL, withIntermediateDirectories: true)
    }

    var fingerprint: String {
        let data = (try? JSONEncoder().encode(config.rules)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func signature(_ url: URL) throws -> FileSignature {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileSignature(
            size: UInt64(values.fileSize ?? 0),
            modified: Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func supportedFiles() -> [URL] {
        let supported = Set(config.extensions.map { $0.lowercased() })
        let urls = (try? manager.contentsOfDirectory(at: watchURL, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return urls.filter {
            let name = $0.lastPathComponent
            let regular = (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            return regular && !name.hasPrefix(".") && !temporaryFileSuffixes.contains(where: { name.lowercased().hasSuffix($0) })
                && supported.contains("." + $0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func pathMatches(_ file: URL, configuredPath: String) -> Bool {
        pathIsInside(file, root: resolveConfiguredPath(configuredPath))
    }

    func isEligible(_ file: URL) -> Bool {
        evaluate(file, intent: .eligibility).status == .eligible
    }

    private func resolveConfiguredPath(_ value: String) -> URL {
        let expanded = NSString(string: value).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
    }

    private func resolveTarget(_ value: String) -> URL {
        resolveConfiguredPath(value).standardizedFileURL
    }

    private func isLocked(_ file: URL, values: URLResourceValues) -> Bool {
        if values.isUserImmutable == true { return true }

        // Finder 的“已锁定”由 isUserImmutable 表示；这里再尊重其他进程的
        // advisory flock，避免 --once 在文件仍被明确占用时搬走它。
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    func evaluate(
        _ source: URL,
        intent: FileProcessingIntent,
        expectedSignature: FileSignature? = nil,
        stableSince: Date? = nil
    ) -> FileProcessingAssessment {
        let standardizedSource = source.standardizedFileURL
        let canonicalSource = canonicalFileURL(standardizedSource)
        func emptyAssessment(_ status: FileProcessingStatus, _ detail: String, signature: FileSignature? = nil,
                             ruleIndex: Int? = nil, rule: AgentRule? = nil, target: URL? = nil) -> FileProcessingAssessment {
            FileProcessingAssessment(
                status: status, source: standardizedSource, canonicalSource: canonicalSource,
                signature: signature, ruleIndex: ruleIndex, rule: rule, target: target, detail: detail
            )
        }

        guard manager.fileExists(atPath: standardizedSource.path) else {
            return emptyAssessment(.missing, "文件已不存在：" + standardizedSource.path)
        }
        guard pathIsInside(canonicalSource, root: watchURL) else {
            return emptyAssessment(.sourceOutsideWatchFolder, "来源不在监听目录内：" + canonicalSource.path)
        }
        guard let values = try? canonicalSource.resourceValues(forKeys: [
            .isRegularFileKey, .creationDateKey, .contentModificationDateKey, .isUserImmutableKey
        ]) else {
            return emptyAssessment(.metadataUnavailable, "无法读取文件状态：" + canonicalSource.path)
        }
        guard values.isRegularFile == true else {
            return emptyAssessment(.notRegularFile, "不是普通文件：" + canonicalSource.path)
        }
        let name = canonicalSource.lastPathComponent
        guard !name.hasPrefix(".") else {
            return emptyAssessment(.hidden, "隐藏文件不会自动整理：" + name)
        }
        guard !temporaryFileSuffixes.contains(where: { name.lowercased().hasSuffix($0) }) else {
            return emptyAssessment(.temporary, "临时下载后缀不会整理：" + name)
        }
        if config.excludedPaths.contains(where: { pathMatches(canonicalSource, configuredPath: $0) }) {
            return emptyAssessment(.excluded, "文件位于排除路径：" + canonicalSource.path)
        }
        guard !isLocked(canonicalSource, values: values) else {
            return emptyAssessment(.locked, "文件已锁定或被其他进程占用：" + canonicalSource.path)
        }

        let currentSignature = try? signature(canonicalSource)
        guard let currentSignature else {
            return emptyAssessment(.metadataUnavailable, "无法读取文件签名：" + canonicalSource.path)
        }
        let now = Date()
        if let expectedSignature, expectedSignature != currentSignature {
            return emptyAssessment(.unstable, "文件在稳定等待期间发生变化：" + canonicalSource.path, signature: currentSignature)
        }
        if !intent.bypassTimeProtection {
            let modified = values.contentModificationDate ?? values.creationDate ?? now
            let ageReference = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? modified
            if config.retentionDays > 0,
               now.timeIntervalSince(ageReference) < Double(config.retentionDays) * 86_400 {
                return emptyAssessment(.retentionProtected, "文件仍在保留期内：" + canonicalSource.path, signature: currentSignature)
            }
            if config.recentModificationProtectionHours > 0,
               now.timeIntervalSince(modified) < Double(config.recentModificationProtectionHours) * 3_600 {
                return emptyAssessment(.recentModificationProtected, "文件最近修改保护中：" + canonicalSource.path, signature: currentSignature)
            }
        }
        if intent.requiresStability, config.stableSeconds > 0 {
            guard let stableSince,
                  now.timeIntervalSince(stableSince) >= config.stableSeconds else {
                return emptyAssessment(.unstable, "文件尚未稳定 " + String(config.stableSeconds) + " 秒：" + canonicalSource.path, signature: currentSignature)
            }
        }

        if case .eligibility = intent {
            return emptyAssessment(.eligible, "文件符合安全条件", signature: currentSignature)
        }

        let selectedRule: (offset: Int, element: AgentRule)?
        let target: URL
        switch intent {
        case .confirmedMove(let requestedTarget):
            selectedRule = nil
            target = requestedTarget.standardizedFileURL
        default:
            guard let match = config.rules.enumerated().first(where: { _, rule in rule.matches(canonicalSource) }) else {
                return emptyAssessment(.noMatchingRule, "没有匹配规则：" + canonicalSource.path, signature: currentSignature)
            }
            selectedRule = match
            target = resolveTarget(match.element.target)
        }

        let canonicalTarget = canonicalFileURL(target)
        guard !target.path.isEmpty else {
            return emptyAssessment(.invalidDestination, "目标目录为空", signature: currentSignature,
                                    ruleIndex: selectedRule?.offset, rule: selectedRule?.element, target: target)
        }
        if canonicalTarget == canonicalSource || canonicalTarget == canonicalFileURL(canonicalSource.deletingLastPathComponent()) {
            return emptyAssessment(.sameLocation, "来源与目标目录相同：" + canonicalTarget.path, signature: currentSignature,
                                    ruleIndex: selectedRule?.offset, rule: selectedRule?.element, target: canonicalTarget)
        }
        if pathIsInside(canonicalTarget, root: watchURL) {
            return emptyAssessment(.destinationInWatchFolder, "目标位于监听目录内，可能形成整理循环：" + canonicalTarget.path, signature: currentSignature,
                                    ruleIndex: selectedRule?.offset, rule: selectedRule?.element, target: canonicalTarget)
        }
        if manager.fileExists(atPath: target.path) {
            guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return emptyAssessment(.invalidDestination, "目标路径不是目录：" + target.path, signature: currentSignature,
                                        ruleIndex: selectedRule?.offset, rule: selectedRule?.element, target: canonicalTarget)
            }
        }
        return emptyAssessment(.eligible, "文件符合安全条件", signature: currentSignature,
                                ruleIndex: selectedRule?.offset, rule: selectedRule?.element, target: canonicalTarget)
    }

    private func swiftDateFormat(_ python: String) -> String {
        python.replacingOccurrences(of: "%Y", with: "yyyy").replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd").replacingOccurrences(of: "%H", with: "HH")
            .replacingOccurrences(of: "%M", with: "mm").replacingOccurrences(of: "%S", with: "ss")
    }

    private func destinationName(_ source: URL, rule: AgentRule?) -> String {
        guard config.rename.enabled, rule != nil else { return source.lastPathComponent }
        let formatter = DateFormatter(); formatter.dateFormat = swiftDateFormat(config.rename.dateFormat)
        let ext = source.pathExtension
        let keyword = rule?.keywords.first(where: {
            source.lastPathComponent.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) ?? "关键词"
        let category = rule.map { resolveTarget($0.target).lastPathComponent } ?? "单次整理"
        var name = config.rename.template
            .replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))
            .replacingOccurrences(of: "{original_name}", with: source.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{keyword}", with: keyword)
        if !ext.isEmpty && !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
        return URL(fileURLWithPath: name).lastPathComponent
    }

    private func collisionFree(_ destination: URL) -> URL {
        guard !manager.fileExists(atPath: destination.path) else {
            let ext = destination.pathExtension
            let stem = destination.deletingPathExtension().lastPathComponent
            var index = 1
            while true {
                let name = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
                let candidate = destination.deletingLastPathComponent().appendingPathComponent(name)
                if !manager.fileExists(atPath: candidate.path) { return candidate }
                index += 1
            }
        }
        return destination
    }

    private func loadHistory() -> [MoveHistoryRecord] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([MoveHistoryRecord].self, from: data)) ?? []
    }

    private func saveHistory(_ records: [MoveHistoryRecord]) throws {
        try manager.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trimmed = Array(records.suffix(500))
        let data = try JSONEncoder().encode(trimmed)
        try data.write(to: historyURL, options: .atomic)
    }

    private func recordMove(source: URL, destination: URL, reason: String, batchID: String? = nil) {
        var records = loadHistory()
        records.append(MoveHistoryRecord(
            id: UUID().uuidString, timestamp: Date(), originalPath: source.path,
            destinationPath: destination.path, reason: reason, undone: false, batchID: batchID
        ))
        do { try saveHistory(records) }
        catch { logger.write("WARNING", "整理历史写入失败：\(error.localizedDescription)") }
    }

    private func moveWithFinder(_ source: URL, _ destination: URL) throws {
        let stagingName = ".aisorter-\(UUID().uuidString)-\(source.lastPathComponent)"
        let stagingSource = source.deletingLastPathComponent().appendingPathComponent(stagingName)
        try manager.moveItem(at: source, to: stagingSource)
        let script = """
        on run argv
          tell application "Finder"
            set movedItem to move (POSIX file (item 1 of argv) as alias) to (POSIX file (item 2 of argv) as alias)
            set name of movedItem to item 3 of argv
          end tell
        end run
        """
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, stagingSource.path, destination.deletingLastPathComponent().path, destination.lastPathComponent]
        process.standardError = pipe
        do {
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "AIFileSorter", code: 3, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Finder 移动失败"])
            }
        } catch {
            let movedStaging = destination.deletingLastPathComponent().appendingPathComponent(stagingName)
            if manager.fileExists(atPath: stagingSource.path) { try? manager.moveItem(at: stagingSource, to: source) }
            else if manager.fileExists(atPath: movedStaging.path) && !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: movedStaging, to: source)
            }
            throw error
        }
    }

    @discardableResult
    func process(
        _ source: URL,
        intent: FileProcessingIntent,
        batchID: String? = nil,
        expectedSignature: FileSignature? = nil,
        stableSince: Date? = nil
    ) -> FileProcessingAssessment {
        let assessment = evaluate(source, intent: intent, expectedSignature: expectedSignature, stableSince: stableSince)
        guard assessment.canMove, let folder = assessment.target else {
            logger.write("INFO", "原文件=\(assessment.source.path) | 目标=\(assessment.target?.path ?? "-") | 结果=\(assessment.status.label) | 说明=\(assessment.detail)")
            return assessment
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = collisionFree(folder.appendingPathComponent(destinationName(assessment.canonicalSource, rule: assessment.rule)))
            if config.moveMethod == "finder" { try moveWithFinder(assessment.canonicalSource, destination) }
            else { try manager.moveItem(at: assessment.canonicalSource, to: destination) }
            let reason = assessment.ruleIndex.map { "规则 \($0 + 1)" } ?? "单次整理"
            recordMove(source: assessment.canonicalSource, destination: destination, reason: reason, batchID: batchID)
            logger.write("INFO", "原文件=\(assessment.canonicalSource.path) | 目标=\(destination.path) | 结果=成功 | 说明=\(reason) 匹配并移动")
            return assessment.replacing(status: .moved, detail: destination.path)
        } catch {
            logger.write("ERROR", "原文件=\(assessment.canonicalSource.path) | 目标=\(folder.path) | 结果=失败 | 说明=\(error.localizedDescription)")
            return assessment.replacing(status: .failed, detail: error.localizedDescription)
        }
    }

    @discardableResult
    func sort(_ source: URL, batchID: String? = nil, expectedSignature: FileSignature? = nil, stableSince: Date? = nil) -> String {
        let result = process(source, intent: .plan, batchID: batchID, expectedSignature: expectedSignature, stableSince: stableSince)
        switch result.status {
        case .moved: return "moved"
        case .noMatchingRule: return "unknown"
        case .failed: return "error"
        default: return "skipped"
        }
    }

    // 单次整理不会创建规则，保留原文件名，并与自动整理共用进程锁及历史记录。
    func moveOnce(sourcePath: String, targetPath: String, batchID: String? = nil) -> Int32 {
        let source = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath)
        let folder = URL(fileURLWithPath: NSString(string: targetPath).expandingTildeInPath, isDirectory: true)
        let result = process(source, intent: .confirmedMove(target: folder), batchID: batchID)
        if result.status == .moved {
            print("单次整理完成：\(source.lastPathComponent) → \(folder.path)")
            return 0
        }
        print("单次整理未执行：\(result.status.label)（\(result.detail)）")
        return 1
    }

    func moveMany(sourcePaths: [String], targetPath: String) -> Int32 {
        let batchID = UUID().uuidString
        var failures = 0
        for path in sourcePaths where moveOnce(sourcePath: path, targetPath: targetPath, batchID: batchID) != 0 { failures += 1 }
        print("批量单次整理完成：成功 \(sourcePaths.count - failures) 个，失败 \(failures) 个")
        return failures == 0 ? 0 : 1
    }

    func sortPaths(_ paths: [String]) -> Int32 {
        let batchID = UUID().uuidString
        var moved = 0, failed = 0
        let started = Date()
        let snapshots = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            return try? (source.path, signature(source))
        })
        Thread.sleep(forTimeInterval: max(0, config.stableSeconds))
        for path in paths {
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let result = process(source, intent: .plan, batchID: batchID,
                                 expectedSignature: snapshots[source.path], stableSince: started)
            if result.status == .moved { moved += 1 } else { failed += 1 }
        }
        print("整理计划执行完成：成功 \(moved) 个，失败或已不匹配 \(failed) 个")
        return failed == 0 ? 0 : 1
    }

    func undo(historyID: String) -> Int32 {
        var records = loadHistory()
        guard let index = records.firstIndex(where: { $0.id == historyID }) else { print("找不到整理记录"); return 1 }
        guard !records[index].undone else { print("这条整理记录已经撤销"); return 1 }
        let destination = URL(fileURLWithPath: records[index].destinationPath)
        guard manager.fileExists(atPath: destination.path) else { print("目标文件已不存在，无法撤销"); return 1 }
        do {
            let requested = URL(fileURLWithPath: records[index].originalPath)
            try manager.createDirectory(at: requested.deletingLastPathComponent(), withIntermediateDirectories: true)
            let restored = collisionFree(requested)
            try manager.moveItem(at: destination, to: restored)
            records[index].originalPath = restored.path
            records[index].undone = true
            try saveHistory(records)
            // 标记撤销后的文件为已见，避免 LaunchAgent 因目录变化立即再次把它移走。
            let canonicalRestored = restored.resolvingSymlinksInPath()
            if let restoredSignature = try? signature(canonicalRestored) {
                var state = loadState()
                state.initialized = true
                state.rulesFingerprint = fingerprint
                state.files[canonicalRestored.path] = StateRecord(signature: restoredSignature, reason: "undo")
                saveState(state)
            }
            logger.write("INFO", "原文件=\(destination.path) | 目标=\(restored.path) | 结果=成功 | 说明=撤销整理")
            print("已撤销：\(restored.lastPathComponent) 已移回原目录")
            return 0
        } catch {
            logger.write("ERROR", "原文件=\(destination.path) | 目标=\(records[index].originalPath) | 结果=失败 | 说明=撤销：\(error.localizedDescription)")
            print("撤销失败：\(error.localizedDescription)")
            return 1
        }
    }

    func undoBatch(batchID: String) -> Int32 {
        let ids = loadHistory().reversed().filter { $0.batchID == batchID && !$0.undone }.map(\.id)
        guard !ids.isEmpty else { print("找不到可撤销的整理批次"); return 1 }
        var failures = 0
        for id in ids where undo(historyID: id) != 0 { failures += 1 }
        print("批次撤销完成：成功 \(ids.count - failures) 个，失败 \(failures) 个")
        return failures == 0 ? 0 : 1
    }

    func loadState() -> AgentState {
        guard let data = try? Data(contentsOf: stateURL) else { return AgentState() }
        if var state = try? JSONDecoder().decode(AgentState.self, from: data) {
            if state.version < 2 {
                state.version = 2
                logger.write("INFO", "已将 1.x 状态文件迁移到原生 2.0 格式")
                saveState(state)
            }
            return state
        }

        // 兼容 1.x Python 状态：记录原来直接包含 size、mtime_ns 和 reason。
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return AgentState() }
        var migrated = AgentState()
        migrated.initialized = root["initialized"] as? Bool ?? false
        migrated.rulesFingerprint = root["rules_fingerprint"] as? String ?? ""
        if let files = root["files"] as? [String: [String: Any]] {
            for (path, value) in files {
                let size = (value["size"] as? NSNumber)?.uint64Value ?? 0
                let modified = (value["mtime_ns"] as? NSNumber)?.int64Value ?? 0
                migrated.files[path] = StateRecord(
                    signature: FileSignature(size: size, modified: modified),
                    reason: value["reason"] as? String ?? "baseline"
                )
            }
        }
        logger.write("INFO", "已将 1.x 状态文件迁移到原生 2.0 格式")
        saveState(migrated)
        return migrated
    }

    func saveState(_ state: AgentState) {
        try? manager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

func acquireLock(_ url: URL) -> Int32? {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { if descriptor >= 0 { close(descriptor) }; return nil }
    return descriptor
}

func runOnce(_ sorter: NativeSorter) -> Int32 {
    let candidates = sorter.supportedFiles()
    let before = Dictionary(uniqueKeysWithValues: candidates.compactMap { url in try? (url.path, sorter.signature(url)) })
    let started = Date()
    Thread.sleep(forTimeInterval: max(0, sorter.config.stableSeconds))
    var moved = 0, unknown = 0, errors = 0, changing = 0
    for url in sorter.supportedFiles() {
        guard let expected = before[url.path] else { changing += 1; continue }
        let result = sorter.process(
            url, intent: .once, expectedSignature: expected, stableSince: started
        )
        switch result.status {
        case .moved: moved += 1
        case .noMatchingRule: unknown += 1
        case .unstable: changing += 1
        case .failed: errors += 1
        default: break
        }
    }
    let summary = "手动整理完成：支持文件 \(candidates.count) 个，成功移动 \(moved) 个，未匹配 \(unknown) 个，仍在写入 \(changing) 个，失败 \(errors) 个"
    sorter.logger.write(errors == 0 ? "INFO" : "ERROR", summary)
    print(summary)
    return errors > 0 ? 1 : 0
}

func runEvent(_ sorter: NativeSorter) -> Int32 {
    var state = sorter.loadState()
    let initialFiles = sorter.supportedFiles()
    if !state.initialized {
        state.rulesFingerprint = sorter.fingerprint
        if !sorter.config.processExisting {
            for url in initialFiles {
                let canonical = url.resolvingSymlinksInPath()
                if let signature = try? sorter.signature(canonical) {
                    state.files[canonical.path] = StateRecord(signature: signature, reason: "baseline")
                }
            }
            sorter.logger.write("INFO", "首次启动：保留现有文件 \(initialFiles.count) 个")
            state.initialized = true; sorter.saveState(state); return 0
        }
        state.initialized = true
    }
    if state.rulesFingerprint != sorter.fingerprint {
        state.files = state.files.filter { $0.value.reason != "unknown" }
        state.rulesFingerprint = sorter.fingerprint
    }
    guard sorter.config.organizationMode == "automatic" else {
        sorter.logger.write("INFO", "当前整理模式不允许后台自动移动：\(sorter.config.organizationMode)")
        sorter.saveState(state)
        return 0
    }
    var stable: [String: (FileSignature, Date)] = [:]
    var failed: Set<String> = []
    let started = Date(); var idleSince: Date?
    while Date().timeIntervalSince(started) < sorter.config.maxRuntime {
        let files = sorter.supportedFiles()
        let existing = Set(files.map { $0.resolvingSymlinksInPath().path })
        state.files = state.files.filter { existing.contains($0.key) }
        var pending = 0
        for url in files {
            let canonical = url.resolvingSymlinksInPath()
            let key = canonical.path
            guard let currentSignature = try? sorter.signature(canonical) else { continue }
            if state.files[key]?.reason == "undo" || state.files[key]?.signature == currentSignature || failed.contains(key) { continue }
            let previous = stable[key]
            let result = sorter.evaluate(canonical, intent: .automatic,
                                         expectedSignature: previous?.0, stableSince: previous?.1)
            if result.status == .unstable {
                pending += 1
                if previous?.0 != result.signature, let signature = result.signature {
                    stable[key] = (signature, Date())
                }
                continue
            }
            if result.status == .noMatchingRule, let signature = result.signature {
                state.files[key] = StateRecord(signature: signature, reason: "unknown")
                stable[key] = nil
                continue
            }
            guard result.status == .eligible, let signature = result.signature else { continue }
            pending += 1
            let processed = sorter.process(canonical, intent: .automatic,
                                            batchID: nil, expectedSignature: signature, stableSince: previous?.1)
            stable[key] = nil
            if processed.status == .noMatchingRule { state.files[key] = StateRecord(signature: signature, reason: "unknown") }
            if processed.status == .failed { failed.insert(key) }
        }
        sorter.saveState(state)
        if pending == 0 { idleSince = idleSince ?? Date() } else { idleSince = nil }
        if let idleSince, Date().timeIntervalSince(idleSince) >= sorter.config.idleSeconds { return 0 }
        Thread.sleep(forTimeInterval: max(0.2, sorter.config.scanInterval))
    }
    sorter.logger.write("WARNING", "本次监听达到最长运行时间")
    return 0
}

let arguments = CommandLine.arguments
guard let configIndex = arguments.firstIndex(of: "--config"), arguments.indices.contains(configIndex + 1) else {
    FileHandle.standardError.write(Data("缺少 --config 参数\n".utf8)); exit(2)
}
do {
    let sorter = try NativeSorter(configURL: URL(fileURLWithPath: arguments[configIndex + 1]))
    if arguments.contains("--check-config") { print("原生配置检查通过：\(sorter.configURL.path)"); exit(0) }
    let isDirectMove = arguments.contains("--move-once") || arguments.contains("--move-many")
    let isUndo = arguments.contains("--undo") || arguments.contains("--undo-batch")
    // 收件箱文件本身没有命中自动规则，直接移动无需等待事件监听进程退出。
    // 使用独立锁只阻止两个手动移动互相冲突，修复批量移动和最近目录偶发无响应。
    // 撤销使用独立锁避免与 --run（LaunchAgent 触发）冲突：撤销把文件移回 Downloads，
    // LaunchAgent 检测到目录变化后立即触发 --run，两者共用 sorter.lock 会导致撤销受阻。
    let lockName = isDirectMove ? "sorter-manual.lock" : (isUndo ? "sorter-undo.lock" : "sorter.lock")
    guard let lock = acquireLock(sorter.stateURL.deletingLastPathComponent().appendingPathComponent(lockName)) else {
        print(isDirectMove ? "另一个手动整理正在执行，请完成后重试。" : "整理服务正忙，请稍后重试。")
        let interactive = arguments.contains("--once") || isDirectMove || arguments.contains("--sort-paths")
            || arguments.contains("--undo") || arguments.contains("--undo-batch")
        exit(interactive ? 3 : 0)
    }
    defer { flock(lock, LOCK_UN); close(lock) }
    if let moveIndex = arguments.firstIndex(of: "--move-once"), arguments.indices.contains(moveIndex + 2) {
        exit(sorter.moveOnce(sourcePath: arguments[moveIndex + 1], targetPath: arguments[moveIndex + 2]))
    }
    if let moveIndex = arguments.firstIndex(of: "--move-many"), arguments.indices.contains(moveIndex + 2) {
        let target = arguments[moveIndex + 1]
        let paths = Array(arguments[(moveIndex + 2)...])
        exit(sorter.moveMany(sourcePaths: paths, targetPath: target))
    }
    if let sortIndex = arguments.firstIndex(of: "--sort-paths"), arguments.indices.contains(sortIndex + 1) {
        exit(sorter.sortPaths(Array(arguments[(sortIndex + 1)...])))
    }
    if let undoIndex = arguments.firstIndex(of: "--undo"), arguments.indices.contains(undoIndex + 1) {
        exit(sorter.undo(historyID: arguments[undoIndex + 1]))
    }
    if let undoIndex = arguments.firstIndex(of: "--undo-batch"), arguments.indices.contains(undoIndex + 1) {
        exit(sorter.undoBatch(batchID: arguments[undoIndex + 1]))
    }
    exit(arguments.contains("--once") ? runOnce(sorter) : runEvent(sorter))
} catch {
    FileHandle.standardError.write(Data("启动失败：\(error.localizedDescription)\n".utf8)); exit(1)
}
