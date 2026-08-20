import Foundation

actor FilePlaybackProgressStore: PlaybackProgressStoring {
    private enum Storage {
        static let directoryName = "Muralume"
        static let fileName = "playback-progress.json"
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumFileByteCount: Int
    private var cachedPositions: [LibraryMediaItem.ID: TimeInterval]?

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumFileByteCount: Int =
            PlaybackProgressPolicy.maximumFileByteCount
    ) {
        precondition(maximumFileByteCount > 0 && maximumFileByteCount < Int.max)
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.maximumFileByteCount = maximumFileByteCount
    }

    func position(for itemID: LibraryMediaItem.ID) throws -> TimeInterval? {
        try positions()[itemID]
    }

    func update(
        position: TimeInterval,
        duration: TimeInterval,
        for itemID: LibraryMediaItem.ID
    ) throws {
        var updatedPositions = try positions()
        let resumablePosition = PlaybackProgressPolicy.resumablePosition(
            position: position,
            duration: duration
        )
        guard updatedPositions[itemID] != resumablePosition else {
            return
        }
        updatedPositions[itemID] = resumablePosition
        try save(updatedPositions)
    }

    func removeProgress(
        for itemIDs: Set<LibraryMediaItem.ID>
    ) throws {
        guard !itemIDs.isEmpty else {
            return
        }
        var updatedPositions = try positions()
        let previousCount = updatedPositions.count
        updatedPositions = updatedPositions.filter {
            !itemIDs.contains($0.key)
        }
        guard updatedPositions.count != previousCount else {
            return
        }
        try save(updatedPositions)
    }

    func pruneProgress(
        keeping itemIDs: Set<LibraryMediaItem.ID>,
        withinRootPaths rootPaths: Set<String>
    ) throws {
        guard !rootPaths.isEmpty else {
            return
        }
        var updatedPositions = try positions()
        let previousCount = updatedPositions.count
        updatedPositions = updatedPositions.filter { itemID, _ in
            !rootPaths.contains(itemID.rootPath) || itemIDs.contains(itemID)
        }
        guard updatedPositions.count != previousCount else {
            return
        }
        try save(updatedPositions)
    }

    private func positions() throws
        -> [LibraryMediaItem.ID: TimeInterval] {
        if let cachedPositions {
            return cachedPositions
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let positions: [LibraryMediaItem.ID: TimeInterval] = [:]
            cachedPositions = positions
            return positions
        }

        let snapshot: PlaybackProgressSnapshot
        do {
            let data = try readBoundedData()
            snapshot = try decoder.decode(
                PlaybackProgressSnapshot.self,
                from: data
            )
            guard snapshot.isValid else {
                throw PlaybackProgressStoreError.invalidSnapshot
            }
        } catch is DecodingError {
            return try discardInvalidCache()
        } catch let error as PlaybackProgressStoreError {
            switch error {
            case .invalidSnapshot, .fileTooLarge:
                return try discardInvalidCache()
            case .entryLimitExceeded:
                throw error
            }
        }
        let positions = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map {
                ($0.itemID, $0.position)
            }
        )
        cachedPositions = positions
        return positions
    }

    private func discardInvalidCache() throws
        -> [LibraryMediaItem.ID: TimeInterval] {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        let positions: [LibraryMediaItem.ID: TimeInterval] = [:]
        cachedPositions = positions
        return positions
    }

    private func save(
        _ positions: [LibraryMediaItem.ID: TimeInterval]
    ) throws {
        guard positions.count <= PlaybackProgressPolicy.maximumEntryCount else {
            throw PlaybackProgressStoreError.entryLimitExceeded(
                maximumEntryCount: PlaybackProgressPolicy.maximumEntryCount,
                observedEntryCount: positions.count
            )
        }
        if positions.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            cachedPositions = [:]
            return
        }

        let entries = positions.map {
            PlaybackProgressSnapshot.Entry(
                itemID: $0.key,
                position: $0.value
            )
        }.sorted {
            $0.itemID.standardizedMediaPath
                < $1.itemID.standardizedMediaPath
        }
        let snapshot = PlaybackProgressSnapshot(entries: entries)
        guard snapshot.isValid else {
            throw PlaybackProgressStoreError.invalidSnapshot
        }
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumFileByteCount else {
            throw PlaybackProgressStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: data.count
            )
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        cachedPositions = positions
    }

    private func readBoundedData() throws -> Data {
        if let attributes = try? fileManager.attributesOfItem(
            atPath: fileURL.path
        ), let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > maximumFileByteCount {
            throw PlaybackProgressStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: fileSize.intValue
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        var data = Data()
        let readLimit = maximumFileByteCount + 1
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
            throw PlaybackProgressStoreError.fileTooLarge(
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
                "Application Support is required for playback progress."
            )
        }
        return applicationSupportURL
            .appendingPathComponent(Storage.directoryName, isDirectory: true)
            .appendingPathComponent(Storage.fileName, isDirectory: false)
    }
}
