import Foundation

protocol MediaLibraryScanning: Sendable {
    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot
    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot
    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability
}

enum MediaLibraryItemAvailability: Equatable, Sendable {
    case available
    case missing
    case temporarilyUnavailable
}

extension MediaLibraryScanning {
    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot {
        try await scan(rootURLs: sources.map(\.url))
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        .temporarilyUnavailable
    }
}

enum MediaLibraryScanError: Error, Equatable, Sendable {
    case rootUnavailable(URL)
    case rootIsNotDirectory(URL)
    case sourceKindMismatch(URL, expected: MediaSourceKind)
    case unsupportedMediaFile(URL)
    case rootIsSymbolicLink(URL)
    case cannotEnumerateRoot(URL)
    case enumerationFailed(rootURL: URL, failedURL: URL)
    case resourceAccessFailed(URL)
}
