import Foundation

actor FileCustomPlaylistStore: CustomPlaylistStoring {
    private enum Storage {
        static let directoryName = "Muralume"
        static let fileName = "custom-playlists.json"
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumFileByteCount: Int

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumFileByteCount: Int =
            CustomPlaylistPolicy.maximumFileByteCount
    ) {
        precondition(maximumFileByteCount > 0 && maximumFileByteCount < Int.max)
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.maximumFileByteCount = maximumFileByteCount
    }

    func load() throws -> CustomPlaylistCollection {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try readBoundedData()
        let collection = try decoder.decode(
            CustomPlaylistCollection.self,
            from: data
        )
        guard collection.isValid else {
            throw CustomPlaylistStoreError.invalidCollection
        }
        return collection
    }

    func save(_ collection: CustomPlaylistCollection) throws {
        guard collection.isValid else {
            throw CustomPlaylistStoreError.invalidCollection
        }
        let data = try encoder.encode(collection)
        guard data.count <= maximumFileByteCount else {
            throw CustomPlaylistStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: data.count
            )
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    private func readBoundedData() throws -> Data {
        if let attributes = try? fileManager.attributesOfItem(
            atPath: fileURL.path
        ), let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > maximumFileByteCount {
            throw CustomPlaylistStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: fileSize.intValue
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        let readLimit = maximumFileByteCount + 1
        var data = Data()
        while data.count < readLimit {
            let chunk = try handle.read(
                upToCount: min(
                    PlaybackStatePersistencePolicy.readChunkByteCount,
                    readLimit - data.count
                )
            ) ?? Data()
            guard !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumFileByteCount else {
            throw CustomPlaylistStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: data.count
            )
        }
        return data
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support is required for custom playlists."
            )
        }
        return applicationSupportURL
            .appendingPathComponent(Storage.directoryName, isDirectory: true)
            .appendingPathComponent(Storage.fileName, isDirectory: false)
    }
}
