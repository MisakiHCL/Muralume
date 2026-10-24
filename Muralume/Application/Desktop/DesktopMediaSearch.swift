import Foundation

/// The desktop picker searches three visible fields. Keep this distinct from
/// library search, which also matches the complete relative media filename.
struct DesktopMediaSearch: Sendable {
    let query: String

    init(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func updateProjection(
        _ projection: LatestMediaSearch<[LibraryMediaItem]>,
        requestID: DesktopMediaSearchRequestID,
        items: [LibraryMediaItem]
    ) {
        // SwiftUI can cancel a queued .task before it enters this body. It
        // must not restart work after onDisappear has cleared the projection.
        guard !Task.isCancelled else { return }
        if query.isEmpty {
            projection.cancel()
        } else {
            projection.request(key: requestID) {
                try filteredItemsCancellable(from: items)
            }
        }
    }

    func filteredItemsCancellable(
        from items: [LibraryMediaItem]
    ) throws -> [LibraryMediaItem] {
        try Task.checkCancellation()
        guard !query.isEmpty else { return items }
        var matches: [LibraryMediaItem] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if item.displayName.localizedStandardContains(query)
                || item.rootName.localizedStandardContains(query)
                || item.relativeDirectory.localizedStandardContains(query) {
                matches.append(item)
            }
        }
        try Task.checkCancellation()
        return matches
    }
}

/// The immutable ordered library snapshot and locale invalidate old results.
/// LatestMediaSearch owns at most one worker and one latest pending snapshot;
/// leaving the picker clears the completed projection and cancels its work.
struct DesktopMediaSearchRequestID: Hashable {
    let itemsRevision: UInt64
    let query: String
    let localeIdentifier: String
    let systemLocaleIdentifier: String
}
