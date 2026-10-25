import Foundation

struct ExternalSubtitleBookmarkIO: Sendable {
    struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    let resolve: @Sendable (Data) -> Resolution?
    let create: @Sendable (URL) -> Data?

    static let live = ExternalSubtitleBookmarkIO(
        resolve: { data in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            return Resolution(url: url, isStale: isStale)
        },
        create: { url in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    )
}

struct ExternalSubtitleAssociationPersistence: Sendable {
    let read: @Sendable () -> Data?
    let write: @Sendable (Data?) -> Void
}

/// Serializes bookmark/filesystem work off the UI executor. Only raw bookmark
/// records are cached, keyed by standardized media path, in this defaults
/// suite's store instance. The cache holds at most 64 records and is released
/// with the store. Every lookup resolves its bookmark again; stale, failed,
/// saved and removed associations update the same actor-owned state.
actor UserDefaultsExternalSubtitleAssociationStore: ExternalSubtitleAssociationStoring {
    private enum Storage {
        static let key = "playback.externalSubtitleAssociations.v1"
        static let maximumEncodedBytes = 8 * 1_024 * 1_024
    }

    private struct Record: Codable {
        let mediaPath: String
        let bookmark: Data
        var lastUsed: Date
    }

    // UserDefaults supports concurrent access; its non-Sendable annotation
    // must not transfer the rest of the bookmark/cache state out of this actor.
    private final class Defaults: @unchecked Sendable {
        let value: UserDefaults
        init(_ value: UserDefaults) { self.value = value }
    }

    private let persistence: ExternalSubtitleAssociationPersistence
    private let bookmarkIO: ExternalSubtitleBookmarkIO
    private let recencySaveDelay: Duration
    private var records: [String: Record] = [:]
    private var didLoad = false
    private var recencySaveTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        bookmarkIO: ExternalSubtitleBookmarkIO = .live,
        recencySaveDelay: Duration = .seconds(30),
        persistence: ExternalSubtitleAssociationPersistence? = nil
    ) {
        let defaults = Defaults(defaults)
        self.persistence = persistence ?? ExternalSubtitleAssociationPersistence(
            read: { defaults.value.data(forKey: Storage.key) },
            write: { data in
                if let data { defaults.value.set(data, forKey: Storage.key) }
                else { defaults.value.removeObject(forKey: Storage.key) }
            }
        )
        self.bookmarkIO = bookmarkIO
        self.recencySaveDelay = recencySaveDelay
    }

    deinit { recencySaveTask?.cancel() }

    func subtitleURL(for mediaURL: URL) -> URL? {
        guard !Task.isCancelled else { return nil }
        loadIfNeeded()
        let mediaPath = normalizedPath(mediaURL)
        guard var record = records[mediaPath] else { return nil }
        let resolution = bookmarkIO.resolve(record.bookmark)
        // Resolution may be non-cooperative filesystem work. A cancelled
        // lookup never updates recency or replaces a later user's choice.
        guard !Task.isCancelled else { return nil }
        guard let resolution else {
            records[mediaPath] = nil
            persistRecords()
            return nil
        }
        record.lastUsed = Date()
        if resolution.isStale, let bookmark = bookmark(for: resolution.url) {
            guard !Task.isCancelled else { return nil }
            record = Record(mediaPath: mediaPath, bookmark: bookmark, lastUsed: record.lastUsed)
            records[mediaPath] = record
            persistRecords()
        } else {
            records[mediaPath] = record
            scheduleRecencySave()
        }
        return resolution.url
    }

    func save(subtitleURL: URL, for mediaURL: URL) {
        guard !Task.isCancelled else { return }
        loadIfNeeded()
        guard let bookmark = bookmark(for: subtitleURL), !Task.isCancelled else { return }
        let mediaPath = normalizedPath(mediaURL)
        records[mediaPath] = Record(mediaPath: mediaPath, bookmark: bookmark, lastUsed: Date())
        trimRecords()
        persistRecords()
    }

    func removeSubtitleURL(for mediaURL: URL) {
        loadIfNeeded()
        guard records.removeValue(forKey: normalizedPath(mediaURL)) != nil else { return }
        persistRecords()
    }

    private func bookmark(for url: URL) -> Data? {
        guard let data = bookmarkIO.create(url),
              data.count <= ExternalSubtitlePolicy.maximumBookmarkBytes else { return nil }
        return data
    }

    private func normalizedPath(_ url: URL) -> String { url.standardizedFileURL.path }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = persistence.read(),
              data.count <= Storage.maximumEncodedBytes,
              let loaded = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in loaded.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            guard records.count < ExternalSubtitlePolicy.maximumStoredAssociations else { break }
            guard record.bookmark.count <= ExternalSubtitlePolicy.maximumBookmarkBytes,
                  records[record.mediaPath] == nil else { continue }
            records[record.mediaPath] = record
        }
    }

    private func trimRecords() {
        if records.count > ExternalSubtitlePolicy.maximumStoredAssociations {
            let retained = records.values.sorted { $0.lastUsed > $1.lastUsed }
                .prefix(ExternalSubtitlePolicy.maximumStoredAssociations)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.mediaPath, $0) })
        }
    }

    private func scheduleRecencySave() {
        guard recencySaveTask == nil else { return }
        let delay = recencySaveDelay
        recencySaveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            await self?.flushRecency()
        }
    }

    private func flushRecency() {
        recencySaveTask = nil
        persistRecords()
    }

    private func persistRecords() {
        recencySaveTask?.cancel()
        recencySaveTask = nil
        guard !records.isEmpty else {
            persistence.write(nil)
            return
        }
        let ordered = records.values.sorted { $0.lastUsed > $1.lastUsed }
        guard let data = try? JSONEncoder().encode(ordered),
              data.count <= Storage.maximumEncodedBytes else { return }
        persistence.write(data)
    }
}
