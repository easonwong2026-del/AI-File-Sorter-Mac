import Foundation
import Darwin

/// Shared timestamp primitives for the App and the native Agent.
///
/// File signatures come from `stat(2)`'s integer nanoseconds. Display dates
/// are deliberately separate and may be unavailable without affecting the
/// signature or ignore key.
enum AssessmentTimestamp {
    static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static func modifiedNanoseconds(at url: URL) -> Int64? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
        guard (0..<nanosecondsPerSecond).contains(nanoseconds) else { return nil }
        let multiplied = seconds.multipliedReportingOverflow(by: nanosecondsPerSecond)
        let added = multiplied.partialValue.addingReportingOverflow(nanoseconds)
        guard !multiplied.overflow, !added.overflow else { return nil }
        return added.partialValue
    }

    /// Parse only for display. A parse failure is intentionally represented by
    /// nil; callers must display “未知” and must never derive a file signature.
    static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = trimmed.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
