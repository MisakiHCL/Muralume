import Foundation

enum PlaybackStatePersistencePolicy {
    /// A valid 10,000-item queue with long paths remains comfortably below
    /// this bound, while a damaged recovery file cannot consume unbounded RAM.
    static let maximumFileByteCount = 32 * 1_024 * 1_024

    /// Keeps bounded reads responsive without relying on one FileHandle read
    /// returning every requested byte.
    static let readChunkByteCount = 64 * 1_024
}

enum PlaybackSessionPresentation: String, Codable, Equatable, Sendable {
    case player
    case desktop
}

struct PlaybackSessionSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: DesktopPreset
    let presentation: PlaybackSessionPresentation

    init(
        state: DesktopPreset,
        presentation: PlaybackSessionPresentation
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.state = state
        self.presentation = presentation
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion && state.isValid
    }
}

enum PlaybackSessionStoreError: Error, Equatable, Sendable {
    case invalidSnapshot
    case fileTooLarge(maximumByteCount: Int, observedByteCount: Int)
    case queueLimitExceeded(
        itemCount: Int,
        historyEntryCount: Int
    )
}

protocol PlaybackSessionStoring: Sendable {
    func load() async throws -> PlaybackSessionSnapshot?
    func save(_ snapshot: PlaybackSessionSnapshot) async throws
    func clear() async throws
}
