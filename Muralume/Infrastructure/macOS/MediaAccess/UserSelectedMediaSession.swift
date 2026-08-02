import Foundation

@MainActor
struct SecurityScopedMediaAccess {
    struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    let makeBookmark: (URL) -> Data?
    let resolveBookmark: (Data) -> ResolvedBookmark?
    let startAccess: (URL) -> Bool
    let stopAccess: (URL) -> Void

    static let live = SecurityScopedMediaAccess(
        makeBookmark: { url in
            try? url.bookmarkData(
                options: [
                    .withSecurityScope,
                    .securityScopeAllowOnlyReadAccess
                ],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: { bookmark in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [
                    .withSecurityScope,
                    .withoutUI,
                    .withoutMounting
                ],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return ResolvedBookmark(url: url, isStale: isStale)
        },
        startAccess: { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccess: { url in
            url.stopAccessingSecurityScopedResource()
        }
    )
}

@MainActor
final class UserSelectedMediaSession: MediaAccessSession {
    private enum Storage {
        static let bookmarkKey = "media-library.root-bookmarks"
    }

    private let defaults: UserDefaults
    private let securityAccess: SecurityScopedMediaAccess
    private var activeRootURLsByPath: [String: URL] = [:]
    private var activeBookmarksByPath: [String: Data] = [:]
    private(set) var hasUnavailablePersistedFolders = false

    init(
        defaults: UserDefaults = .standard,
        securityAccess: SecurityScopedMediaAccess = .live
    ) {
        self.defaults = defaults
        self.securityAccess = securityAccess
    }

    func restoreFolders() -> [URL] {
        guard activeRootURLsByPath.isEmpty else {
            return activeRootURLs
        }

        let bookmarks = storedBookmarks
        var refreshedBookmarks: [Data] = []
        hasUnavailablePersistedFolders = false

        for bookmark in bookmarks {
            guard let resolvedBookmark = securityAccess.resolveBookmark(bookmark),
                  securityAccess.startAccess(resolvedBookmark.url) else {
                hasUnavailablePersistedFolders = true
                refreshedBookmarks.append(bookmark)
                continue
            }

            let resolvedURL = resolvedBookmark.url
            guard !overlapsActiveRoot(resolvedURL) else {
                securityAccess.stopAccess(resolvedURL)
                continue
            }

            let resolvedRootKey = rootKey(for: resolvedURL)
            activeRootURLsByPath[resolvedRootKey] = resolvedURL
            let activeBookmark = if resolvedBookmark.isStale {
                securityAccess.makeBookmark(resolvedURL) ?? bookmark
            } else {
                bookmark
            }
            activeBookmarksByPath[resolvedRootKey] = activeBookmark
            refreshedBookmarks.append(activeBookmark)
        }

        if refreshedBookmarks != bookmarks {
            store(refreshedBookmarks)
        }
        return activeRootURLs
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        var bookmarks = storedBookmarks

        for selectedURL in urls {
            // URLs returned by NSOpenPanel already hold an implicit Powerbox
            // security scope. Always relinquish that grant after converting it
            // into the persistent bookmark used by this session.
            defer {
                securityAccess.stopAccess(selectedURL)
            }

            guard !overlapsActiveRoot(selectedURL),
                  let bookmark = securityAccess.makeBookmark(selectedURL),
                  let resolvedBookmark = securityAccess.resolveBookmark(bookmark),
                  securityAccess.startAccess(resolvedBookmark.url) else {
                continue
            }

            let resolvedURL = resolvedBookmark.url
            guard !overlapsActiveRoot(resolvedURL) else {
                securityAccess.stopAccess(resolvedURL)
                continue
            }

            let resolvedRootKey = rootKey(for: resolvedURL)
            activeRootURLsByPath[resolvedRootKey] = resolvedURL
            let activeBookmark = (
                resolvedBookmark.isStale
                    ? securityAccess.makeBookmark(resolvedURL) ?? bookmark
                    : bookmark
            )
            activeBookmarksByPath[resolvedRootKey] = activeBookmark
            bookmarks.append(activeBookmark)
        }

        store(bookmarks)
        return activeRootURLs
    }

    func prepareToRemoveFolder(_ url: URL) {
        let removedRootKey = rootKey(for: url)
        let activeBookmark = activeBookmarksByPath.removeValue(
            forKey: removedRootKey
        )

        let remainingBookmarks = storedBookmarks.filter { bookmark in
            if let activeBookmark, bookmark == activeBookmark {
                return false
            }
            guard let resolvedBookmark = securityAccess.resolveBookmark(
                bookmark
            ) else {
                return true
            }
            return rootKey(for: resolvedBookmark.url) != removedRootKey
        }
        store(remainingBookmarks)
    }

    func removeFolder(_ url: URL) -> [URL] {
        prepareToRemoveFolder(url)
        let removedRootKey = rootKey(for: url)
        if let activeURL = activeRootURLsByPath.removeValue(
            forKey: removedRootKey
        ) {
            securityAccess.stopAccess(activeURL)
        }
        return activeRootURLs
    }

    func stop() {
        for url in activeRootURLsByPath.values {
            securityAccess.stopAccess(url)
        }
        activeRootURLsByPath.removeAll()
        activeBookmarksByPath.removeAll()
        hasUnavailablePersistedFolders = false
    }

    private var storedBookmarks: [Data] {
        defaults.array(forKey: Storage.bookmarkKey) as? [Data] ?? []
    }

    private var activeRootURLs: [URL] {
        activeRootURLsByPath.values.sorted {
            rootKey(for: $0).localizedStandardCompare(rootKey(for: $1))
                == .orderedAscending
        }
    }

    private func overlapsActiveRoot(_ candidateURL: URL) -> Bool {
        activeRootURLsByPath.values.contains { activeURL in
            Self.rootsOverlap(candidateURL, activeURL)
        }
    }

    private func rootKey(for url: URL) -> String {
        Self.comparisonURL(for: url).path
    }

    private func store(_ bookmarks: [Data]) {
        defaults.set(bookmarks, forKey: Storage.bookmarkKey)
    }

    private static func rootsOverlap(_ firstURL: URL, _ secondURL: URL) -> Bool {
        let firstComparisonURL = comparisonURL(for: firstURL)
        let secondComparisonURL = comparisonURL(for: secondURL)

        if firstComparisonURL.path == secondComparisonURL.path
            || resourceIdentifiersMatch(
                firstComparisonURL,
                secondComparisonURL
            ) {
            return true
        }

        return relationship(
            directoryURL: firstComparisonURL,
            itemURL: secondComparisonURL
        ) != .other
            || relationship(
                directoryURL: secondComparisonURL,
                itemURL: firstComparisonURL
            ) != .other
    }

    private static func comparisonURL(for url: URL) -> URL {
        let aliasResolvedURL = (
            try? URL(
                resolvingAliasFileAt: url,
                options: [.withoutUI, .withoutMounting]
            )
        ) ?? url

        return aliasResolvedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func resourceIdentifiersMatch(
        _ firstURL: URL,
        _ secondURL: URL
    ) -> Bool {
        guard let firstIdentifier = resourceIdentifier(for: firstURL),
              let secondIdentifier = resourceIdentifier(for: secondURL) else {
            return false
        }
        return firstIdentifier.isEqual(secondIdentifier)
    }

    private static func resourceIdentifier(for url: URL) -> NSObject? {
        do {
            return try url.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier as? NSObject
        } catch {
            return nil
        }
    }

    private static func relationship(
        directoryURL: URL,
        itemURL: URL
    ) -> FileManager.URLRelationship {
        var relationship = FileManager.URLRelationship.other
        do {
            try FileManager.default.getRelationship(
                &relationship,
                ofDirectoryAt: directoryURL,
                toItemAt: itemURL
            )
        } catch {
            return .other
        }
        return relationship
    }
}
