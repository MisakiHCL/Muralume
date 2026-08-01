import Foundation

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

enum PlaybackSessionStoreError: Error {
    case invalidSnapshot
}

protocol PlaybackSessionStoring: Sendable {
    func load() async throws -> PlaybackSessionSnapshot?
    func save(_ snapshot: PlaybackSessionSnapshot) async throws
    func clear() async throws
}
