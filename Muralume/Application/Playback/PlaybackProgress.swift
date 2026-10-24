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
    /// Journal records through this sequence are already reflected in entries.
    /// Older JSON snapshots omit the field and therefore start at zero.
    let checkpointSequence: UInt64

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entries
        case checkpointSequence
    }

    init(entries: [Entry], checkpointSequence: UInt64 = 0) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
        self.checkpointSequence = checkpointSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        entries = try container.decode([Entry].self, forKey: .entries)
        checkpointSequence = try container.decodeIfPresent(
            UInt64.self, forKey: .checkpointSequence
        ) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(entries, forKey: .entries)
        if checkpointSequence > 0 {
            try container.encode(checkpointSequence, forKey: .checkpointSequence)
        }
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
