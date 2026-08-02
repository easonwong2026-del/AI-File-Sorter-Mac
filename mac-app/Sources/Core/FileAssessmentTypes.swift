import Foundation

// Build integration: add this file to both the App source list and the Agent
// swiftc source list in build-app.sh.

/// Stable values shared by the native Agent and the App's scan consumer.
enum FileProcessingStatus: String, Codable, Equatable, CaseIterable {
    case ready
    case moved
    case awaitingConfirmation = "awaiting_confirmation"
    case automaticPending = "automatic_pending"
    case waitingRetention = "waiting_retention"
    case recentlyModified = "recently_modified"
    case unstable
    case excluded
    case temporary
    case hidden
    case locked
    case unsupported
    case unmatched
    case invalidTarget = "invalid_target"
    case destinationInWatchFolder = "destination_in_watch_folder"
    case permissionError = "permission_error"
    case metadataUnavailable = "metadata_unavailable"
    case missing
    case notRegularFile = "not_regular_file"
    case sameLocation = "same_location"
    case failed
    case sourceOutsideWatchFolder = "source_outside_watch_folder"
    case symlink
}

/// One first-level watch-folder assessment. Optional-looking values are empty
/// strings so every required JSON key is present for simple App decoding.
struct FileAssessmentItem: Codable {
    let path: String
    let fileName: String
    let `extension`: String
    let fileSize: UInt64
    let modifiedAt: String
    let modifiedNs: Int64?
    let status: FileProcessingStatus
    let reason: String
    let remainingSeconds: Double
    let ruleName: String
    let targetFolder: String
    let destinationPath: String
    let canManualMove: Bool
    let canIncludeInPlan: Bool
    let canAutoMoveNow: Bool

    /// Compatibility alias for source callers; it is not emitted in schema v2.
    var canSelect: Bool { canManualMove }

    enum CodingKeys: String, CodingKey {
        case path
        case fileName = "file_name"
        case `extension`
        case fileSize = "file_size"
        case modifiedAt = "modified_at"
        case modifiedNs = "modified_ns"
        case status, reason
        case remainingSeconds = "remaining_seconds"
        case ruleName = "rule_name"
        case targetFolder = "target_folder"
        case destinationPath = "destination_path"
        case canManualMove = "can_manual_move"
        case canIncludeInPlan = "can_include_in_plan"
        case canAutoMoveNow = "can_auto_move_now"
        case legacyCanSelect = "can_select"
    }

    init(
        path: String,
        fileName: String,
        fileExtension: String,
        fileSize: UInt64,
        modifiedAt: String,
        modifiedNs: Int64?,
        status: FileProcessingStatus,
        reason: String,
        remainingSeconds: Double,
        ruleName: String,
        targetFolder: String,
        destinationPath: String,
        canManualMove: Bool,
        canIncludeInPlan: Bool,
        canAutoMoveNow: Bool
    ) {
        self.path = path
        self.fileName = fileName
        self.extension = fileExtension
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.modifiedNs = modifiedNs
        self.status = status
        self.reason = reason
        self.remainingSeconds = max(0, remainingSeconds)
        self.ruleName = ruleName
        self.targetFolder = targetFolder
        self.destinationPath = destinationPath
        self.canManualMove = canManualMove
        self.canIncludeInPlan = canIncludeInPlan
        self.canAutoMoveNow = canAutoMoveNow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileSize = try container.decode(UInt64.self, forKey: .fileSize)
        modifiedNs = try container.decodeIfPresent(Int64.self, forKey: .modifiedNs)
        path = try container.decode(String.self, forKey: .path)
        fileName = try container.decode(String.self, forKey: .fileName)
        `extension` = try container.decode(String.self, forKey: .extension)
        modifiedAt = try container.decode(String.self, forKey: .modifiedAt)
        status = try container.decode(FileProcessingStatus.self, forKey: .status)
        reason = try container.decode(String.self, forKey: .reason)
        remainingSeconds = max(0, try container.decode(Double.self, forKey: .remainingSeconds))
        ruleName = try container.decode(String.self, forKey: .ruleName)
        targetFolder = try container.decode(String.self, forKey: .targetFolder)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        let legacy = try container.decodeIfPresent(Bool.self, forKey: .legacyCanSelect) ?? false
        canManualMove = try container.decodeIfPresent(Bool.self, forKey: .canManualMove) ?? legacy
        canIncludeInPlan = try container.decodeIfPresent(Bool.self, forKey: .canIncludeInPlan) ?? false
        canAutoMoveNow = try container.decodeIfPresent(Bool.self, forKey: .canAutoMoveNow) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(`extension`, forKey: .extension)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(modifiedNs, forKey: .modifiedNs)
        try container.encode(status, forKey: .status)
        try container.encode(reason, forKey: .reason)
        try container.encode(remainingSeconds, forKey: .remainingSeconds)
        try container.encode(ruleName, forKey: .ruleName)
        try container.encode(targetFolder, forKey: .targetFolder)
        try container.encode(destinationPath, forKey: .destinationPath)
        try container.encode(canManualMove, forKey: .canManualMove)
        try container.encode(canIncludeInPlan, forKey: .canIncludeInPlan)
        try container.encode(canAutoMoveNow, forKey: .canAutoMoveNow)
    }
}

struct FileAssessmentDocument: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let watchFolder: String
    let items: [FileAssessmentItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case watchFolder = "watch_folder"
        case items
    }

    init(schemaVersion: Int = 2, generatedAt: String, watchFolder: String, items: [FileAssessmentItem]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.watchFolder = watchFolder
        self.items = items
    }
}
