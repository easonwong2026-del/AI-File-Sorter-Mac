// AI File Sorter 3.0 原生后台引擎：评估、移动与持久化使用同一套安全逻辑。

import CryptoKit
import Darwin
import Foundation

struct AgentRename: Codable {
    var enabled: Bool = false
    var template: String = "{date}_{original_name}"
    var dateFormat: String = "%Y-%m-%d"

    enum CodingKeys: String, CodingKey {
        case enabled, template
        case dateFormat = "date_format"
    }
}

struct AgentRule: Codable {
    var name: String = ""
    var enabled = true
    var matchMode = "any"
    var keywords: [String] = []
    var excludeKeywords: [String] = []
    var extensions: [String] = []
    var nameRegex = ""
    var minimumSizeMB: Double?
    var maximumSizeMB: Double?
    var modifiedOlderThanDays: Int?
    var modifiedNewerThanDays: Int?
    var finderTags: [String] = []
    var target: String = ""

    enum CodingKeys: String, CodingKey {
        case name, enabled, keywords, target, extensions
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
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
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

    private var needsMetadata: Bool {
        minimumSizeMB != nil || maximumSizeMB != nil || modifiedOlderThanDays != nil
            || modifiedNewerThanDays != nil || !finderTags.isEmpty
    }

    func matches(_ file: URL, values suppliedValues: URLResourceValues? = nil) -> Bool {
        guard enabled else { return false }
        let name = file.lastPathComponent
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if excludeKeywords.contains(where: { name.range(of: $0, options: options) != nil }) { return false }
        if !nameRegex.isEmpty,
           name.range(of: nameRegex, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if !extensions.isEmpty {
            let ext = "." + file.pathExtension.lowercased()
            if !extensions.contains(where: {
                ($0.hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()) == ext
            }) { return false }
        }
        if keywords.isEmpty && extensions.isEmpty && nameRegex.isEmpty { return false }
        let keywordMatch = keywords.isEmpty || (matchMode.lowercased() == "all"
            ? keywords.allSatisfy { name.range(of: $0, options: options) != nil }
            : keywords.contains { name.range(of: $0, options: options) != nil })
        guard keywordMatch else { return false }
        guard needsMetadata else { return true }
        guard let values = suppliedValues ?? (try? file.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .tagNamesKey
        ])) else { return false }
        guard let fileSize = values.fileSize else { return false }
        let sizeMB = Double(fileSize) / 1_048_576
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

enum FileProcessingIntent {
    case automatic
    case once
    case plan
    case confirmedMove(target: URL)
    case eligibility
    case scanJSON

    var bypassTimeProtection: Bool {
        if case .confirmedMove = self { return true }
        return false
    }

    var requiresStability: Bool {
        switch self {
        case .automatic, .once, .plan: return true
        case .confirmedMove, .eligibility, .scanJSON: return false
        }
    }

    var mutationTimeout: TimeInterval {
        switch self {
        case .automatic: return 0.25
        case .once, .plan: return 10
        case .confirmedMove: return 10
        case .eligibility, .scanJSON: return 0
        }
    }

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
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
        case watchFolder = "watch_folder"
        case logFile = "log_file"
        case stateFile = "state_file"
        case historyFile = "history_file"
        case scanInterval = "scan_interval_seconds"
        case stableSeconds = "stable_seconds"
        case idleSeconds = "event_idle_seconds"
        case maxRuntime = "max_event_runtime_seconds"
        case processExisting = "process_existing_on_first_start"
        case moveMethod = "move_method"
        case rename
        case extensions = "supported_extensions"
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
        scanInterval = max(0.1, try c.decodeIfPresent(Double.self, forKey: .scanInterval) ?? scanInterval)
        stableSeconds = max(0, try c.decodeIfPresent(Double.self, forKey: .stableSeconds) ?? stableSeconds)
        idleSeconds = max(0, try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? idleSeconds)
        maxRuntime = max(0, try c.decodeIfPresent(Double.self, forKey: .maxRuntime) ?? maxRuntime)
        processExisting = try c.decodeIfPresent(Bool.self, forKey: .processExisting) ?? processExisting
        moveMethod = try c.decodeIfPresent(String.self, forKey: .moveMethod) ?? moveMethod
        rename = try c.decodeIfPresent(AgentRename.self, forKey: .rename) ?? rename
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? extensions
        let storedMode = try c.decodeIfPresent(String.self, forKey: .organizationMode) ?? organizationMode
        organizationMode = ["manual", "review", "automatic"].contains(storedMode) ? storedMode : "review"
        retentionDays = max(0, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays)
        recentModificationProtectionHours = max(
            0, try c.decodeIfPresent(Int.self, forKey: .recentModificationProtectionHours)
                ?? recentModificationProtectionHours
        )
        automaticScanIntervalHours = max(
            0, try c.decodeIfPresent(Int.self, forKey: .automaticScanIntervalHours)
                ?? automaticScanIntervalHours
        )
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
    let destination: URL?
    let detail: String
    let remainingSeconds: TimeInterval
    let fileSize: UInt64
    let modifiedAt: Date?
    let didMove: Bool

    var canMove: Bool { status == .ready }

    var canSelect: Bool {
        switch status {
        case .ready, .awaitingConfirmation, .automaticPending, .waitingRetention,
             .recentlyModified, .unstable, .unmatched:
            return true
        default:
            return false
        }
    }

    func replacing(
        status: FileProcessingStatus,
        detail: String,
        remainingSeconds: TimeInterval? = nil,
        destination: URL? = nil
    ) -> FileProcessingAssessment {
        FileProcessingAssessment(
            status: status,
            source: source,
            canonicalSource: canonicalSource,
            signature: signature,
            ruleIndex: ruleIndex,
            rule: rule,
            target: target,
            destination: destination ?? self.destination,
            detail: detail,
            remainingSeconds: remainingSeconds ?? self.remainingSeconds,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            didMove: didMove
        )
    }

    func scanItem() -> FileAssessmentItem {
        FileAssessmentItem(
            path: source.path,
            fileName: source.lastPathComponent,
            fileExtension: source.pathExtension,
            fileSize: fileSize,
            modifiedAt: modifiedAt.map(iso8601String) ?? "",
            status: status,
            reason: detail,
            remainingSeconds: remainingSeconds,
            ruleName: ruleName,
            targetFolder: target?.path ?? "",
            destinationPath: destination?.path ?? "",
            canSelect: canSelect,
            canMoveNow: canMove
        )
    }

    private var ruleName: String {
        if let name = rule?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let keyword = rule?.keywords.first, !keyword.isEmpty { return keyword }
        if let ruleIndex { return "规则 \(ruleIndex + 1)" }
        return ""
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        rulesFingerprint = try c.decodeIfPresent(String.self, forKey: .rulesFingerprint) ?? ""
        files = try c.decodeIfPresent([String: StateRecord].self, forKey: .files) ?? [:]
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

    init(
        id: String,
        timestamp: Date,
        originalPath: String,
        destinationPath: String,
        reason: String,
        undone: Bool,
        batchID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalPath = originalPath
        self.destinationPath = destinationPath
        self.reason = reason
        self.undone = undone
        self.batchID = batchID
    }
}

final class SorterLogger {
    private let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func write(_ level: String = "INFO", _ message: String) {
        rotateIfNeeded()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) | \(level) | \(message)\n"
        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
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

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
}

private func pathIsInside(_ candidate: URL, root: URL) -> Bool {
    let rootPath = canonicalFileURL(root).path
    let candidatePath = canonicalFileURL(candidate).path
    let prefix = rootPath == "/" ? "/" : (rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
}

private func isSymbolicLink(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFLNK
}

private extension FileProcessingStatus {
    var logLabel: String {
        switch self {
        case .ready, .awaitingConfirmation: return "可以整理"
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
        case .waitingRetention: return "仍在保留期内"
        case .recentlyModified: return "最近修改保护中"
        case .automaticPending, .unstable: return "文件仍在写入或状态发生变化"
        case .unmatched: return "未分类"
        case .sameLocation: return "来源与目标相同"
        case .destinationInWatchFolder: return "目标位于监听目录内"
        case .invalidTarget: return "目标目录无效"
        case .permissionError: return "权限错误"
        case .symlink: return "符号链接"
        case .failed: return "失败"
        }
    }
}

private enum NativeSorterError: LocalizedError {
    case mutationBusy
    case lockFailure(String)
    case corruptPersistence(URL, String)
    case persistenceRead(URL, String)

    var errorDescription: String? {
        switch self {
        case .mutationBusy:
            return "整理服务正忙，未能在合理时间取得变更锁；请稍后重试。"
        case .lockFailure(let message):
            return "无法取得整理变更锁：\(message)"
        case .corruptPersistence(let url, let message):
            return "持久化文件已损坏，已保留原文件 \(url.path)：\(message)"
        case .persistenceRead(let url, let message):
            return "无法读取持久化文件 \(url.path)：\(message)"
        }
    }
}

private final class MutationLock {
    private let descriptor: Int32

    init(url: URL, timeout: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NativeSorterError.lockFailure(String(cString: strerror(errno)))
        }
        self.descriptor = descriptor

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                close(descriptor)
                throw NativeSorterError.lockFailure(String(cString: strerror(lockError)))
            }
            guard Date() < deadline else {
                close(descriptor)
                throw NativeSorterError.mutationBusy
            }
            Thread.sleep(forTimeInterval: min(0.05, max(0.005, deadline.timeIntervalSinceNow)))
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

final class NativeSorter {
    let configURL: URL
    var config: AgentConfig
    let base: URL
    let logger: SorterLogger
    let stateURL: URL
    let historyURL: URL
    let watchURL: URL
    let mutationLockURL: URL
    private let manager = FileManager.default

    init(configURL: URL) throws {
        self.configURL = configURL
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: configURL))
        config = decoded
        guard !decoded.rules.contains(where: {
            $0.enabled && (($0.keywords.isEmpty && $0.extensions.isEmpty && $0.nameRegex.isEmpty) || $0.target.isEmpty)
        }) else {
            throw NSError(
                domain: "AIFileSorter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "规则需要关键词、扩展名或正则表达式，以及目标目录"]
            )
        }
        for (index, rule) in decoded.rules.enumerated() where rule.enabled {
            if !rule.nameRegex.isEmpty, (try? NSRegularExpression(pattern: rule.nameRegex)) == nil {
                throw NSError(
                    domain: "AIFileSorter",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的正则表达式无效"]
                )
            }
            if let minimum = rule.minimumSizeMB, let maximum = rule.maximumSizeMB, minimum > maximum {
                throw NSError(
                    domain: "AIFileSorter",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的最小大小不能大于最大大小"]
                )
            }
            if [rule.minimumSizeMB, rule.maximumSizeMB].compactMap({ $0 }).contains(where: { $0 < 0 })
                || [rule.modifiedOlderThanDays, rule.modifiedNewerThanDays]
                    .compactMap({ $0 }).contains(where: { $0 < 0 }) {
                throw NSError(
                    domain: "AIFileSorter",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "规则 \(index + 1) 的大小和天数不能为负数"]
                )
            }
        }

        let resolvedBase = configURL.deletingLastPathComponent().standardizedFileURL
        base = resolvedBase
        func resolveURL(_ value: String) -> URL {
            let expanded = NSString(string: value).expandingTildeInPath
            return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : resolvedBase.appendingPathComponent(expanded))
                .standardizedFileURL
        }
        stateURL = resolveURL(decoded.stateFile)
        historyURL = resolveURL(decoded.historyFile)
        watchURL = resolveURL(decoded.watchFolder)
        mutationLockURL = resolvedBase.appendingPathComponent("logs/sorter-mutation.lock")
        logger = SorterLogger(url: resolveURL(decoded.logFile))
        if decoded.rules.contains(where: { $0.enabled && pathIsInside(resolveURL($0.target), root: watchURL) }) {
            throw NSError(
                domain: "AIFileSorter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "规则目标不能位于监听文件夹内"]
            )
        }
        try manager.createDirectory(at: watchURL, withIntermediateDirectories: true)
    }

    var fingerprint: String {
        let data = (try? JSONEncoder().encode(config.rules)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func signature(_ url: URL) throws -> FileSignature {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize, let modified = values.contentModificationDate else {
            throw NativeSorterError.persistenceRead(url, "无法读取文件大小或修改时间")
        }
        return FileSignature(
            size: UInt64(fileSize),
            modified: Int64(modified.timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func supportedFiles() -> [URL] {
        let supported = Set(config.extensions.map {
            $0.hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()
        })
        let urls = (try? manager.contentsOfDirectory(
            at: watchURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            return regular && !isSymbolicLink(url) && !name.hasPrefix(".")
                && !temporaryFileSuffixes.contains(where: { name.lowercased().hasSuffix($0) })
                && supported.contains("." + url.pathExtension.lowercased())
        }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func firstLevelEntries() throws -> [URL] {
        try manager.contentsOfDirectory(
            at: watchURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey, .isUserImmutableKey
            ],
            options: []
        ).sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func pathMatches(_ file: URL, configuredPath: String) -> Bool {
        pathIsInside(file, root: resolveConfiguredPath(configuredPath))
    }

    func isEligible(_ file: URL) -> Bool {
        evaluate(file, intent: .eligibility).status == .ready
    }

    private func resolveConfiguredPath(_ value: String) -> URL {
        let expanded = NSString(string: value).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded))
            .standardizedFileURL
    }

    private func resolveTarget(_ value: String) -> URL {
        resolveConfiguredPath(value)
    }

    private enum LockState {
        case unlocked
        case locked
        case unavailable
    }

    private func lockState(_ file: URL, values: URLResourceValues) -> LockState {
        if values.isUserImmutable == true { return .locked }
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            return (errno == EACCES || errno == EPERM) ? .unavailable : .unlocked
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            flock(descriptor, LOCK_UN)
            return .unlocked
        }
        let lockError = errno
        if lockError == EWOULDBLOCK || lockError == EAGAIN { return .locked }
        if lockError == EACCES || lockError == EPERM { return .unavailable }
        return .unlocked
    }

    private func assessment(
        source: URL,
        canonicalSource: URL,
        status: FileProcessingStatus,
        detail: String,
        signature: FileSignature? = nil,
        ruleIndex: Int? = nil,
        rule: AgentRule? = nil,
        target: URL? = nil,
        destination: URL? = nil,
        remainingSeconds: TimeInterval = 0,
        values: URLResourceValues? = nil
    ) -> FileProcessingAssessment {
        FileProcessingAssessment(
            status: status,
            source: source,
            canonicalSource: canonicalSource,
            signature: signature,
            ruleIndex: ruleIndex,
            rule: rule,
            target: target,
            destination: destination,
            detail: detail,
            remainingSeconds: max(0, remainingSeconds),
            fileSize: values?.fileSize.map(UInt64.init) ?? signature?.size ?? 0,
            modifiedAt: values?.contentModificationDate,
            didMove: false
        )
    }

    func evaluate(
        _ source: URL,
        intent: FileProcessingIntent,
        expectedSignature: FileSignature? = nil,
        stableSince: Date? = nil
    ) -> FileProcessingAssessment {
        let standardizedSource = source.standardizedFileURL
        let canonicalSource = canonicalFileURL(standardizedSource)

        guard pathIsInside(standardizedSource, root: watchURL), pathIsInside(canonicalSource, root: watchURL) else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .sourceOutsideWatchFolder,
                detail: "来源不在监听目录内：\(canonicalSource.path)"
            )
        }
        if isSymbolicLink(standardizedSource) {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .symlink,
                detail: "符号链接不会被整理：\(standardizedSource.lastPathComponent)"
            )
        }
        guard manager.fileExists(atPath: standardizedSource.path) else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .missing,
                detail: "文件已不存在：\(standardizedSource.path)"
            )
        }

        let name = standardizedSource.lastPathComponent
        if name.hasPrefix(".") {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .hidden,
                detail: "隐藏文件不会自动整理：\(name)"
            )
        }
        if temporaryFileSuffixes.contains(where: { name.lowercased().hasSuffix($0) }) {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .temporary,
                detail: "临时下载后缀不会整理：\(name)"
            )
        }

        guard let values = try? standardizedSource.resourceValues(forKeys: [
            .isRegularFileKey, .creationDateKey, .contentModificationDateKey,
            .fileSizeKey, .isUserImmutableKey, .tagNamesKey
        ]) else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .metadataUnavailable,
                detail: "无法读取文件状态：\(canonicalSource.path)"
            )
        }
        guard values.isRegularFile == true else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .notRegularFile,
                detail: "不是普通文件：\(name)",
                values: values
            )
        }
        guard values.fileSize != nil, values.contentModificationDate != nil else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .metadataUnavailable,
                detail: "无法读取文件大小或修改时间：\(canonicalSource.path)",
                values: values
            )
        }
        guard let currentSignature = try? signature(canonicalSource) else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .metadataUnavailable,
                detail: "无法读取文件签名：\(canonicalSource.path)",
                values: values
            )
        }

        if case .confirmedMove = intent {
            // 明确确认的单次整理可绕过时间保护和自动扩展名白名单，
            // 但不能绕过隐藏、临时、锁定、符号链接和目标安全检查。
        } else {
            let supported = Set(config.extensions.map {
                $0.hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()
            })
            guard supported.contains("." + canonicalSource.pathExtension.lowercased()) else {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .unsupported,
                    detail: "文件类型不在自动整理白名单中：\(name)",
                    signature: currentSignature,
                    values: values
                )
            }
        }
        if config.excludedPaths.contains(where: { pathMatches(canonicalSource, configuredPath: $0) }) {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .excluded,
                detail: "文件位于排除路径：\(canonicalSource.path)",
                signature: currentSignature,
                values: values
            )
        }
        switch lockState(canonicalSource, values: values) {
        case .locked:
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .locked,
                detail: "文件已锁定或被其他进程占用：\(canonicalSource.path)",
                signature: currentSignature,
                values: values
            )
        case .unavailable:
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .permissionError,
                detail: "没有权限检查或访问文件：\(canonicalSource.path)",
                signature: currentSignature,
                values: values
            )
        case .unlocked:
            break
        }

        if let expectedSignature, expectedSignature != currentSignature {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .unstable,
                detail: "文件在稳定等待期间发生变化：\(canonicalSource.path)",
                signature: currentSignature,
                remainingSeconds: config.stableSeconds,
                values: values
            )
        }

        let selectedRule: (offset: Int, element: AgentRule)?
        let target: URL?
        switch intent {
        case .confirmedMove(let requestedTarget):
            selectedRule = nil
            target = requestedTarget.standardizedFileURL
        case .eligibility:
            selectedRule = nil
            target = nil
        default:
            selectedRule = config.rules.enumerated().first { _, rule in
                rule.matches(canonicalSource, values: values)
            }
            guard let selectedRule else {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .unmatched,
                    detail: "没有匹配规则：\(canonicalSource.path)",
                    signature: currentSignature,
                    values: values
                )
            }
            target = resolveTarget(selectedRule.element.target)
        }

        if case .eligibility = intent {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .ready,
                detail: "文件符合安全条件",
                signature: currentSignature,
                values: values
            )
        }

        guard let target else {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .invalidTarget,
                detail: "目标目录为空",
                signature: currentSignature,
                ruleIndex: selectedRule?.offset,
                rule: selectedRule?.element,
                values: values
            )
        }
        let canonicalTarget = canonicalFileURL(target)
        if target.path.isEmpty {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .invalidTarget,
                detail: "目标目录为空",
                signature: currentSignature,
                ruleIndex: selectedRule?.offset,
                rule: selectedRule?.element,
                target: target,
                values: values
            )
        }
        if canonicalTarget == canonicalSource
            || canonicalTarget == canonicalFileURL(canonicalSource.deletingLastPathComponent()) {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .sameLocation,
                detail: "来源与目标目录相同：\(canonicalTarget.path)",
                signature: currentSignature,
                ruleIndex: selectedRule?.offset,
                rule: selectedRule?.element,
                target: canonicalTarget,
                values: values
            )
        }
        if pathIsInside(target, root: watchURL) || pathIsInside(canonicalTarget, root: watchURL) {
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .destinationInWatchFolder,
                detail: "目标位于监听目录内，可能形成整理循环：\(canonicalTarget.path)",
                signature: currentSignature,
                ruleIndex: selectedRule?.offset,
                rule: selectedRule?.element,
                target: canonicalTarget,
                values: values
            )
        }
        if manager.fileExists(atPath: target.path) {
            guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .invalidTarget,
                    detail: "目标路径不是目录：\(target.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    values: values
                )
            }
            guard manager.isWritableFile(atPath: target.path) else {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .permissionError,
                    detail: "没有权限写入目标目录：\(target.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    values: values
                )
            }
        } else {
            var parent = target.deletingLastPathComponent()
            while !manager.fileExists(atPath: parent.path), parent.path != "/" {
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
            if manager.fileExists(atPath: parent.path),
               (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .invalidTarget,
                    detail: "目标目录的父路径不是目录：\(parent.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    values: values
                )
            }
            if manager.fileExists(atPath: parent.path), !manager.isWritableFile(atPath: parent.path) {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .permissionError,
                    detail: "没有权限创建目标目录：\(parent.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    values: values
                )
            }
        }

        let candidateDestination = collisionFree(
            target.appendingPathComponent(destinationName(canonicalSource, rule: selectedRule?.element))
        )
        let now = Date()
        let modified = values.contentModificationDate ?? values.creationDate ?? now
        let ageReference = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? modified
        if !intent.bypassTimeProtection {
            if config.retentionDays > 0 {
                let remaining = Double(config.retentionDays) * 86_400 - now.timeIntervalSince(ageReference)
                if remaining > 0 {
                    return assessment(
                        source: standardizedSource,
                        canonicalSource: canonicalSource,
                        status: .waitingRetention,
                        detail: "文件仍在保留期内：\(canonicalSource.path)",
                        signature: currentSignature,
                        ruleIndex: selectedRule?.offset,
                        rule: selectedRule?.element,
                        target: canonicalTarget,
                        destination: candidateDestination,
                        remainingSeconds: remaining,
                        values: values
                    )
                }
            }
            if config.recentModificationProtectionHours > 0 {
                let remaining = Double(config.recentModificationProtectionHours) * 3_600
                    - now.timeIntervalSince(modified)
                if remaining > 0 {
                    return assessment(
                        source: standardizedSource,
                        canonicalSource: canonicalSource,
                        status: .recentlyModified,
                        detail: "文件最近修改保护中：\(canonicalSource.path)",
                        signature: currentSignature,
                        ruleIndex: selectedRule?.offset,
                        rule: selectedRule?.element,
                        target: canonicalTarget,
                        destination: candidateDestination,
                        remainingSeconds: remaining,
                        values: values
                    )
                }
            }
        }

        if case .scanJSON = intent {
            if config.organizationMode == "automatic", config.stableSeconds > 0 {
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: .automaticPending,
                    detail: "自动整理将在文件稳定后执行：\(canonicalSource.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    destination: candidateDestination,
                    remainingSeconds: config.stableSeconds,
                    values: values
                )
            }
            return assessment(
                source: standardizedSource,
                canonicalSource: canonicalSource,
                status: .awaitingConfirmation,
                detail: "文件符合整理规则，等待确认",
                signature: currentSignature,
                ruleIndex: selectedRule?.offset,
                rule: selectedRule?.element,
                target: canonicalTarget,
                destination: candidateDestination,
                values: values
            )
        }

        if intent.requiresStability, config.stableSeconds > 0 {
            guard let stableSince else {
                let pendingStatus: FileProcessingStatus = intent.isAutomatic ? .automaticPending : .unstable
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: pendingStatus,
                    detail: "文件尚未稳定 \(String(config.stableSeconds)) 秒：\(canonicalSource.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    destination: candidateDestination,
                    remainingSeconds: config.stableSeconds,
                    values: values
                )
            }
            let remaining = config.stableSeconds - now.timeIntervalSince(stableSince)
            if remaining > 0 {
                let pendingStatus: FileProcessingStatus = intent.isAutomatic ? .automaticPending : .unstable
                return assessment(
                    source: standardizedSource,
                    canonicalSource: canonicalSource,
                    status: pendingStatus,
                    detail: "文件尚未稳定 \(String(format: "%.1f", remaining)) 秒：\(canonicalSource.path)",
                    signature: currentSignature,
                    ruleIndex: selectedRule?.offset,
                    rule: selectedRule?.element,
                    target: canonicalTarget,
                    destination: candidateDestination,
                    remainingSeconds: remaining,
                    values: values
                )
            }
        }

        return assessment(
            source: standardizedSource,
            canonicalSource: canonicalSource,
            status: .ready,
            detail: "文件符合安全条件",
            signature: currentSignature,
            ruleIndex: selectedRule?.offset,
            rule: selectedRule?.element,
            target: canonicalTarget,
            destination: candidateDestination,
            values: values
        )
    }

    private func swiftDateFormat(_ python: String) -> String {
        python.replacingOccurrences(of: "%Y", with: "yyyy")
            .replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd")
            .replacingOccurrences(of: "%H", with: "HH")
            .replacingOccurrences(of: "%M", with: "mm")
            .replacingOccurrences(of: "%S", with: "ss")
    }

    private func destinationName(_ source: URL, rule: AgentRule?) -> String {
        guard config.rename.enabled, let rule else { return source.lastPathComponent }
        let formatter = DateFormatter()
        formatter.dateFormat = swiftDateFormat(config.rename.dateFormat)
        let ext = source.pathExtension
        let keyword = rule.keywords.first(where: {
            source.lastPathComponent.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) ?? "关键词"
        let category = resolveTarget(rule.target).lastPathComponent
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
        guard manager.fileExists(atPath: destination.path) else { return destination }
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

    private func withMutationLock<T>(timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let lock = try MutationLock(url: mutationLockURL, timeout: timeout)
        // The lock is intentionally kept alive until the body returns.
        defer { _ = lock }
        return try body()
    }

    private func rawDataLocked(at url: URL) throws -> Data? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) }
        catch { throw NativeSorterError.persistenceRead(url, error.localizedDescription) }
    }

    private func readHistoryLocked() throws -> [MoveHistoryRecord] {
        guard let data = try rawDataLocked(at: historyURL) else { return [] }
        do { return try JSONDecoder().decode([MoveHistoryRecord].self, from: data) }
        catch { throw NativeSorterError.corruptPersistence(historyURL, error.localizedDescription) }
    }

    private func readStateLocked() throws -> AgentState {
        guard let data = try rawDataLocked(at: stateURL) else { return AgentState() }
        do {
            var state = try JSONDecoder().decode(AgentState.self, from: data)
            if state.version < 2 {
                state.version = 2
                logger.write("INFO", "已将 1.x 状态文件迁移到原生 2.0 格式")
            }
            return state
        }
        catch let modernError {
            // Preserve and migrate only the known 1.x shape. Arbitrary or
            // partially decoded JSON is corruption and must never become {}.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !root.isEmpty,
                  root["version"] != nil || root["initialized"] != nil
                    || root["rules_fingerprint"] != nil || root["files"] != nil else {
                throw NativeSorterError.corruptPersistence(stateURL, modernError.localizedDescription)
            }
            if let initialized = root["initialized"], !(initialized is Bool) {
                throw NativeSorterError.corruptPersistence(stateURL, "initialized 字段格式无效")
            }
            if let fingerprint = root["rules_fingerprint"], !(fingerprint is String) {
                throw NativeSorterError.corruptPersistence(stateURL, "rules_fingerprint 字段格式无效")
            }
            var migrated = AgentState()
            migrated.initialized = root["initialized"] as? Bool ?? false
            migrated.rulesFingerprint = root["rules_fingerprint"] as? String ?? ""
            if let rawFiles = root["files"] {
                guard let files = rawFiles as? [String: Any] else {
                    throw NativeSorterError.corruptPersistence(stateURL, "旧版 files 字段格式无效")
                }
                for (path, rawValue) in files {
                    guard let value = rawValue as? [String: Any],
                          let size = (value["size"] as? NSNumber)?.uint64Value,
                          let modified = (value["mtime_ns"] as? NSNumber)?.int64Value else {
                        throw NativeSorterError.corruptPersistence(stateURL, "旧版 files 条目格式无效")
                    }
                    migrated.files[path] = StateRecord(
                        signature: FileSignature(size: size, modified: modified),
                        reason: value["reason"] as? String ?? "baseline"
                    )
                }
            }
            logger.write("INFO", "已将 1.x 状态文件迁移到原生 2.0 格式")
            return migrated
        }
    }

    private func encodedHistory(_ records: [MoveHistoryRecord]) throws -> Data {
        try JSONEncoder().encode(Array(records.suffix(500)))
    }

    private func encodedState(_ state: AgentState) throws -> Data {
        try JSONEncoder().encode(state)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func restore(_ data: Data?, at url: URL) {
        do {
            if let data {
                try writeAtomically(data, to: url)
            } else if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        } catch {
            logger.write("ERROR", "事务回滚持久化文件失败：\(url.path) | \(error.localizedDescription)")
        }
    }

    private func updateState(_ mutation: (inout AgentState) throws -> Void, timeout: TimeInterval = 0.25) throws {
        try withMutationLock(timeout: timeout) {
            var state = try readStateLocked()
            try mutation(&state)
            try writeAtomically(try encodedState(state), to: stateURL)
        }
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
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", script, stagingSource.path,
            destination.deletingLastPathComponent().path,
            destination.lastPathComponent
        ]
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(
                    domain: "AIFileSorter",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Finder 移动失败"]
                )
            }
        } catch {
            let movedStaging = destination.deletingLastPathComponent().appendingPathComponent(stagingName)
            if manager.fileExists(atPath: stagingSource.path) {
                try? manager.moveItem(at: stagingSource, to: source)
            } else if manager.fileExists(atPath: movedStaging.path) && !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: movedStaging, to: source)
            }
            throw error
        }
    }

    private func logAssessment(_ assessment: FileProcessingAssessment, level: String = "INFO") {
        logger.write(
            level,
            "原文件=\(assessment.source.path) | 目标=\(assessment.target?.path ?? "-") | "
                + "结果=\(assessment.status.logLabel) | 说明=\(assessment.detail)"
        )
    }

    @discardableResult
    func process(
        _ source: URL,
        intent: FileProcessingIntent,
        batchID: String? = nil,
        expectedSignature: FileSignature? = nil,
        stableSince: Date? = nil
    ) -> FileProcessingAssessment {
        let preliminary = evaluate(
            source,
            intent: intent,
            expectedSignature: expectedSignature,
            stableSince: stableSince
        )
        guard preliminary.canMove else {
            logAssessment(preliminary)
            return preliminary
        }

        do {
            return try withMutationLock(timeout: intent.mutationTimeout) {
                // The lock is deliberately acquired after the potentially
                // long stability wait. This is the authoritative recheck.
                let latest = evaluate(
                    source,
                    intent: intent,
                    expectedSignature: expectedSignature,
                    stableSince: stableSince
                )
                guard latest.canMove, let folder = latest.target else {
                    logAssessment(latest)
                    return latest
                }

                let oldHistory = try rawDataLocked(at: historyURL)
                let oldState = try rawDataLocked(at: stateURL)
                var records = try readHistoryLocked()
                var state = try readStateLocked()
                if intent.isAutomatic,
                   let stateRecord = state.files[latest.canonicalSource.path],
                   stateRecord.reason == "undo",
                   stateRecord.signature == latest.signature {
                    let skipped = latest.replacing(
                        status: .automaticPending,
                        detail: "文件刚刚撤销，等待文件状态变化后再自动整理"
                    )
                    logAssessment(skipped)
                    return skipped
                }
                state.initialized = true
                state.rulesFingerprint = fingerprint

                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = collisionFree(
                    folder.appendingPathComponent(destinationName(latest.canonicalSource, rule: latest.rule))
                )
                let reason = latest.ruleIndex.map { "规则 \($0 + 1)" } ?? "单次整理"
                records.append(MoveHistoryRecord(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    originalPath: latest.canonicalSource.path,
                    destinationPath: destination.path,
                    reason: reason,
                    undone: false,
                    batchID: batchID
                ))
                state.files.removeValue(forKey: latest.canonicalSource.path)
                let historyData = try encodedHistory(records)
                let stateData = try encodedState(state)

                do {
                    if config.moveMethod == "finder" {
                        try moveWithFinder(latest.canonicalSource, destination)
                    } else {
                        try manager.moveItem(at: latest.canonicalSource, to: destination)
                    }
                    do {
                        try writeAtomically(historyData, to: historyURL)
                        try writeAtomically(stateData, to: stateURL)
                    } catch {
                        if manager.fileExists(atPath: destination.path) && !manager.fileExists(atPath: latest.canonicalSource.path) {
                            try? manager.moveItem(at: destination, to: latest.canonicalSource)
                        }
                        restore(oldHistory, at: historyURL)
                        restore(oldState, at: stateURL)
                        throw error
                    }
                } catch {
                    throw error
                }

                let moved = FileProcessingAssessment(
                    status: .ready,
                    source: latest.source,
                    canonicalSource: latest.canonicalSource,
                    signature: latest.signature,
                    ruleIndex: latest.ruleIndex,
                    rule: latest.rule,
                    target: latest.target,
                    destination: destination,
                    detail: destination.path,
                    remainingSeconds: 0,
                    fileSize: latest.fileSize,
                    modifiedAt: latest.modifiedAt,
                    didMove: true
                )
                logger.write(
                    "INFO",
                    "原文件=\(latest.canonicalSource.path) | 目标=\(destination.path) | 结果=成功 | 说明=\(reason) 匹配并移动"
                )
                return moved
            }
        } catch {
            let failed = preliminary.replacing(status: .failed, detail: error.localizedDescription)
            logAssessment(failed, level: "ERROR")
            return failed
        }
    }

    @discardableResult
    func sort(_ source: URL, batchID: String? = nil, expectedSignature: FileSignature? = nil, stableSince: Date? = nil) -> String {
        let result = process(
            source,
            intent: .plan,
            batchID: batchID,
            expectedSignature: expectedSignature,
            stableSince: stableSince
        )
        switch result.status {
        case .ready where result.didMove: return "moved"
        case .unmatched: return "unknown"
        case .failed: return "error"
        default: return "skipped"
        }
    }

    // 单次整理不会创建规则，保留原文件名，并与自动整理共用变更锁及历史记录。
    func moveOnce(sourcePath: String, targetPath: String, batchID: String? = nil) -> Int32 {
        let source = URL(fileURLWithPath: NSString(string: sourcePath).expandingTildeInPath)
        let folder = resolveConfiguredPath(targetPath)
        let result = process(source, intent: .confirmedMove(target: folder), batchID: batchID)
        if result.didMove, let destination = result.destination {
            print("单次整理完成：\(source.lastPathComponent) → \(destination.path)")
            return 0
        }
        print("单次整理未执行：\(result.status.logLabel)（\(result.detail)）")
        return 1
    }

    func moveMany(sourcePaths: [String], targetPath: String) -> Int32 {
        let batchID = UUID().uuidString
        var failures = 0
        for path in sourcePaths where moveOnce(sourcePath: path, targetPath: targetPath, batchID: batchID) != 0 {
            failures += 1
        }
        print("批量单次整理完成：成功 \(sourcePaths.count - failures) 个，失败 \(failures) 个")
        return failures == 0 ? 0 : 1
    }

    func sortPaths(_ paths: [String]) -> Int32 {
        let batchID = UUID().uuidString
        var moved = 0
        var failed = 0
        let started = Date()
        let snapshots = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            return try? (source.standardizedFileURL.path, signature(source))
        })
        Thread.sleep(forTimeInterval: max(0, config.stableSeconds))
        for path in paths {
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let result = process(
                source,
                intent: .plan,
                batchID: batchID,
                expectedSignature: snapshots[source.standardizedFileURL.path],
                stableSince: started
            )
            if result.didMove { moved += 1 } else { failed += 1 }
        }
        print("整理计划执行完成：成功 \(moved) 个，失败或已不匹配 \(failed) 个")
        return failed == 0 ? 0 : 1
    }

    private enum UndoOutcome {
        case moved(id: String, path: String)
        case none
        case alreadyUndone
        case unavailable(id: String, message: String)
    }

    private func performUndo(
        historyID: String? = nil,
        batchID: String? = nil,
        excluding: Set<String> = []
    ) throws -> UndoOutcome {
        try withMutationLock(timeout: 10) {
            let oldHistory = try rawDataLocked(at: historyURL)
            let oldState = try rawDataLocked(at: stateURL)
            var records = try readHistoryLocked()
            let index: Int?
            if let historyID {
                index = records.firstIndex(where: { $0.id == historyID })
            } else if let batchID {
                index = records.indices.reversed().first {
                    records[$0].batchID == batchID && !records[$0].undone && !excluding.contains(records[$0].id)
                }
            } else {
                index = nil
            }
            guard let index else { return .none }
            guard !records[index].undone else { return .alreadyUndone }

            let record = records[index]
            let destination = URL(fileURLWithPath: record.destinationPath)
            guard manager.fileExists(atPath: destination.path) else {
                return .unavailable(id: record.id, message: "目标文件已不存在，无法撤销")
            }
            guard !isSymbolicLink(destination) else {
                return .unavailable(id: record.id, message: "目标文件是符号链接，拒绝撤销")
            }

            var state = try readStateLocked()
            let requested = URL(fileURLWithPath: record.originalPath)
            try manager.createDirectory(at: requested.deletingLastPathComponent(), withIntermediateDirectories: true)
            let restored = collisionFree(requested)
            var didMoveToRestored = false
            do {
                try manager.moveItem(at: destination, to: restored)
                didMoveToRestored = true
                guard let restoredSignature = try? signature(restored) else {
                    throw NativeSorterError.persistenceRead(restored, "撤销后无法读取文件签名")
                }
                records[index].originalPath = restored.path
                records[index].undone = true
                state.initialized = true
                state.rulesFingerprint = fingerprint
                state.files[canonicalFileURL(restored).path] = StateRecord(
                    signature: restoredSignature,
                    reason: "undo"
                )
                let historyData = try encodedHistory(records)
                let stateData = try encodedState(state)
                do {
                    try writeAtomically(historyData, to: historyURL)
                    try writeAtomically(stateData, to: stateURL)
                } catch {
                    if manager.fileExists(atPath: restored.path) && !manager.fileExists(atPath: destination.path) {
                        do {
                            try manager.moveItem(at: restored, to: destination)
                            didMoveToRestored = false
                        } catch {
                            logger.write("ERROR", "撤销事务回滚文件失败：\(error.localizedDescription)")
                        }
                    }
                    restore(oldHistory, at: historyURL)
                    restore(oldState, at: stateURL)
                    throw error
                }
            } catch {
                if didMoveToRestored,
                   manager.fileExists(atPath: restored.path),
                   !manager.fileExists(atPath: destination.path) {
                    do {
                        try manager.moveItem(at: restored, to: destination)
                    } catch {
                        logger.write("ERROR", "撤销失败后的文件回滚失败：\(error.localizedDescription)")
                    }
                }
                throw error
            }
            logger.write("INFO", "原文件=\(destination.path) | 目标=\(restored.path) | 结果=成功 | 说明=撤销整理")
            return .moved(id: record.id, path: restored.path)
        }
    }

    func undo(historyID: String) -> Int32 {
        do {
            switch try performUndo(historyID: historyID) {
            case .moved(_, let path):
                print("已撤销：\(URL(fileURLWithPath: path).lastPathComponent) 已移回原目录")
                return 0
            case .none: print("找不到整理记录")
            case .alreadyUndone: print("这条整理记录已经撤销")
            case .unavailable(_, let message): print(message)
            }
        } catch {
            logger.write("ERROR", "撤销失败：\(error.localizedDescription)")
            print("撤销失败：\(error.localizedDescription)")
        }
        return 1
    }

    func undoBatch(batchID: String) -> Int32 {
        var attempted: Set<String> = []
        var successes = 0
        var failures = 0
        while true {
            do {
                switch try performUndo(batchID: batchID, excluding: attempted) {
                case .none:
                    if successes == 0 && failures == 0 {
                        print("找不到可撤销的整理批次")
                        return 1
                    }
                    print("批次撤销完成：成功 \(successes) 个，失败 \(failures) 个")
                    return failures == 0 && successes > 0 ? 0 : 1
                case .moved(let id, _):
                    attempted.insert(id)
                    successes += 1
                case .alreadyUndone:
                    print("批次中没有可撤销的整理记录")
                    return failures == 0 && successes > 0 ? 0 : 1
                case .unavailable(let id, let message):
                    attempted.insert(id)
                    failures += 1
                    logger.write("ERROR", "批次撤销失败：\(message)")
                }
            } catch {
                failures += 1
                logger.write("ERROR", "批次撤销失败：\(error.localizedDescription)")
                print("批次撤销失败：\(error.localizedDescription)")
                return 1
            }
        }
    }

    func scanJSON() -> Int32 {
        let items: [FileAssessmentItem]
        do {
            items = try firstLevelEntries().map { evaluate($0, intent: .scanJSON).scanItem() }
        } catch {
            let item = FileAssessmentItem(
                path: watchURL.path,
                fileName: watchURL.lastPathComponent,
                fileExtension: "",
                fileSize: 0,
                modifiedAt: "",
                status: .permissionError,
                reason: "无法读取监听目录：\(error.localizedDescription)",
                remainingSeconds: 0,
                ruleName: "",
                targetFolder: "",
                destinationPath: "",
                canSelect: false,
                canMoveNow: false
            )
            do {
                try writeScanJSON(items: [item])
            } catch {
                writeStandardError("扫描监听目录失败且错误结果无法输出：\(error.localizedDescription)\n")
            }
            return 1
        }
        do {
            try writeScanJSON(items: items)
            return 0
        } catch {
            writeStandardError("输出扫描 JSON 失败：\(error.localizedDescription)\n")
            return 1
        }
    }

    private func writeScanJSON(items: [FileAssessmentItem]) throws {
        let document = FileAssessmentDocument(
            generatedAt: iso8601String(Date()),
            watchFolder: watchURL.path,
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try FileHandle.standardOutput.write(contentsOf: data)
        try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    }

    private func eventState(initialFiles: [URL]) throws -> (AgentState, shouldExit: Bool) {
        try withMutationLock(timeout: 0.25) {
            var state = try readStateLocked()
            if !state.initialized {
                state.rulesFingerprint = fingerprint
                if !config.processExisting {
                    for url in initialFiles {
                        let canonical = canonicalFileURL(url)
                        if let signature = try? signature(canonical) {
                            state.files[canonical.path] = StateRecord(signature: signature, reason: "baseline")
                        }
                    }
                    state.initialized = true
                    try writeAtomically(try encodedState(state), to: stateURL)
                    logger.write("INFO", "首次启动：保留现有文件 \(initialFiles.count) 个")
                    return (state, true)
                }
                state.initialized = true
            }
            if state.rulesFingerprint != fingerprint {
                state.files = state.files.filter { $0.value.reason != "unmatched" }
                state.rulesFingerprint = fingerprint
            }
            let existing = Set(initialFiles.map { canonicalFileURL($0).path })
            // Keep undo markers even when this directory snapshot predates the
            // restore. The next automatic pass must see the marker and wait
            // for a signature change instead of immediately moving the file again.
            state.files = state.files.filter { existing.contains($0.key) || $0.value.reason == "undo" }
            try writeAtomically(try encodedState(state), to: stateURL)
            return (state, false)
        }
    }

    @discardableResult
    private func markUnmatched(_ assessment: FileProcessingAssessment) -> Bool {
        guard let expected = assessment.signature else { return true }
        do {
            try updateState({ state in
                let key = assessment.canonicalSource.path
                guard state.files[key]?.reason != "undo",
                      let current = try? signature(assessment.canonicalSource), current == expected else { return }
                state.files[key] = StateRecord(signature: expected, reason: "unmatched")
            })
            return true
        } catch {
            logger.write("ERROR", "未匹配状态写入失败：\(error.localizedDescription)")
            return false
        }
    }

    func runEvent() -> Int32 {
        let initialFiles = supportedFiles()
        let initial: (AgentState, shouldExit: Bool)
        do {
            initial = try eventState(initialFiles: initialFiles)
        } catch {
            logger.write("ERROR", "读取或写入状态失败：\(error.localizedDescription)")
            return 1
        }
        if initial.shouldExit { return 0 }
        guard config.organizationMode == "automatic" else {
            logger.write("INFO", "当前整理模式不允许后台自动移动：\(config.organizationMode)")
            return 0
        }

        var stable: [String: (FileSignature, Date)] = [:]
        var failed: Set<String> = []
        var hadFailure = false
        let started = Date()
        var idleSince: Date?
        while Date().timeIntervalSince(started) < config.maxRuntime {
            let files = supportedFiles()
            let existing = Set(files.map { canonicalFileURL($0).path })
            stable = stable.filter { existing.contains($0.key) }
            let state: AgentState
            do {
                state = try eventState(initialFiles: files).0
            } catch {
                logger.write("ERROR", "读取或写入状态失败：\(error.localizedDescription)")
                return 1
            }

            var pending = 0
            for url in files {
                let canonical = canonicalFileURL(url)
                let key = canonical.path
                guard let currentSignature = try? signature(canonical) else { continue }
                if state.files[key]?.reason == "undo"
                    || state.files[key]?.signature == currentSignature
                    || failed.contains(key) {
                    continue
                }

                let previous = stable[key]
                let result = evaluate(
                    canonical,
                    intent: .automatic,
                    expectedSignature: previous?.0,
                    stableSince: previous?.1
                )
                switch result.status {
                case .automaticPending, .unstable:
                    pending += 1
                    if previous?.0 != result.signature, let signature = result.signature {
                        stable[key] = (signature, Date())
                    }
                case .unmatched:
                    stable[key] = nil
                    if !markUnmatched(result) { hadFailure = true }
                case .ready:
                    pending += 1
                    let processed = process(
                        canonical,
                        intent: .automatic,
                        expectedSignature: result.signature,
                        stableSince: previous?.1
                    )
                    stable[key] = nil
                    if [.failed, .permissionError, .invalidTarget, .destinationInWatchFolder, .metadataUnavailable]
                        .contains(processed.status) {
                        failed.insert(key)
                        hadFailure = true
                        pending -= 1
                    }
                default:
                    stable[key] = nil
                }
            }

            if pending == 0 {
                idleSince = idleSince ?? Date()
            } else {
                idleSince = nil
            }
            if let idleSince, Date().timeIntervalSince(idleSince) >= config.idleSeconds {
                return hadFailure ? 1 : 0
            }
            Thread.sleep(forTimeInterval: max(0.2, config.scanInterval))
        }
        logger.write("WARNING", "本次监听达到最长运行时间")
        return hadFailure ? 1 : 0
    }
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

@main
struct AIFileSorterAgentMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard let configIndex = arguments.firstIndex(of: "--config"), arguments.indices.contains(configIndex + 1) else {
            writeStandardError("缺少 --config 参数\n")
            exit(2)
        }

        do {
            let sorter = try NativeSorter(configURL: URL(fileURLWithPath: arguments[configIndex + 1]))
            if arguments.contains("--check-config") {
                print("原生配置检查通过：\(sorter.configURL.path)")
                exit(0)
            }
            if arguments.contains("--scan-json") {
                exit(sorter.scanJSON())
            }
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
            exit(arguments.contains("--once") ? runOnce(sorter) : sorter.runEvent())
        } catch {
            writeStandardError("启动失败：\(error.localizedDescription)\n")
            exit(1)
        }
    }
}

private func runOnce(_ sorter: NativeSorter) -> Int32 {
    let candidates = sorter.supportedFiles()
    let before = Dictionary(uniqueKeysWithValues: candidates.compactMap { url in
        try? (url.standardizedFileURL.path, sorter.signature(url))
    })
    let started = Date()
    Thread.sleep(forTimeInterval: max(0, sorter.config.stableSeconds))
    var moved = 0
    var unknown = 0
    var errors = 0
    var changing = 0
    for url in sorter.supportedFiles() {
        guard let expected = before[url.standardizedFileURL.path] else {
            changing += 1
            continue
        }
        let result = sorter.process(
            url,
            intent: .once,
            expectedSignature: expected,
            stableSince: started
        )
        switch result.status {
        case .ready where result.didMove: moved += 1
        case .unmatched: unknown += 1
        case .unstable, .automaticPending: changing += 1
        case .failed, .permissionError, .invalidTarget, .destinationInWatchFolder,
             .metadataUnavailable, .sameLocation: errors += 1
        default: break
        }
    }
    let summary = "手动整理完成：支持文件 \(candidates.count) 个，成功移动 \(moved) 个，未匹配 \(unknown) 个，仍在写入 \(changing) 个，失败 \(errors) 个"
    sorter.logger.write(errors == 0 ? "INFO" : "ERROR", summary)
    print(summary)
    return errors > 0 ? 1 : 0
}
