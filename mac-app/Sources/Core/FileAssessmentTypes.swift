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
    let status: FileProcessingStatus
    let reason: String
    let remainingSeconds: Double
    let ruleName: String
    let targetFolder: String
    let destinationPath: String
    let canSelect: Bool
    let canMoveNow: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case fileName = "file_name"
        case `extension`
        case fileSize = "file_size"
        case modifiedAt = "modified_at"
        case status, reason
        case remainingSeconds = "remaining_seconds"
        case ruleName = "rule_name"
        case targetFolder = "target_folder"
        case destinationPath = "destination_path"
        case canSelect = "can_select"
        case canMoveNow = "can_move_now"
    }

    init(
        path: String,
        fileName: String,
        fileExtension: String,
        fileSize: UInt64,
        modifiedAt: String,
        status: FileProcessingStatus,
        reason: String,
        remainingSeconds: Double,
        ruleName: String,
        targetFolder: String,
        destinationPath: String,
        canSelect: Bool,
        canMoveNow: Bool
    ) {
        self.path = path
        self.fileName = fileName
        self.extension = fileExtension
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.status = status
        self.reason = reason
        self.remainingSeconds = max(0, remainingSeconds)
        self.ruleName = ruleName
        self.targetFolder = targetFolder
        self.destinationPath = destinationPath
        self.canSelect = canSelect
        self.canMoveNow = canMoveNow
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

    init(schemaVersion: Int = 1, generatedAt: String, watchFolder: String, items: [FileAssessmentItem]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.watchFolder = watchFolder
        self.items = items
    }
}
