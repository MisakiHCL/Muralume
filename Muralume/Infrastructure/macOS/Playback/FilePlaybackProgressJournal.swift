import Foundation

struct PlaybackProgressJournalPolicy: Sendable {
    static let production = PlaybackProgressJournalPolicy(
        checkpointByteCount: 64 * 1_024,
        maximumByteCount: 1 * 1_024 * 1_024,
        checkpointRecordCount: 64,
        maximumRecordCount: 512
    )

    let checkpointByteCount: Int
    let maximumByteCount: Int
    let checkpointRecordCount: Int
    let maximumRecordCount: Int
}

/// Narrow persistence seams also let tests count physical work and suspend a
/// checkpoint without relying on storage timing or real disk failures.
struct PlaybackProgressJournalIO: Sendable {
    let append: @Sendable (URL, Data, Int) throws -> Void
    let replace: @Sendable (URL, Data) throws -> Void

    static let live = PlaybackProgressJournalIO(
        append: { url, data, validByteCount in
            let manager = FileManager.default
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            do {
                // A previous failed append or torn tail must never become a
                // valid record when the next newline is written.
                try handle.truncate(atOffset: UInt64(validByteCount))
                try handle.seek(toOffset: UInt64(validByteCount))
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                try? handle.truncate(atOffset: UInt64(validByteCount))
                try? handle.synchronize()
                throw error
            }
        },
        replace: { url, data in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    )
}

enum FilePlaybackProgressJournal {
    struct Change: Codable, Sendable {
        let itemID: LibraryMediaItem.ID
        let position: TimeInterval?

        var isValid: Bool {
            position.map { $0.isFinite && $0 > 0 } ?? true
        }
    }

    struct Record: Codable, Sendable {
        let sequence: UInt64
        let changes: [Change]

        var isValid: Bool {
            sequence > 0 && !changes.isEmpty
                && changes.count <= PlaybackProgressPolicy.maximumEntryCount
                && changes.allSatisfy(\.isValid)
                && Set(changes.map(\.itemID)).count == changes.count
        }
    }

    struct Frame: Sendable {
        let sequence: UInt64
        let data: Data
    }

    final class CheckpointCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<Void, Error>?

        var result: Result<Void, Error>? { lock.withLock { storedResult } }
        func finish(_ result: Result<Void, Error>) {
            lock.withLock { storedResult = result }
        }
    }

    static func url(for snapshotURL: URL) -> URL {
        snapshotURL.appendingPathExtension("journal")
    }

    static func readBoundedData(at url: URL, maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let readLimit = maximumByteCount + 1
        while data.count < readLimit {
            let chunk = try handle.read(upToCount: min(
                PlaybackStatePersistencePolicy.readChunkByteCount,
                readLimit - data.count
            )) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    static func encodeFrame(_ record: Record, encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    static func checkpointData(
        positions: [LibraryMediaItem.ID: TimeInterval],
        sequence: UInt64,
        maximumByteCount: Int
    ) throws -> Data {
        let entries = positions.map {
            PlaybackProgressSnapshot.Entry(itemID: $0.key, position: $0.value)
        }.sorted {
            $0.itemID.standardizedMediaPath < $1.itemID.standardizedMediaPath
        }
        let snapshot = PlaybackProgressSnapshot(
            entries: entries, checkpointSequence: sequence
        )
        guard snapshot.isValid else { throw PlaybackProgressStoreError.invalidSnapshot }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumByteCount else {
            throw PlaybackProgressStoreError.fileTooLarge(
                maximumByteCount: maximumByteCount, observedByteCount: data.count
            )
        }
        return data
    }
}
