import Foundation

@MainActor
protocol MediaAccessSession: AnyObject {
    /// Restores persisted folder grants and keeps their security scopes active.
    func restoreFolders() -> [URL]

    /// Persists newly selected folders and returns every currently active root.
    func addFolders(_ urls: [URL]) -> [URL]

    /// Removes one persisted folder grant without modifying files on disk.
    func removeFolder(_ url: URL) -> [URL]

    func stop()
}
