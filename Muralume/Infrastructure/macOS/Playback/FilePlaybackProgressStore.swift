import Foundation

actor FilePlaybackProgressStore: PlaybackProgressStoring {
    private enum Storage {
        static let directoryName = "Muralume"
        static let fileName = "playback-progress.json"
    }

    private struct CheckpointFlight {
        let id: UUID
        let sequence: UInt64
        let task: Task<Void, Never>
        let completion: FilePlaybackProgressJournal.CheckpointCompletion
    }

    private let fileURL: URL
    private let journalURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumFileByteCount: Int
    private let journalPolicy: PlaybackProgressJournalPolicy
    private let io: PlaybackProgressJournalIO
    private var didLoad = false
    private var cachedPositions: [LibraryMediaItem.ID: TimeInterval] = [:]
    private var encodedEntryBytes = 0
    private var sequence: UInt64 = 0
    private var journalFrames: [FilePlaybackProgressJournal.Frame] = []
    private var journalByteCount = 0
    private var journalNeedsRewrite = false
    private var requiresDiskReconciliation = false
    private var checkpoint: CheckpointFlight?

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumFileByteCount: Int = PlaybackProgressPolicy.maximumFileByteCount,
        journalPolicy: PlaybackProgressJournalPolicy = .production,
        io: PlaybackProgressJournalIO = .live
    ) {
        precondition(maximumFileByteCount > 0 && maximumFileByteCount < Int.max)
        precondition(journalPolicy.checkpointByteCount > 0)
        precondition(journalPolicy.maximumByteCount >= journalPolicy.checkpointByteCount)
        precondition(journalPolicy.checkpointRecordCount > 0)
        precondition(journalPolicy.maximumRecordCount >= journalPolicy.checkpointRecordCount)
        self.fileManager = fileManager
        let resolvedURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.fileURL = resolvedURL
        journalURL = FilePlaybackProgressJournal.url(for: resolvedURL)
        self.maximumFileByteCount = maximumFileByteCount
        self.journalPolicy = journalPolicy
        self.io = io
    }

    func position(for itemID: LibraryMediaItem.ID) throws -> TimeInterval? {
        try loadIfNeeded()
        return cachedPositions[itemID]
    }

    func update(
        position: TimeInterval,
        duration: TimeInterval,
        for itemID: LibraryMediaItem.ID
    ) async throws {
        try loadForMutation()
        let resumablePosition = PlaybackProgressPolicy.resumablePosition(
            position: position, duration: duration
        )
        while true {
            try loadForMutation()
            finishReadyCheckpoint()
            guard cachedPositions[itemID] != resumablePosition else { return }
            if try await commit([
                .init(itemID: itemID, position: resumablePosition)
            ]) { return }
        }
    }

    func removeProgress(for itemIDs: Set<LibraryMediaItem.ID>) async throws {
        guard !itemIDs.isEmpty else { return }
        try loadForMutation()
        while true {
            try loadForMutation()
            finishReadyCheckpoint()
            let changes = itemIDs.compactMap { id in
                cachedPositions[id] == nil ? nil : FilePlaybackProgressJournal.Change(
                    itemID: id, position: nil
                )
            }
            guard !changes.isEmpty else { return }
            if try await commit(changes) { return }
        }
    }

    func pruneProgress(
        keeping itemIDs: Set<LibraryMediaItem.ID>,
        withinRootPaths rootPaths: Set<String>
    ) async throws {
        guard !rootPaths.isEmpty else { return }
        try loadForMutation()
        while true {
            try loadForMutation()
            finishReadyCheckpoint()
            let changes = cachedPositions.keys.compactMap { id in
                rootPaths.contains(id.rootPath) && !itemIDs.contains(id)
                    ? FilePlaybackProgressJournal.Change(itemID: id, position: nil) : nil
            }
            guard !changes.isEmpty else { return }
            if try await commit(changes) { return }
        }
    }

    /// Ordinary updates have already synchronized their individual journal
    /// frame; this explicit checkpoint never substitutes deferred durability.
    func compact() async throws {
        try loadForMutation()
        finishReadyCheckpoint()
        if checkpoint == nil { startCheckpoint() }
        guard let flight = checkpoint else { return }
        await flight.task.value
        let result = flight.completion.result!
        try finishCheckpoint(flight, result: result)
    }

    /// False means capacity required an await. Recompute against the current
    /// cache after actor reentrancy instead of committing a stale mutation.
    private func commit(_ changes: [FilePlaybackProgressJournal.Change]) async throws -> Bool {
        guard sequence < UInt64.max else { throw PlaybackProgressStoreError.invalidSnapshot }
        let nextSequence = sequence + 1
        let projected = try projectedMutation(changes, sequence: nextSequence)
        let record = FilePlaybackProgressJournal.Record(
            sequence: nextSequence, changes: changes
        )
        let frame = try FilePlaybackProgressJournal.encodeFrame(record, encoder: encoder)
        if frame.count > maximumJournalByteCount {
            if checkpoint != nil {
                try await compact()
                return false
            }
            // A large root deletion may exceed the journal cap. Preserve its
            // atomicity using a complete checkpoint rather than partial batches.
            var updatedPositions = cachedPositions
            for change in changes { updatedPositions[change.itemID] = change.position }
            let data = try FilePlaybackProgressJournal.checkpointData(
                positions: updatedPositions, sequence: nextSequence,
                maximumByteCount: maximumFileByteCount
            )
            do {
                try io.replace(fileURL, data)
            } catch {
                // Rename can commit the next watermark before a later sync
                // fails. Keep the caller's cache unchanged, but never reuse
                // the old sequence for a subsequent acknowledged journal write.
                requiresDiskReconciliation = true
                throw error
            }
            cachedPositions = updatedPositions
            encodedEntryBytes = projected.entryBytes
            sequence = nextSequence
            // A failed cleanup is safe: the new watermark makes old records
            // inert, so completed deletions cannot be resurrected on restart.
            do {
                try io.replace(journalURL, Data())
                journalFrames = []
                journalByteCount = 0
                journalNeedsRewrite = false
            } catch {
                // Atomic rename may have succeeded before synchronize failed.
                // Restore known frames before trusting the old append offset.
                journalNeedsRewrite = true
            }
            return true
        }
        if journalByteCount > maximumJournalByteCount - frame.count
            || journalFrames.count >= journalPolicy.maximumRecordCount {
            try await compact()
            return false
        }

        if journalNeedsRewrite {
            try io.replace(journalURL, encodedJournalFrames(journalFrames))
            journalNeedsRewrite = false
        }
        do {
            try io.append(journalURL, frame, journalByteCount)
        } catch {
            journalNeedsRewrite = true
            throw error
        }
        // Do not copy the complete dictionary or change the cache before the
        // small append has completed successfully and synchronized to disk.
        for change in changes { cachedPositions[change.itemID] = change.position }
        encodedEntryBytes = projected.entryBytes
        sequence = nextSequence
        journalFrames.append(.init(sequence: nextSequence, data: frame))
        journalByteCount += frame.count
        if checkpoint == nil && (
            journalByteCount >= min(journalPolicy.checkpointByteCount, maximumJournalByteCount)
                || journalFrames.count >= journalPolicy.checkpointRecordCount
        ) {
            startCheckpoint()
        }
        return true
    }

    private var maximumJournalByteCount: Int {
        min(maximumFileByteCount, journalPolicy.maximumByteCount)
    }

    private func projectedMutation(
        _ changes: [FilePlaybackProgressJournal.Change], sequence: UInt64
    ) throws -> (entryBytes: Int, count: Int) {
        var count = cachedPositions.count
        var bytes = encodedEntryBytes
        for change in changes {
            let storedID = cachedPositions.index(forKey: change.itemID).map {
                cachedPositions.keys[$0]
            } ?? change.itemID
            if let oldPosition = cachedPositions[change.itemID] {
                bytes -= try entryByteCount(itemID: storedID, position: oldPosition)
                count -= 1
            }
            if let position = change.position {
                bytes += try entryByteCount(itemID: storedID, position: position)
                count += 1
            }
        }
        guard count <= PlaybackProgressPolicy.maximumEntryCount else {
            throw PlaybackProgressStoreError.entryLimitExceeded(
                maximumEntryCount: PlaybackProgressPolicy.maximumEntryCount,
                observedEntryCount: count
            )
        }
        let headerBytes = try encoder.encode(PlaybackProgressSnapshot(
            entries: [], checkpointSequence: sequence
        )).count
        let totalBytes = headerBytes + bytes + max(0, count - 1)
        guard totalBytes <= maximumFileByteCount else {
            throw PlaybackProgressStoreError.fileTooLarge(
                maximumByteCount: maximumFileByteCount, observedByteCount: totalBytes
            )
        }
        return (bytes, count)
    }

    private func entryByteCount(itemID: LibraryMediaItem.ID, position: TimeInterval) throws -> Int {
        try encoder.encode(PlaybackProgressSnapshot.Entry(itemID: itemID, position: position)).count
    }

    private func startCheckpoint() {
        precondition(checkpoint == nil)
        let id = UUID()
        let positions = cachedPositions
        let sequence = sequence
        let fileURL = fileURL
        let maximumByteCount = maximumFileByteCount
        let io = io
        let completion = FilePlaybackProgressJournal.CheckpointCompletion()
        let task = Task.detached(priority: .utility) {
            let result = Result {
                let data = try FilePlaybackProgressJournal.checkpointData(
                    positions: positions, sequence: sequence,
                    maximumByteCount: maximumByteCount
                )
                try io.replace(fileURL, data)
            }
            completion.finish(result)
        }
        checkpoint = CheckpointFlight(
            id: id, sequence: sequence, task: task, completion: completion
        )
    }

    private func finishReadyCheckpoint() {
        guard let flight = checkpoint, let result = flight.completion.result else { return }
        // Background failures cannot undo acknowledged journal writes. A hard
        // cap forces a retry whose failure is returned before another append.
        try? finishCheckpoint(flight, result: result)
    }

    private func finishCheckpoint(
        _ flight: CheckpointFlight, result: Result<Void, Error>
    ) throws {
        guard checkpoint?.id == flight.id else { return try result.get() }
        checkpoint = nil
        try result.get()
        let tail = journalFrames.filter { $0.sequence > flight.sequence }
        let data = encodedJournalFrames(tail)
        // Only this actor appends/trims; writes newer than the captured
        // checkpoint sequence survive the atomically replaced journal tail.
        do {
            try io.replace(journalURL, data)
        } catch {
            journalNeedsRewrite = true
            throw error
        }
        journalFrames = tail
        journalByteCount = data.count
        journalNeedsRewrite = false
    }

    private func encodedJournalFrames(_ frames: [FilePlaybackProgressJournal.Frame]) -> Data {
        var data = Data()
        data.reserveCapacity(frames.reduce(0) { $0 + $1.data.count })
        for frame in frames { data.append(frame.data) }
        return data
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        cachedPositions = [:]
        encodedEntryBytes = 0
        sequence = 0
        journalFrames = []
        journalByteCount = 0
        journalNeedsRewrite = false
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try FilePlaybackProgressJournal.readBoundedData(
                    at: fileURL, maximumByteCount: maximumFileByteCount
                )
                guard data.count <= maximumFileByteCount else {
                    throw PlaybackProgressStoreError.invalidSnapshot
                }
                let snapshot = try decoder.decode(PlaybackProgressSnapshot.self, from: data)
                guard snapshot.isValid else { throw PlaybackProgressStoreError.invalidSnapshot }
                for entry in snapshot.entries {
                    cachedPositions[entry.itemID] = entry.position
                    encodedEntryBytes += try entryByteCount(
                        itemID: entry.itemID, position: entry.position
                    )
                }
                sequence = snapshot.checkpointSequence
            } catch is DecodingError {
                try discardInvalidCache()
            } catch PlaybackProgressStoreError.invalidSnapshot {
                try discardInvalidCache()
            }
        }
        try replayJournal()
        didLoad = true
    }

    private func loadForMutation() throws {
        // An uncertain checkpoint failure leaves the last acknowledged cache
        // visible. Before the next mutation, reconcile the disk commit point;
        // if recovery itself fails, preserve that cache and keep rejecting writes.
        guard requiresDiskReconciliation else { return try loadIfNeeded() }
        let oldPositions = cachedPositions
        let oldEntryBytes = encodedEntryBytes
        let oldSequence = sequence
        let oldFrames = journalFrames
        let oldJournalBytes = journalByteCount
        let oldNeedsRewrite = journalNeedsRewrite
        didLoad = false
        do {
            try loadIfNeeded()
            requiresDiskReconciliation = false
        } catch {
            cachedPositions = oldPositions
            encodedEntryBytes = oldEntryBytes
            sequence = oldSequence
            journalFrames = oldFrames
            journalByteCount = oldJournalBytes
            journalNeedsRewrite = oldNeedsRewrite
            didLoad = true
            throw error
        }
    }

    private func replayJournal() throws {
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let data = try FilePlaybackProgressJournal.readBoundedData(
            at: journalURL, maximumByteCount: maximumJournalByteCount
        )
        let checkpointSequence = sequence
        var previousRecordSequence: UInt64 = 0
        var offset = 0
        while offset < min(data.count, maximumJournalByteCount),
              journalFrames.count < journalPolicy.maximumRecordCount,
              let newline = data[offset...].firstIndex(of: 0x0A),
              newline < maximumJournalByteCount {
            let line = data.subdata(in: offset..<newline)
            guard let record = try? decoder.decode(FilePlaybackProgressJournal.Record.self, from: line),
                  record.isValid, record.sequence > previousRecordSequence else { break }
            if record.sequence > checkpointSequence {
                guard sequence < UInt64.max, record.sequence == sequence + 1,
                      let projected = try? projectedMutation(
                        record.changes, sequence: record.sequence
                      ) else { break }
                for change in record.changes { cachedPositions[change.itemID] = change.position }
                encodedEntryBytes = projected.entryBytes
                sequence = record.sequence
            }
            previousRecordSequence = record.sequence
            let frame = data.subdata(in: offset..<(newline + 1))
            journalFrames.append(.init(sequence: record.sequence, data: frame))
            offset = newline + 1
        }
        journalByteCount = offset
        let size = try fileManager.attributesOfItem(atPath: journalURL.path)[.size] as? NSNumber
        if size?.intValue != offset {
            try io.replace(journalURL, data.prefix(offset))
        }
    }

    private func discardInvalidCache() throws {
        try fileManager.removeItem(at: fileURL)
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
        cachedPositions = [:]
        encodedEntryBytes = 0
        sequence = 0
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support is required for playback progress.")
        }
        return applicationSupportURL
            .appendingPathComponent(Storage.directoryName, isDirectory: true)
            .appendingPathComponent(Storage.fileName, isDirectory: false)
    }
}
