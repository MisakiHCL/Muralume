import Foundation

protocol MediaLibraryScanning: Sendable {
    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot
}

enum MediaLibraryScanError: Error, Equatable, Sendable {
    case rootUnavailable(URL)
    case rootIsNotDirectory(URL)
    case rootIsSymbolicLink(URL)
    case cannotEnumerateRoot(URL)
    case enumerationFailed(rootURL: URL, failedURL: URL)
    case resourceAccessFailed(URL)
}
