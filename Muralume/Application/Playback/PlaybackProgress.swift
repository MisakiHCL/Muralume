import Foundation

enum PlaybackProgressPolicy {
    /// Leaving an item at or beyond this point treats it as completed, so a
    /// later play starts from the beginning.
    static let completionRatio = 0.95
    static let maximumEntryCount = 100_000
    static let maximumFileByteCount = 32 * 1_024 * 1_024

    static func resumablePosition(
        position: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0,
              position / duration < completionRatio else {
            return nil
        }
        return min(position, duration)
    }
}

struct PlaybackProgressSnapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let itemID: LibraryMediaItem.ID
        let position: TimeInterval

        var isValid: Bool {
            position.isFinite && position > 0
        }
    }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let entries: [Entry]

    init(entries: [Entry]) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              entries.count <= PlaybackProgressPolicy.maximumEntryCount,
              entries.allSatisfy(\.isValid) else {
            return false
        }
        return Set(entries.map(\.itemID)).count == entries.count
    }
}

enum PlaybackProgressStoreError: Error, Equatable, Sendable {
    case invalidSnapshot
    case fileTooLarge(maximumByteCount: Int, observedByteCount: Int)
    case entryLimitExceeded(maximumEntryCount: Int, observedEntryCount: Int)
}

protocol PlaybackProgressStoring: Sendable {
    func position(for itemID: LibraryMediaItem.ID) async throws
        -> TimeInterval?
    func update(
        position: TimeInterval,
        duration: TimeInterval,
        for itemID: LibraryMediaItem.ID
    ) async throws
    func removeProgress(
        for itemIDs: Set<LibraryMediaItem.ID>
    ) async throws
    func pruneProgress(
        keeping itemIDs: Set<LibraryMediaItem.ID>,
        withinRootPaths rootPaths: Set<String>
    ) async throws
}
