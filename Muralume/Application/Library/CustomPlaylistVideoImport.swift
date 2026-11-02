import Foundation

enum CustomPlaylistVideoImportError: Error, Equatable, Sendable {
    case selectionLimitReached
    case unavailable
}

struct CustomPlaylistVideoImport: Sendable {
    let items: [LibraryMediaItem]
    let grantsByItemID: [LibraryMediaItem.ID: CustomPlaylistMediaGrant]
}

@MainActor
protocol CustomPlaylistVideoImporting {
    /// Consumes every picker-provided incoming scope, including rejected inputs.
    func prepare(_ selectedURLs: [URL]) async throws -> CustomPlaylistVideoImport
}

enum CustomPlaylistVideoImportFailure: Equatable {
    case selectionLimitReached
    case playlistUnavailable
    case playlistFull
    case unavailable
}
