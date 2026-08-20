import Foundation

@MainActor
final class UserDefaultsExternalSubtitleAssociationStore:
    ExternalSubtitleAssociationStoring {
    private enum Storage {
        static let key = "playback.externalSubtitleAssociations.v1"
    }

    private struct Record: Codable {
        let mediaPath: String
        let bookmark: Data
        var lastUsed: Date
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func subtitleURL(for mediaURL: URL) -> URL? {
        let mediaPath = normalizedPath(mediaURL)
        var records = loadRecords()
        guard let index = records.firstIndex(
            where: { $0.mediaPath == mediaPath }
        ) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: records[index].bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            records.remove(at: index)
            saveRecords(records)
            return nil
        }

        records[index].lastUsed = Date()
        if isStale,
           let refreshedBookmark = bookmark(for: url) {
            records[index] = Record(
                mediaPath: mediaPath,
                bookmark: refreshedBookmark,
                lastUsed: Date()
            )
        }
        saveRecords(records)
        return url
    }

    func save(subtitleURL: URL, for mediaURL: URL) {
        guard let bookmark = bookmark(for: subtitleURL) else {
            return
        }
        let mediaPath = normalizedPath(mediaURL)
        var records = loadRecords()
        records.removeAll { $0.mediaPath == mediaPath }
        records.append(
            Record(
                mediaPath: mediaPath,
                bookmark: bookmark,
                lastUsed: Date()
            )
        )
        records.sort { $0.lastUsed > $1.lastUsed }
        saveRecords(
            Array(records.prefix(
                ExternalSubtitlePolicy.maximumStoredAssociations
            ))
        )
    }

    func removeSubtitleURL(for mediaURL: URL) {
        let mediaPath = normalizedPath(mediaURL)
        var records = loadRecords()
        records.removeAll { $0.mediaPath == mediaPath }
        saveRecords(records)
    }

    private func bookmark(for url: URL) -> Data? {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), data.count <= ExternalSubtitlePolicy.maximumBookmarkBytes else {
            return nil
        }
        return data
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func loadRecords() -> [Record] {
        guard let data = defaults.data(forKey: Storage.key),
              let records = try? JSONDecoder().decode(
                [Record].self,
                from: data
              ) else {
            return []
        }
        return records.filter {
            $0.bookmark.count <= ExternalSubtitlePolicy.maximumBookmarkBytes
        }
    }

    private func saveRecords(_ records: [Record]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Storage.key)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: Storage.key)
    }
}
