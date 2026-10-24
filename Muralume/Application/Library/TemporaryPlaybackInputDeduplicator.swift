import Foundation
import SQLite3

/// Request-local keys start in a small memory budget, then move to an owned
/// scratch database. Exact skipped counts require visiting every distinct input
/// path, even after the accepted-source limit; they do not require retaining all
/// of those paths in memory. Every occurrence is still resolved, because a
/// symlink may be retargeted while the request is being prepared.
final class TemporaryPlaybackInputDeduplicator {
    enum Budget {
        static let maximumResidentKeyCount = 512
        static let maximumResidentUTF8Bytes = 256 * 1_024
        static let sqliteCacheKiB = 256
        static let normalizationBatchSize = 128
    }

    private var canonicalPaths: Set<String> = []
    private var residentUTF8Bytes = 0
    private var database: ScratchDatabase?
    private let temporaryDirectoryURL: URL

    private(set) var maximumResidentKeyCount = 0
    private(set) var maximumResidentUTF8Bytes = 0
    var scratchDirectoryURL: URL? { database?.directoryURL }

    init(temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    func insertCanonicalPath(_ path: String) throws -> Bool {
        // Swift String equality uses canonical Unicode equivalence. SQLite's
        // BINARY collation alone does not, so both tiers use NFC UTF-8 keys.
        let key = path.precomposedStringWithCanonicalMapping
        if let database { return try database.insert(key) }
        guard !canonicalPaths.contains(key) else { return false }
        let keyBytes = key.utf8.count
        let residentKeyCount = canonicalPaths.count
        if residentKeyCount == Budget.maximumResidentKeyCount
            || keyBytes > Budget.maximumResidentUTF8Bytes - residentUTF8Bytes {
            let database = try ScratchDatabase(
                temporaryDirectoryURL: temporaryDirectoryURL
            )
            for existingKey in canonicalPaths {
                try Task.checkCancellation()
                _ = try database.insert(existingKey)
            }
            self.database = database
            canonicalPaths.removeAll(keepingCapacity: false)
            residentUTF8Bytes = 0
            return try database.insert(key)
        }
        canonicalPaths.insert(key)
        residentUTF8Bytes += keyBytes
        maximumResidentKeyCount = max(maximumResidentKeyCount, residentKeyCount + 1)
        maximumResidentUTF8Bytes = max(maximumResidentUTF8Bytes, residentUTF8Bytes)
        return true
    }

    private final class ScratchDatabase {
        enum Failure: Error {
            case sqlite(Int32)
        }

        let directoryURL: URL
        private var handle: OpaquePointer?
        private var statement: OpaquePointer?

        init(temporaryDirectoryURL: URL) throws {
            directoryURL = temporaryDirectoryURL.appendingPathComponent(
                "Muralume-InputDedup-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                let status = sqlite3_open_v2(
                    directoryURL.appendingPathComponent("keys.sqlite").path,
                    &handle,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                    nil
                )
                guard status == SQLITE_OK else { throw Failure.sqlite(status) }
                // Scratch data is never reused or acknowledged as durable state.
                // Fixed page cache, spillable dirty pages and no mmap keep its
                // resident cost independent of the number of input keys.
                try execute("PRAGMA journal_mode = OFF")
                try execute("PRAGMA synchronous = OFF")
                try execute("PRAGMA cache_size = -\(Budget.sqliteCacheKiB)")
                try execute("PRAGMA cache_spill = ON")
                try execute("PRAGMA mmap_size = 0")
                try execute("PRAGMA temp_store = FILE")
                try execute(
                    "CREATE TABLE canonical (key BLOB PRIMARY KEY NOT NULL) WITHOUT ROWID"
                )
                let prepareStatus = sqlite3_prepare_v2(
                    handle, "INSERT OR IGNORE INTO canonical (key) VALUES (?)",
                    -1, &statement, nil
                )
                guard prepareStatus == SQLITE_OK, statement != nil else {
                    throw Failure.sqlite(prepareStatus)
                }
                try execute("BEGIN TRANSACTION")
            } catch {
                closeAndRemove()
                throw error
            }
        }

        deinit { closeAndRemove() }

        func insert(_ key: String) throws -> Bool {
            guard let statement else {
                throw Failure.sqlite(SQLITE_MISUSE)
            }
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            let bytes = Data(key.utf8)
            let bindStatus: Int32
            if bytes.isEmpty {
                bindStatus = sqlite3_bind_zeroblob(statement, 1, 0)
            } else {
                bindStatus = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(
                        statement, 1, buffer.baseAddress, UInt64(buffer.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            }
            guard bindStatus == SQLITE_OK else { throw Failure.sqlite(bindStatus) }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else { throw Failure.sqlite(status) }
            return sqlite3_changes(handle) == 1
        }

        private func execute(_ sql: String) throws {
            let status = sqlite3_exec(handle, sql, nil, nil, nil)
            guard status == SQLITE_OK else { throw Failure.sqlite(status) }
        }

        private func closeAndRemove() {
            if let statement { sqlite3_finalize(statement) }
            statement = nil
            if let handle { sqlite3_close(handle) }
            handle = nil
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}
