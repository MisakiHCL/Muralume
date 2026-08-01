import Foundation

actor FilePlaybackSessionStore: PlaybackSessionStoring {
    private enum Storage {
        static let directoryName = "Muralume"
        static let fileName = "playback-session.json"
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(
            fileManager: fileManager
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func load() throws -> PlaybackSessionSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(
            PlaybackSessionSnapshot.self,
            from: data
        )
        guard snapshot.isValid else {
            throw PlaybackSessionStoreError.invalidSnapshot
        }
        return snapshot
    }

    func save(_ snapshot: PlaybackSessionSnapshot) throws {
        guard snapshot.isValid else {
            throw PlaybackSessionStoreError.invalidSnapshot
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private static func defaultFileURL(
        fileManager: FileManager
    ) -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support is required for playback recovery."
            )
        }
        return applicationSupportURL
            .appendingPathComponent(Storage.directoryName, isDirectory: true)
            .appendingPathComponent(Storage.fileName, isDirectory: false)
    }
}
