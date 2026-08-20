import Foundation

enum MediaAccessRejectionReason: Hashable, Sendable {
    /// A selected regular file does not use a supported video container.
    case unsupportedFileFormat
    /// The selected folder is broader than a folder already granted access.
    case selectedFolderContainsActiveFolder
    /// The selected folder is already covered by a broader active folder.
    case activeFolderContainsSelectedFolder
}

enum MediaAccessIncomingScopePolicy: Hashable, Sendable {
    /// The media access session consumes the incoming selector grant and
    /// releases it after the request has been processed.
    case sessionManaged
    /// The caller keeps ownership of the incoming grant and remains
    /// responsible for releasing it.
    case callerManaged
}

struct MediaAccessUpdate: Equatable, Sendable {
    let activeSources: [MediaSource]
    /// Explicit file requests remain visible even when an existing folder
    /// already covers them, so callers can honor the user's play intent.
    let requestedFileURLs: [URL]
    let acceptedRequestCount: Int
    let rejectedRequestCount: Int
    /// Counts only recognized, actionable failures. Their sum may be lower
    /// than rejectedRequestCount when generic failures are also present.
    let actionableRejectionCounts: [MediaAccessRejectionReason: Int]
    let didChangeSources: Bool

    init(
        activeSources: [MediaSource],
        requestedFileURLs: [URL],
        acceptedRequestCount: Int,
        rejectedRequestCount: Int,
        actionableRejectionCounts: [MediaAccessRejectionReason: Int] = [:],
        didChangeSources: Bool
    ) {
        self.activeSources = activeSources
        self.requestedFileURLs = requestedFileURLs
        self.acceptedRequestCount = acceptedRequestCount
        self.rejectedRequestCount = rejectedRequestCount
        self.actionableRejectionCounts = actionableRejectionCounts
        self.didChangeSources = didChangeSources
    }

    var exclusiveRejectionReason: MediaAccessRejectionReason? {
        guard acceptedRequestCount == 0,
              rejectedRequestCount > 0,
              actionableRejectionCounts.count == 1,
              let (reason, count) = actionableRejectionCounts.first,
              count == rejectedRequestCount else {
            return nil
        }
        return reason
    }
}

@MainActor
protocol MediaAccessSession: AnyObject {
    /// True when at least one persisted grant could not be restored in this
    /// process, for example because a removable volume is unavailable.
    var hasUnavailablePersistedFolders: Bool { get }
    var hasUnavailablePersistedSources: Bool { get }
    /// Persisted grants with enough metadata to present a specific recovery
    /// action. Anonymous legacy records remain retryable but are not shown as
    /// user-facing unavailable sources.
    var unavailablePersistedSources: [UnavailableMediaSource] { get }

    /// Legacy folder-only restore API.
    func restoreFolders() -> [URL]
    /// Restores persisted file and folder grants and keeps their scopes active.
    func restoreSources() -> [MediaSource]
    /// Asynchronous startup variant for implementations that resolve bookmarks
    /// or inspect unavailable volumes away from the main actor.
    func restoreSourcesAsync() async -> [MediaSource]
    /// Re-attempts only persisted grants that were unavailable during the
    /// initial restore. Existing active scopes remain open.
    func retryUnavailableSources() -> [MediaSource]
    func retryUnavailableSourcesAsync() async -> [MediaSource]

    /// Legacy folder-only add API.
    func addFolders(_ urls: [URL]) -> [URL]
    /// Persists selected file/folder grants and reports import/play intent.
    func addSources(_ urls: [URL]) -> MediaAccessUpdate
    /// Persists grants while making ownership of each incoming security scope
    /// explicit. Bookmark-resolved scopes opened by the session remain owned
    /// by the session regardless of this policy.
    func addSources(
        _ urls: [URL],
        incomingScopePolicy: MediaAccessIncomingScopePolicy
    ) -> MediaAccessUpdate

    /// Persists the user's removal decision while keeping the active security
    /// scope alive until in-flight readers have drained.
    func prepareToRemoveFolder(_ url: URL)
    func prepareToRemoveSource(_ source: MediaSource)

    /// Legacy folder-only removal API.
    func removeFolder(_ url: URL) -> [URL]
    /// Removes one persisted source grant without modifying files on disk.
    func removeSource(_ source: MediaSource) -> [MediaSource]
    /// Forgets one unavailable persisted grant without modifying media on
    /// disk or closing any active source scopes.
    func removeUnavailableSource(_ source: UnavailableMediaSource)

    func stop()
}

extension MediaAccessSession {
    var unavailablePersistedSources: [UnavailableMediaSource] {
        []
    }

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

    func retryUnavailableSources() -> [MediaSource] {
        restoreSources()
    }

    func restoreSourcesAsync() async -> [MediaSource] {
        restoreSources()
    }

    func retryUnavailableSourcesAsync() async -> [MediaSource] {
        retryUnavailableSources()
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

    func addSources(
        _ urls: [URL],
        incomingScopePolicy: MediaAccessIncomingScopePolicy
    ) -> MediaAccessUpdate {
        addSources(urls)
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

    func removeUnavailableSource(_ source: UnavailableMediaSource) {
        // Compatibility default for sessions that do not expose persisted
        // unavailable-source records.
    }
}
