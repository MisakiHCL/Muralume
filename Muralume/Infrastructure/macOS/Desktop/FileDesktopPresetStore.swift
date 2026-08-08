import Foundation

actor FileDesktopPresetStore: DesktopPresetStoring {
    private enum Storage {
        static let directoryName = "Muralume"
        static let fileName = "desktop-preset.json"
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
            PlaybackStatePersistencePolicy.maximumFileByteCount
    ) {
        precondition(maximumFileByteCount > 0 && maximumFileByteCount < Int.max)
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(
            fileManager: fileManager
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.maximumFileByteCount = maximumFileByteCount
    }

    func load() throws -> DesktopPreset? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try readBoundedData()
        let preset: DesktopPreset
        do {
            preset = try decoder.decode(DesktopPreset.self, from: data)
        } catch let error as PlaybackQueueSnapshotCodingError {
            throw storeError(for: error)
        }
        try validateQueueLimits(preset.queue)
        guard preset.isValid else {
            throw DesktopPresetStoreError.invalidPreset
        }
        return preset
    }

    func save(_ preset: DesktopPreset) throws {
        try validateQueueLimits(preset.queue)
        guard preset.isValid else {
            throw DesktopPresetStoreError.invalidPreset
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(preset)
        guard data.count <= maximumFileByteCount else {
            throw DesktopPresetStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: data.count
            )
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func readBoundedData() throws -> Data {
        if let attributes = try? fileManager.attributesOfItem(
            atPath: fileURL.path
        ), let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > maximumFileByteCount {
            throw DesktopPresetStoreError.fileTooLarge(
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
            throw DesktopPresetStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount,
                observedByteCount: data.count
            )
        }
        return data
    }

    private func validateQueueLimits(
        _ queue: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    ) throws {
        guard queue.isWithinPersistenceLimits else {
            throw DesktopPresetStoreError.queueLimitExceeded(
                itemCount: queue.persistenceItemCount,
                historyEntryCount: queue.persistenceHistoryEntryCount
            )
        }
    }

    private func storeError(
        for error: PlaybackQueueSnapshotCodingError
    ) -> DesktopPresetStoreError {
        switch error {
        case let .limitExceeded(itemCount, historyEntryCount):
            return .queueLimitExceeded(
                itemCount: itemCount,
                historyEntryCount: historyEntryCount
            )
        }
    }

    private static func defaultFileURL(
        fileManager: FileManager
    ) -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support is required for desktop recovery."
            )
        }
        return applicationSupportURL
            .appendingPathComponent(Storage.directoryName, isDirectory: true)
            .appendingPathComponent(Storage.fileName, isDirectory: false)
    }
}
