import Foundation

struct MediaAccessUpdate: Equatable, Sendable {
    let activeSources: [MediaSource]
    /// Explicit file requests remain visible even when an existing folder
    /// already covers them, so callers can honor the user's play intent.
    let requestedFileURLs: [URL]
    let acceptedRequestCount: Int
    let rejectedRequestCount: Int
    let didChangeSources: Bool
}

@MainActor
protocol MediaAccessSession: AnyObject {
    /// True when at least one persisted grant could not be restored in this
    /// process, for example because a removable volume is unavailable.
    var hasUnavailablePersistedFolders: Bool { get }
    var hasUnavailablePersistedSources: Bool { get }

    /// Legacy folder-only restore API.
    func restoreFolders() -> [URL]
    /// Restores persisted file and folder grants and keeps their scopes active.
    func restoreSources() -> [MediaSource]

    /// Legacy folder-only add API.
    func addFolders(_ urls: [URL]) -> [URL]
    /// Persists selected file/folder grants and reports import/play intent.
    func addSources(_ urls: [URL]) -> MediaAccessUpdate

    /// Persists the user's removal decision while keeping the active security
    /// scope alive until in-flight readers have drained.
    func prepareToRemoveFolder(_ url: URL)
    func prepareToRemoveSource(_ source: MediaSource)

    /// Legacy folder-only removal API.
    func removeFolder(_ url: URL) -> [URL]
    /// Removes one persisted source grant without modifying files on disk.
    func removeSource(_ source: MediaSource) -> [MediaSource]

    func stop()
}

extension MediaAccessSession {
    var hasUnavailablePersistedSources: Bool {
        hasUnavailablePersistedFolders
    }

    var hasUnavailablePersistedFolders: Bool {
        false
    }

    func restoreSources() -> [MediaSource] {
        restoreFolders().map {
            MediaSource(url: $0, kind: .folder)
        }
    }

    func restoreFolders() -> [URL] {
        []
    }

    func addSources(_ urls: [URL]) -> MediaAccessUpdate {
        let previousURLs = restoreFolders()
        let activeURLs = addFolders(urls)
        return MediaAccessUpdate(
            activeSources: activeURLs.map {
                MediaSource(url: $0, kind: .folder)
            },
            requestedFileURLs: [],
            acceptedRequestCount: urls.count,
            rejectedRequestCount: 0,
            didChangeSources: activeURLs != previousURLs
        )
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        restoreFolders()
    }

    func prepareToRemoveSource(_ source: MediaSource) {
        prepareToRemoveFolder(source.url)
    }

    func prepareToRemoveFolder(_ url: URL) {
        // Compatibility default for folder-only sessions that never needed a
        // two-phase removal hook.
    }

    func removeSource(_ source: MediaSource) -> [MediaSource] {
        removeFolder(source.url).map {
            MediaSource(url: $0, kind: .folder)
        }
    }

    func removeFolder(_ url: URL) -> [URL] {
        restoreFolders()
    }
}
