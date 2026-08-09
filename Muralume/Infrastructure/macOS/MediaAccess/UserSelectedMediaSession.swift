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
        static let legacyBookmarkKey = "media-library.root-bookmarks"
        static let sourceRecordKey = "media-library.source-records"
        static let currentSchemaVersion = 1

        enum RecordField {
            static let schemaVersion = "schemaVersion"
            static let kind = "kind"
            static let bookmark = "bookmark"
        }
    }

    private struct PersistedSourceRecord {
        let schemaVersion: Int
        let kind: MediaSourceKind
        let bookmark: Data

        init(kind: MediaSourceKind, bookmark: Data) {
            schemaVersion = Storage.currentSchemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        init?(storedValue: Any) {
            guard let fields = storedValue as? [String: Any],
                  let schemaVersion = fields[
                      Storage.RecordField.schemaVersion
                  ] as? Int,
                  schemaVersion == Storage.currentSchemaVersion,
                  let rawKind = fields[Storage.RecordField.kind] as? String,
                  let kind = MediaSourceKind(rawValue: rawKind),
                  let bookmark = fields[
                      Storage.RecordField.bookmark
                  ] as? Data else {
                return nil
            }
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        var storedValue: [String: Any] {
            [
                Storage.RecordField.schemaVersion: schemaVersion,
                Storage.RecordField.kind: kind.rawValue,
                Storage.RecordField.bookmark: bookmark
            ]
        }
    }

    private enum RestoreOrigin {
        case typed(storedValue: Any)
        case legacy(bookmark: Data)
    }

    private struct RestoreCandidate {
        let record: PersistedSourceRecord
        let origin: RestoreOrigin
    }

    private struct PendingLinkedCandidate {
        let candidate: RestoreCandidate
        let targetSource: MediaSource?
    }

    private let defaults: UserDefaults
    private let securityAccess: SecurityScopedMediaAccess
    private let sourceKindResolver: (URL) -> MediaSourceKind?
    private var activeSourcesByKey: [String: MediaSource] = [:]
    private var activeRecordsByKey: [String: PersistedSourceRecord] = [:]
    private var activeResourceIdentifiersByKey: [String: NSObject] = [:]
    private var unavailableStoredRecordValues: [Any] = []
    private var unavailableLegacyBookmarks: [Data] = []
    private var deferredStoredRecordValues: ArraySlice<Any> = []
    private var deferredLegacyBookmarks: ArraySlice<Data> = []
    private var didAttemptRestore = false
    private(set) var hasUnavailablePersistedSources = false

    init(
        defaults: UserDefaults = .standard,
        securityAccess: SecurityScopedMediaAccess = .live,
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            UserSelectedMediaSession.liveSourceKind(at: $0)
        }
    ) {
        self.defaults = defaults
        self.securityAccess = securityAccess
        self.sourceKindResolver = sourceKindResolver
    }

    func restoreSources() -> [MediaSource] {
        guard !didAttemptRestore else {
            return activeSources
        }
        didAttemptRestore = true

        // UserDefaults' array API necessarily materializes the existing
        // property-list arrays before record-level validation. The restore
        // budget below bounds bookmark resolution and active scopes; slices
        // avoid another full overflow-tail copy, but the current persisted
        // format cannot impose a total byte bound without a migration.
        let storedRecordValues = storedSourceRecordValues
        let legacyBookmarks = storedLegacyBookmarks
        restoreCandidates(
            storedRecordValues: storedRecordValues,
            legacyBookmarks: legacyBookmarks
        )
        storeSourceRecords(currentStoredRecordValues)
        storeLegacyBookmarks(currentLegacyBookmarks)
        return activeSources
    }

    func retryUnavailableSources() -> [MediaSource] {
        guard didAttemptRestore else {
            return restoreSources()
        }
        guard hasUnavailablePersistedSources else {
            return activeSources
        }

        let storedRecordValues = Array(deferredStoredRecordValues)
            + unavailableStoredRecordValues
        let legacyBookmarks = Array(deferredLegacyBookmarks)
            + unavailableLegacyBookmarks

        restoreCandidates(
            storedRecordValues: storedRecordValues,
            legacyBookmarks: legacyBookmarks
        )
        storeSourceRecords(currentStoredRecordValues)
        storeLegacyBookmarks(currentLegacyBookmarks)
        return activeSources
    }

    private func restoreCandidates(
        storedRecordValues: [Any],
        legacyBookmarks: [Data]
    ) {
        unavailableStoredRecordValues = []
        unavailableLegacyBookmarks = []
        deferredStoredRecordValues = []
        deferredLegacyBookmarks = []
        hasUnavailablePersistedSources = false
        var pendingLinkedCandidates: [PendingLinkedCandidate] = []
        var remainingRestoreCandidateCount =
            MediaImportPolicy.maximumRestoredSourceRecordCount

        for (index, storedValue) in storedRecordValues.enumerated() {
            let shouldReserveLegacyCandidate =
                !legacyBookmarks.isEmpty
                && activeSourcesByKey.count
                    < MediaImportPolicy.maximumActiveSourceCount
                && remainingRestoreCandidateCount
                    == MediaImportPolicy.reservedLegacyRestoreCandidateCount
            guard !shouldReserveLegacyCandidate else {
                deferredStoredRecordValues = storedRecordValues[index...]
                hasUnavailablePersistedSources = true
                break
            }
            guard remainingRestoreCandidateCount > 0 else {
                deferredStoredRecordValues = storedRecordValues[index...]
                hasUnavailablePersistedSources = true
                break
            }
            remainingRestoreCandidateCount -= 1
            guard let record = PersistedSourceRecord(
                storedValue: storedValue
            ) else {
                preserveUnavailableStoredRecord(storedValue)
                continue
            }
            restore(
                RestoreCandidate(
                    record: record,
                    origin: .typed(storedValue: storedValue)
                ),
                pendingLinkedCandidates: &pendingLinkedCandidates
            )
        }

        for (index, bookmark) in legacyBookmarks.enumerated() {
            guard remainingRestoreCandidateCount > 0 else {
                deferredLegacyBookmarks = legacyBookmarks[index...]
                hasUnavailablePersistedSources = true
                break
            }
            remainingRestoreCandidateCount -= 1
            restore(
                RestoreCandidate(
                    record: PersistedSourceRecord(
                        kind: .folder,
                        bookmark: bookmark
                    ),
                    origin: .legacy(bookmark: bookmark)
                ),
                pendingLinkedCandidates: &pendingLinkedCandidates
            )
        }

        for pending in pendingLinkedCandidates {
            guard let targetSource = pending.targetSource,
                  case .covered = disposition(for: targetSource) else {
                preserveUnavailable(pending.candidate)
                continue
            }
        }
    }

    func restoreFolders() -> [URL] {
        restoreSources().compactMap { source in
            source.kind == .folder ? source.url : nil
        }
    }

    func addSources(_ urls: [URL]) -> MediaAccessUpdate {
        _ = restoreSources()
        var requestedFileURLs: [URL] = []
        var requestedFileIDs: Set<LibraryMediaItem.ID> = []
        var acceptedRequestCount = 0
        var rejectedRequestCount = 0
        var didChangeSources = false

        for (requestIndex, selectedURL) in urls.enumerated() {
            // URLs returned by NSOpenPanel already hold an implicit Powerbox
            // security scope. Always relinquish that grant after converting it
            // into the persistent bookmark used by this session.
            defer {
                securityAccess.stopAccess(selectedURL)
            }

            guard requestIndex < MediaImportPolicy.maximumTopLevelSourceCount else {
                rejectedRequestCount += 1
                continue
            }

            let selectedLinkResolution = Self.linkResolution(for: selectedURL)
            guard let selectedKind = sourceKindResolver(
                selectedLinkResolution.targetURL
            ), Self.isSupported(
                kind: selectedKind,
                url: selectedLinkResolution.targetURL
            ) else {
                rejectedRequestCount += 1
                continue
            }
            let selectedSource = MediaSource(
                url: selectedLinkResolution.didResolveLink
                    ? selectedLinkResolution.targetURL
                    : selectedURL,
                kind: selectedKind
            )
            switch disposition(for: selectedSource) {
            case .covered:
                acceptedRequestCount += 1
                if selectedKind == .file {
                    appendRequestedFileURL(
                        playbackURL(for: selectedSource),
                        to: &requestedFileURLs,
                        seenIDs: &requestedFileIDs
                    )
                }
                continue
            case .rejected:
                rejectedRequestCount += 1
                continue
            case let .insert(replacingKeys):
                guard canInstallSource(replacingKeys: replacingKeys) else {
                    rejectedRequestCount += 1
                    continue
                }
            }
            guard !selectedLinkResolution.didResolveLink else {
                rejectedRequestCount += 1
                continue
            }

            guard let bookmark = securityAccess.makeBookmark(selectedURL),
                  Self.bookmarkIsWithinPersistenceLimit(bookmark),
                  let resolvedBookmark = securityAccess.resolveBookmark(bookmark),
                  securityAccess.startAccess(resolvedBookmark.url) else {
                rejectedRequestCount += 1
                continue
            }

            let resolvedURL = resolvedBookmark.url
            let resolvedLinkResolution = Self.linkResolution(for: resolvedURL)
            guard let resolvedKind = sourceKindResolver(
                resolvedLinkResolution.targetURL
            ), Self.isSupported(
                kind: resolvedKind,
                url: resolvedLinkResolution.targetURL
            ) else {
                securityAccess.stopAccess(resolvedURL)
                rejectedRequestCount += 1
                continue
            }
            let resolvedSource = MediaSource(
                url: resolvedLinkResolution.didResolveLink
                    ? resolvedLinkResolution.targetURL
                    : resolvedURL,
                kind: resolvedKind
            )
            if resolvedLinkResolution.didResolveLink {
                securityAccess.stopAccess(resolvedURL)
                if case .covered = disposition(for: resolvedSource) {
                    acceptedRequestCount += 1
                    if resolvedKind == .file {
                        appendRequestedFileURL(
                            playbackURL(for: resolvedSource),
                            to: &requestedFileURLs,
                            seenIDs: &requestedFileIDs
                        )
                    }
                } else {
                    rejectedRequestCount += 1
                }
                continue
            }
            let resolvedDisposition = disposition(for: resolvedSource)
            if case .rejected = resolvedDisposition {
                securityAccess.stopAccess(resolvedURL)
                rejectedRequestCount += 1
                continue
            }
            if case let .insert(replacingKeys) = resolvedDisposition,
               !canInstallSource(replacingKeys: replacingKeys) {
                securityAccess.stopAccess(resolvedURL)
                rejectedRequestCount += 1
                continue
            }
            let activeBookmark: Data
            if case .insert = resolvedDisposition,
               resolvedBookmark.isStale,
               let refreshedBookmark = securityAccess.makeBookmark(resolvedURL) {
                guard Self.bookmarkIsWithinPersistenceLimit(
                    refreshedBookmark
                ) else {
                    securityAccess.stopAccess(resolvedURL)
                    rejectedRequestCount += 1
                    continue
                }
                activeBookmark = refreshedBookmark
            } else {
                activeBookmark = bookmark
            }
            acceptedRequestCount += 1
            if resolvedKind == .file {
                let playbackURL = if case .covered = resolvedDisposition {
                    playbackURL(for: resolvedSource)
                } else {
                    resolvedURL
                }
                appendRequestedFileURL(
                    playbackURL,
                    to: &requestedFileURLs,
                    seenIDs: &requestedFileIDs
                )
            }

            switch resolvedDisposition {
            case .covered:
                securityAccess.stopAccess(resolvedURL)
            case .rejected:
                securityAccess.stopAccess(resolvedURL)
            case let .insert(replacingKeys):
                let replacedURLs = install(
                    resolvedSource,
                    bookmark: activeBookmark,
                    replacingKeys: replacingKeys
                )
                // Persist the broader grant before relinquishing exact-file
                // scopes that it replaces.
                storeSourceRecords(currentStoredRecordValues)
                for replacedURL in replacedURLs {
                    securityAccess.stopAccess(replacedURL)
                }
                didChangeSources = true
            }
        }

        return MediaAccessUpdate(
            activeSources: activeSources,
            requestedFileURLs: requestedFileURLs,
            acceptedRequestCount: acceptedRequestCount,
            rejectedRequestCount: rejectedRequestCount,
            didChangeSources: didChangeSources
        )
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        addSources(urls).activeSources.compactMap { source in
            source.kind == .folder ? source.url : nil
        }
    }

    func prepareToRemoveSource(_ source: MediaSource) {
        guard let activeKey = activeKey(matching: source) else {
            return
        }
        activeRecordsByKey.removeValue(forKey: activeKey)
        storeSourceRecords(currentStoredRecordValues)
    }

    func prepareToRemoveFolder(_ url: URL) {
        prepareToRemoveSource(MediaSource(url: url, kind: .folder))
    }

    func removeSource(_ source: MediaSource) -> [MediaSource] {
        prepareToRemoveSource(source)
        guard let activeKey = activeKey(matching: source),
              let activeSource = activeSourcesByKey.removeValue(
                  forKey: activeKey
              ) else {
            return activeSources
        }
        activeRecordsByKey.removeValue(forKey: activeKey)
        activeResourceIdentifiersByKey.removeValue(forKey: activeKey)
        securityAccess.stopAccess(activeSource.url)
        return activeSources
    }

    func removeFolder(_ url: URL) -> [URL] {
        removeSource(MediaSource(url: url, kind: .folder)).compactMap { source in
            source.kind == .folder ? source.url : nil
        }
    }

    func stop() {
        for source in activeSourcesByKey.values {
            securityAccess.stopAccess(source.url)
        }
        activeSourcesByKey.removeAll()
        activeRecordsByKey.removeAll()
        activeResourceIdentifiersByKey.removeAll()
        unavailableStoredRecordValues.removeAll()
        unavailableLegacyBookmarks.removeAll()
        deferredStoredRecordValues.removeAll()
        deferredLegacyBookmarks.removeAll()
        hasUnavailablePersistedSources = false
        didAttemptRestore = false
    }

    private var storedSourceRecordValues: [Any] {
        defaults.array(forKey: Storage.sourceRecordKey) ?? []
    }

    private var storedLegacyBookmarks: [Data] {
        defaults.array(forKey: Storage.legacyBookmarkKey) as? [Data] ?? []
    }

    private var activeSources: [MediaSource] {
        activeSourcesByKey.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.compactMap {
            activeSourcesByKey[$0]
        }
    }

    private var currentStoredRecordValues: [Any] {
        var storedValues: [Any] = []
        storedValues.reserveCapacity(
            activeRecordsByKey.count
                + deferredStoredRecordValues.count
                + unavailableStoredRecordValues.count
        )
        for key in activeSourcesByKey.keys.sorted() {
            if let storedValue = activeRecordsByKey[key]?.storedValue {
                storedValues.append(storedValue)
            }
        }
        // Unattempted records must precede records already confirmed
        // unavailable so a bad/offline prefix cannot consume every future
        // restore budget. No value is discarded or rewritten.
        storedValues.append(contentsOf: deferredStoredRecordValues)
        storedValues.append(contentsOf: unavailableStoredRecordValues)
        return storedValues
    }

    private var currentLegacyBookmarks: [Data] {
        var bookmarks: [Data] = []
        bookmarks.reserveCapacity(
            deferredLegacyBookmarks.count + unavailableLegacyBookmarks.count
        )
        bookmarks.append(contentsOf: deferredLegacyBookmarks)
        bookmarks.append(contentsOf: unavailableLegacyBookmarks)
        return bookmarks
    }

    private func sourceKey(for url: URL) -> String {
        Self.comparisonURL(for: url).path
    }

    private func storeSourceRecords(_ storedValues: [Any]) {
        defaults.set(storedValues, forKey: Storage.sourceRecordKey)
    }

    private func storeLegacyBookmarks(_ bookmarks: [Data]) {
        guard !bookmarks.isEmpty else {
            defaults.removeObject(forKey: Storage.legacyBookmarkKey)
            return
        }
        defaults.set(bookmarks, forKey: Storage.legacyBookmarkKey)
    }

    private enum SourceDisposition {
        case covered
        case rejected
        case insert(replacingKeys: [String])
    }

    private func canInstallSource(replacingKeys: [String]) -> Bool {
        let replacedActiveSourceCount = replacingKeys.reduce(into: 0) {
            count, key in
            if activeSourcesByKey[key] != nil {
                count += 1
            }
        }
        let resultingSourceCount = activeSourcesByKey.count
            - replacedActiveSourceCount
            + 1
        return resultingSourceCount
            <= MediaImportPolicy.maximumActiveSourceCount
    }

    private func disposition(for candidate: MediaSource) -> SourceDisposition {
        let candidateComparisonURL = Self.comparisonURL(for: candidate.url)
        let candidateKey = candidateComparisonURL.path
        if activeSourcesByKey[candidateKey] != nil {
            return .covered
        }
        if let candidateIdentifier = Self.resourceIdentifier(
            for: candidateComparisonURL
        ), activeResourceIdentifiersByKey.values.contains(where: {
            $0.isEqual(candidateIdentifier)
        }) {
            return .covered
        }

        guard candidate.kind == .folder else {
            if activeSourcesByKey.contains(where: { key, source in
                source.kind == .folder
                    && Self.folder(
                        URL(fileURLWithPath: key, isDirectory: true),
                        covers: candidateComparisonURL
                    )
            }) {
                return .covered
            }
            return .insert(replacingKeys: [])
        }

        let overlapsActiveFolder = activeSourcesByKey.contains { key, source in
            guard source.kind == .folder else {
                return false
            }
            let activeFolderURL = URL(
                fileURLWithPath: key,
                isDirectory: true
            )
            return Self.folder(activeFolderURL, covers: candidateComparisonURL)
                || Self.folder(candidateComparisonURL, covers: activeFolderURL)
        }
        guard !overlapsActiveFolder else {
            return .rejected
        }

        let replacingKeys: [String] = activeSourcesByKey.compactMap { key, source in
            guard source.kind == .file else {
                return nil
            }
            return Self.folder(
                candidateComparisonURL,
                covers: URL(fileURLWithPath: key)
            ) ? key : nil
        }
        return .insert(replacingKeys: replacingKeys)
    }

    private func install(
        _ source: MediaSource,
        bookmark: Data,
        replacingKeys: [String]
    ) -> [URL] {
        let replacedURLs = replacingKeys.compactMap {
            activeSourcesByKey.removeValue(forKey: $0)?.url
        }
        for key in replacingKeys {
            activeRecordsByKey.removeValue(forKey: key)
            activeResourceIdentifiersByKey.removeValue(forKey: key)
        }
        let key = sourceKey(for: source.url)
        activeSourcesByKey[key] = source
        activeRecordsByKey[key] = PersistedSourceRecord(
            kind: source.kind,
            bookmark: bookmark
        )
        activeResourceIdentifiersByKey[key] = Self.resourceIdentifier(
            for: URL(fileURLWithPath: key)
        )
        return replacedURLs
    }

    private func activeKey(matching source: MediaSource) -> String? {
        let comparisonURL = Self.comparisonURL(for: source.url)
        if activeSourcesByKey[comparisonURL.path] != nil {
            return comparisonURL.path
        }
        guard let identifier = Self.resourceIdentifier(for: comparisonURL) else {
            return nil
        }
        return activeResourceIdentifiersByKey.first {
            $0.value.isEqual(identifier)
        }?.key
    }

    private func restore(
        _ candidate: RestoreCandidate,
        pendingLinkedCandidates: inout [PendingLinkedCandidate]
    ) {
        let record = candidate.record
        guard Self.bookmarkIsWithinPersistenceLimit(record.bookmark) else {
            preserveUnavailable(candidate)
            return
        }
        guard let resolvedBookmark = securityAccess.resolveBookmark(
            record.bookmark
        ), securityAccess.startAccess(resolvedBookmark.url) else {
            preserveUnavailable(candidate)
            return
        }

        let resolvedURL = resolvedBookmark.url
        let linkResolution = Self.linkResolution(for: resolvedURL)
        guard sourceKindResolver(linkResolution.targetURL) == record.kind,
              Self.isSupported(
                  kind: record.kind,
                  url: linkResolution.targetURL
              ) else {
            securityAccess.stopAccess(resolvedURL)
            preserveUnavailable(candidate)
            return
        }

        let refreshedCandidate = candidateByRefreshingBookmark(
            candidate,
            resolvedURL: resolvedURL
        )

        if linkResolution.didResolveLink {
            securityAccess.stopAccess(resolvedURL)
            pendingLinkedCandidates.append(
                PendingLinkedCandidate(
                    candidate: refreshedCandidate,
                    targetSource: MediaSource(
                        url: linkResolution.targetURL,
                        kind: record.kind
                    )
                )
            )
            return
        }

        let source = MediaSource(url: resolvedURL, kind: record.kind)
        switch disposition(for: source) {
        case .covered:
            securityAccess.stopAccess(resolvedURL)
        case .rejected:
            securityAccess.stopAccess(resolvedURL)
            preserveUnavailable(refreshedCandidate)
        case let .insert(replacingKeys):
            guard canInstallSource(replacingKeys: replacingKeys) else {
                securityAccess.stopAccess(resolvedURL)
                preserveUnavailable(refreshedCandidate)
                return
            }
            let replacedURLs = install(
                source,
                bookmark: refreshedCandidate.record.bookmark,
                replacingKeys: replacingKeys
            )
            for replacedURL in replacedURLs {
                securityAccess.stopAccess(replacedURL)
            }
        }
    }

    private func candidateByRefreshingBookmark(
        _ candidate: RestoreCandidate,
        resolvedURL: URL
    ) -> RestoreCandidate {
        // Refresh every successfully resolved persisted grant when the
        // current signing identity can create a replacement. A failed or
        // oversized refresh must not discard the still-working bookmark.
        guard let refreshedBookmark = securityAccess.makeBookmark(resolvedURL),
              Self.bookmarkIsWithinPersistenceLimit(refreshedBookmark) else {
            return candidate
        }
        let refreshedRecord = PersistedSourceRecord(
            kind: candidate.record.kind,
            bookmark: refreshedBookmark
        )
        let refreshedOrigin: RestoreOrigin = switch candidate.origin {
        case .typed:
            .typed(storedValue: refreshedRecord.storedValue)
        case .legacy:
            .legacy(bookmark: refreshedBookmark)
        }
        return RestoreCandidate(
            record: refreshedRecord,
            origin: refreshedOrigin
        )
    }

    private func playbackURL(for candidate: MediaSource) -> URL {
        let comparisonURL = Self.comparisonURL(for: candidate.url)
        if let exactSource = activeSourcesByKey[comparisonURL.path],
           exactSource.kind == .file {
            return exactSource.url
        }
        if let identifier = Self.resourceIdentifier(for: comparisonURL),
           let matchingKey = activeResourceIdentifiersByKey.first(where: {
               $0.value.isEqual(identifier)
           })?.key,
           let matchingSource = activeSourcesByKey[matchingKey],
           matchingSource.kind == .file {
            return matchingSource.url
        }
        return comparisonURL
    }

    private func preserveUnavailable(_ candidate: RestoreCandidate) {
        switch candidate.origin {
        case let .typed(storedValue):
            unavailableStoredRecordValues.append(storedValue)
        case let .legacy(bookmark):
            unavailableLegacyBookmarks.append(bookmark)
        }
        hasUnavailablePersistedSources = true
    }

    private func preserveUnavailableStoredRecord(_ storedValue: Any) {
        unavailableStoredRecordValues.append(storedValue)
        hasUnavailablePersistedSources = true
    }

    private func appendRequestedFileURL(
        _ url: URL,
        to urls: inout [URL],
        seenIDs: inout Set<LibraryMediaItem.ID>
    ) {
        let id = LibraryMediaItem.ID(mediaURL: url)
        if seenIDs.insert(id).inserted {
            urls.append(url.standardizedFileURL)
        }
    }

    private static func liveSourceKind(at url: URL) -> MediaSourceKind? {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else {
            return nil
        }
        if values.isDirectory == true {
            return .folder
        }
        if values.isRegularFile == true {
            return .file
        }
        return nil
    }

    private static func isSupported(
        kind: MediaSourceKind,
        url: URL
    ) -> Bool {
        kind == .folder
            || MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                url.pathExtension.lowercased()
            )
    }

    private static func bookmarkIsWithinPersistenceLimit(
        _ bookmark: Data
    ) -> Bool {
        bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount
    }

    private static func folder(
        _ directoryURL: URL,
        covers itemURL: URL
    ) -> Bool {
        return relationship(
            directoryURL: directoryURL,
            itemURL: itemURL
        ) != .other
    }

    private static func comparisonURL(for url: URL) -> URL {
        linkResolution(for: url).targetURL
    }

    private struct LinkResolution {
        let targetURL: URL
        let didResolveLink: Bool
    }

    private static func linkResolution(for url: URL) -> LinkResolution {
        let values = try? url.resourceValues(
            forKeys: [.isAliasFileKey, .isSymbolicLinkKey]
        )
        let isAlias = values?.isAliasFile == true
        let isSymbolicLink = values?.isSymbolicLink == true
        let aliasResolvedURL = if isAlias {
            (
                try? URL(
                    resolvingAliasFileAt: url,
                    options: [.withoutUI, .withoutMounting]
                )
            ) ?? url
        } else {
            url
        }

        return LinkResolution(
            targetURL: aliasResolvedURL
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            didResolveLink: isAlias || isSymbolicLink
        )
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
