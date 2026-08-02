import Foundation

@MainActor
protocol MediaAccessSession: AnyObject {
    /// True when at least one persisted grant could not be restored in this
    /// process, for example because a removable volume is unavailable.
    var hasUnavailablePersistedFolders: Bool { get }

    /// Restores persisted folder grants and keeps their security scopes active.
    func restoreFolders() -> [URL]

    /// Persists newly selected folders and returns every currently active root.
    func addFolders(_ urls: [URL]) -> [URL]

    /// Persists the user's removal decision while keeping the active security
    /// scope alive until in-flight readers have drained.
    func prepareToRemoveFolder(_ url: URL)

    /// Removes one persisted folder grant without modifying files on disk.
    func removeFolder(_ url: URL) -> [URL]

    func stop()
}

extension MediaAccessSession {
    var hasUnavailablePersistedFolders: Bool {
        false
    }

    func prepareToRemoveFolder(_ url: URL) {}
}
