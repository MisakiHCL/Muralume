import Foundation

/// Immutable library metadata prepared with the library's existing ID index.
/// Canonical roots are deliberately resolved by each worker, because aliases
/// can change without a library refresh. Reordering shares all lookup storage.
struct TemporaryPlaybackLibrarySnapshot: Sendable {
    struct Matches: Sendable {
        let items: [LibraryMediaItem?]
        /// Full item visits are limited to exceptional paths or alias ties.
        let visitedItemCount: Int
    }

    private struct Root: Sendable {
        let path: String
        let url: URL
    }

    static let empty = TemporaryPlaybackLibrarySnapshot(
        items: [], itemsByID: [:], rootURLsByPath: [:]
    )

    private let items: [LibraryMediaItem]
    private let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    private let roots: [Root]
    private let exceptionalItems: [LibraryMediaItem]
    private let requiresLegacyLookup: Bool

    init(
        items: [LibraryMediaItem],
        itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        rootURLsByPath: [String: URL]
    ) {
        self.items = items
        self.itemsByID = itemsByID
        var roots: [Root] = []
        var seenRoots: Set<String> = []
        var exceptionalItems: [LibraryMediaItem] = []
        for item in items {
            let path = item.id.rootPath
            if seenRoots.insert(path).inserted {
                roots.append(Root(
                    path: path, url: rootURLsByPath[path] ?? item.rootURL
                ))
            }
            // A parent component can leave an aliased root, even when the
            // lexical normalized path eventually returns inside that root.
            // Scanner-produced relative paths do not contain these components.
            let relativePath = item.relativePath
            if relativePath == ".." || relativePath.hasPrefix("../")
                || relativePath.contains("/../") || relativePath.hasSuffix("/..") {
                exceptionalItems.append(item)
            }
        }
        self.roots = roots
        self.exceptionalItems = exceptionalItems
        // The compatibility API can receive duplicate normalized IDs whose
        // original roots differ. Keep its ordered-map semantics in that case.
        requiresLegacyLookup = items.count != itemsByID.count
    }

    private init(
        items: [LibraryMediaItem],
        sharing snapshot: TemporaryPlaybackLibrarySnapshot
    ) {
        self.items = items
        itemsByID = snapshot.itemsByID
        roots = snapshot.roots
        exceptionalItems = snapshot.exceptionalItems
        requiresLegacyLookup = snapshot.requiresLegacyLookup
    }

    func reordered(items: [LibraryMediaItem]) -> Self {
        Self(items: items, sharing: self)
    }

    func matches(
        canonicalPaths: [String],
        canonicalPath: @Sendable (URL) -> String
    ) throws -> Matches {
        guard !canonicalPaths.isEmpty else {
            return Matches(items: [], visitedItemCount: 0)
        }
        var canonicalRoots: [String: URL] = [:]
        canonicalRoots.reserveCapacity(roots.count)
        for root in roots {
            try Task.checkCancellation()
            canonicalRoots[root.path] = URL(
                fileURLWithPath: canonicalPath(root.url)
            ).standardizedFileURL
        }
        if requiresLegacyLookup {
            var itemsByPath: [String: LibraryMediaItem] = [:]
            for item in items {
                try Task.checkCancellation()
                guard let root = canonicalRoots[item.id.rootPath] else { continue }
                itemsByPath[Self.path(for: item, canonicalRoot: root)] = item
            }
            return Matches(
                items: canonicalPaths.map { itemsByPath[$0] },
                visitedItemCount: items.count
            )
        }

        var exceptionalIDsByPath: [String: Set<LibraryMediaItem.ID>] = [:]
        for item in exceptionalItems {
            try Task.checkCancellation()
            guard let root = canonicalRoots[item.id.rootPath] else { continue }
            exceptionalIDsByPath[Self.path(for: item, canonicalRoot: root), default: []]
                .insert(item.id)
        }
        var visitedItemCount = exceptionalItems.count
        var matches: [LibraryMediaItem?] = []
        matches.reserveCapacity(canonicalPaths.count)
        for path in canonicalPaths {
            try Task.checkCancellation()
            var matchedIDs = exceptionalIDsByPath[path] ?? []
            for root in roots {
                guard let canonicalRoot = canonicalRoots[root.path] else { continue }
                let canonicalRootPath = canonicalRoot.path
                let relativePath: String
                if path == canonicalRootPath {
                    relativePath = ""
                } else {
                    let prefix = canonicalRootPath == "/" ? "/" : canonicalRootPath + "/"
                    guard path.hasPrefix(prefix) else { continue }
                    relativePath = String(path.dropFirst(prefix.count))
                }
                let id = LibraryMediaItem.ID(
                    rootPath: root.path, relativePath: relativePath
                )
                guard let item = itemsByID[id], item.id.rootPath == root.path,
                      Self.path(for: item, canonicalRoot: canonicalRoot) == path else {
                    continue
                }
                matchedIDs.insert(item.id)
            }
            if matchedIDs.count == 1, let id = matchedIDs.first {
                matches.append(itemsByID[id])
            } else if matchedIDs.count > 1 {
                // Aliased/overlapping roots use the last item in the current
                // visible order, just as the previous ordered canonical map.
                var match: LibraryMediaItem?
                for item in items.reversed() {
                    try Task.checkCancellation()
                    visitedItemCount += 1
                    if matchedIDs.contains(item.id) {
                        match = item
                        break
                    }
                }
                matches.append(match)
            } else {
                matches.append(nil)
            }
        }
        return Matches(items: matches, visitedItemCount: visitedItemCount)
    }

    private static func path(
        for item: LibraryMediaItem, canonicalRoot: URL
    ) -> String {
        let url = item.relativePath.isEmpty
            ? canonicalRoot : canonicalRoot.appendingPathComponent(item.relativePath)
        return url.standardizedFileURL.path
    }
}
