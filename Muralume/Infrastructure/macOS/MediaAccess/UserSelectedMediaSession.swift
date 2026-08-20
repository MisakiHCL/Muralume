import Foundation

@MainActor
final class UserSelectedMediaSession: MediaAccessSession {
    typealias SourceRecordStore = @MainActor ([Any]) -> Void

    private enum Storage {
        static let legacyBookmarkKey = "media-library.root-bookmarks"
        static let sourceRecordKey = "media-library.source-records"
        static let currentSchemaVersion = 1

        enum RecordField {
            static let schemaVersion = "schemaVersion"
            static let kind = "kind"
            static let bookmark = "bookmark"
            static let identifier = "identifier"
            static let displayName = "displayName"
            static let lastKnownPath = "lastKnownPath"
        }
    }

    private struct PersistedSourceRecord {
        let schemaVersion: Int
        let kind: MediaSourceKind
        let bookmark: Data
        let identifier: String?
        let displayName: String?
        let lastKnownPath: String?

        init(
            kind: MediaSourceKind,
            bookmark: Data,
            identifier: String? = nil,
            displayName: String? = nil,
            lastKnownPath: String? = nil
        ) {
            schemaVersion = Storage.currentSchemaVersion
            self.kind = kind
            self.bookmark = bookmark
            self.identifier = identifier
            self.displayName = displayName
            self.lastKnownPath = lastKnownPath
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
            identifier = fields[Storage.RecordField.identifier] as? String
            displayName = fields[Storage.RecordField.displayName] as? String
            lastKnownPath = fields[Storage.RecordField.lastKnownPath] as? String
        }

        var storedValue: [String: Any] {
            var fields: [String: Any] = [
                Storage.RecordField.schemaVersion: schemaVersion,
                Storage.RecordField.kind: kind.rawValue,
                Storage.RecordField.bookmark: bookmark
            ]
            fields[Storage.RecordField.identifier] = identifier
            fields[Storage.RecordField.displayName] = displayName
            fields[Storage.RecordField.lastKnownPath] = lastKnownPath
            return fields
        }

        var unavailableSource: UnavailableMediaSource? {
            guard let identifier,
                  let displayName,
                  !displayName.isEmpty,
                  let lastKnownPath,
                  !lastKnownPath.isEmpty else {
                return nil
            }
            return UnavailableMediaSource(
                id: .init(rawValue: identifier),
                displayName: displayName,
                lastKnownURL: URL(
                    fileURLWithPath: lastKnownPath,
                    isDirectory: kind == .folder
                ),
                kind: kind
            )
        }

        func identified(at url: URL) -> PersistedSourceRecord {
            let standardizedURL = url.standardizedFileURL
            return PersistedSourceRecord(
                kind: kind,
                bookmark: bookmark,
                identifier: identifier ?? UUID().uuidString,
                displayName: standardizedURL.lastPathComponent,
                lastKnownPath: standardizedURL.path
            )
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
    private let sourceRecordStore: SourceRecordStore
    private let restoreExecutor: UserSelectedMediaRestoreExecutor?
    private var activeSourcesByKey: [String: MediaSource] = [:]
    private var activeRecordsByKey: [String: PersistedSourceRecord] = [:]
    private var activeResourceIdentifiersByKey: [String: NSObject] = [:]
    private var activeKeyByResourceIdentifier: [NSObject: String] = [:]
    private var activeFolderKeys: Set<String> = []
    private var unavailableStoredRecordValues: [Any] = []
    private var unavailableLegacyBookmarks: [Data] = []
    private var deferredStoredRecordValues: ArraySlice<Any> = []
    private var deferredLegacyBookmarks: ArraySlice<Data> = []
    private var asyncInFlightStoredRecordValues: ArraySlice<Any> = []
    private var asyncInFlightLegacyBookmarks: ArraySlice<Data> = []
    private var asyncPendingLinkedStoredRecordValues: [Any] = []
    private var asyncPendingLinkedLegacyBookmarks: [Data] = []
    private var asyncRestoreGeneration: UInt?
    private var didAttemptRestore = false
    private var lifecycleGeneration: UInt = 0
    private(set) var hasUnavailablePersistedSources = false

    var unavailablePersistedSources: [UnavailableMediaSource] {
        unavailableStoredRecordValues
            .compactMap(PersistedSourceRecord.init(storedValue:))
            .compactMap(\.unavailableSource)
            .reduce(into: [UnavailableMediaSource.ID: UnavailableMediaSource]()) {
                sourcesByID, source in
                sourcesByID[source.id] = source
            }
            .values
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
    }

    init(
        defaults: UserDefaults = .standard,
        securityAccess: SecurityScopedMediaAccess = .live,
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            MediaSourceURLInspector.liveSourceKind(at: $0)
        },
        sourceRecordStore: SourceRecordStore? = nil,
        restoreExecutor: UserSelectedMediaRestoreExecutor? = nil
    ) {
        self.defaults = defaults
        self.securityAccess = securityAccess
        self.sourceKindResolver = sourceKindResolver
        self.sourceRecordStore = sourceRecordStore ?? { storedValues in
            defaults.set(storedValues, forKey: Storage.sourceRecordKey)
        }
        self.restoreExecutor = restoreExecutor
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
        let hasPersistedSourcePayload =
            defaults.object(forKey: Storage.sourceRecordKey) != nil
                || defaults.object(forKey: Storage.legacyBookmarkKey) != nil
        guard hasPersistedSourcePayload else {
            return activeSources
        }
        restoreCandidates(
            storedRecordValues: storedRecordValues,
            legacyBookmarks: legacyBookmarks
        )
        storeSourceRecords(currentStoredRecordValues)
        storeLegacyBookmarks(currentLegacyBookmarks)
        return activeSources
    }

    func restoreSourcesAsync() async -> [MediaSource] {
        guard restoreExecutor != nil else {
            return restoreSources()
        }
        guard !didAttemptRestore else {
            return activeSources
        }
        didAttemptRestore = true

        let storedRecordValues = storedSourceRecordValues
        let legacyBookmarks = storedLegacyBookmarks
        let hasPersistedSourcePayload =
            defaults.object(forKey: Storage.sourceRecordKey) != nil
                || defaults.object(forKey: Storage.legacyBookmarkKey) != nil
        guard hasPersistedSourcePayload else {
            return activeSources
        }

        let restoreGeneration = lifecycleGeneration
        await restoreCandidatesAsync(
            storedRecordValues: storedRecordValues,
            legacyBookmarks: legacyBookmarks,
            generation: restoreGeneration
        )
        guard restoreGeneration == lifecycleGeneration else {
            return activeSources
        }
        storeSourceRecords(currentStoredRecordValues)
        storeLegacyBookmarks(currentLegacyBookmarks)
        return activeSources
    }

    func retryUnavailableSources() -> [MediaSource] {
        guard didAttemptRestore else {
            return restoreSources()
        }
        guard asyncRestoreGeneration == nil else {
            return activeSources
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

    func retryUnavailableSourcesAsync() async -> [MediaSource] {
        guard restoreExecutor != nil else {
            return retryUnavailableSources()
        }
        guard didAttemptRestore else {
            return await restoreSourcesAsync()
        }
        guard asyncRestoreGeneration == nil else {
            return activeSources
        }
        guard hasUnavailablePersistedSources else {
            return activeSources
        }

        let storedRecordValues = Array(deferredStoredRecordValues)
            + unavailableStoredRecordValues
        let legacyBookmarks = Array(deferredLegacyBookmarks)
            + unavailableLegacyBookmarks

        let restoreGeneration = lifecycleGeneration
        await restoreCandidatesAsync(
            storedRecordValues: storedRecordValues,
            legacyBookmarks: legacyBookmarks,
            generation: restoreGeneration
        )
        guard restoreGeneration == lifecycleGeneration else {
            return activeSources
        }
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

    private func restoreCandidatesAsync(
        storedRecordValues: [Any],
        legacyBookmarks: [Data],
        generation: UInt
    ) async {
        guard generation == lifecycleGeneration else {
            return
        }
        guard asyncRestoreGeneration == nil else {
            return
        }
        asyncRestoreGeneration = generation
        asyncInFlightStoredRecordValues = storedRecordValues[...]
        asyncInFlightLegacyBookmarks = legacyBookmarks[...]
        asyncPendingLinkedStoredRecordValues = []
        asyncPendingLinkedLegacyBookmarks = []
        unavailableStoredRecordValues = []
        unavailableLegacyBookmarks = []
        deferredStoredRecordValues = []
        deferredLegacyBookmarks = []
        refreshHasUnavailablePersistedSources()
        var pendingLinkedCandidates: [PendingLinkedCandidate] = []
        var remainingRestoreCandidateCount =
            MediaImportPolicy.maximumRestoredSourceRecordCount

        for storedValue in storedRecordValues {
            guard generation == lifecycleGeneration else {
                return
            }
            guard !Task.isCancelled else {
                interruptAsyncRestore(
                    pendingLinkedCandidates: pendingLinkedCandidates,
                    generation: generation
                )
                return
            }
            let shouldReserveLegacyCandidate =
                !legacyBookmarks.isEmpty
                && activeSourcesByKey.count
                    < MediaImportPolicy.maximumActiveSourceCount
                && remainingRestoreCandidateCount
                    == MediaImportPolicy.reservedLegacyRestoreCandidateCount
            guard !shouldReserveLegacyCandidate else {
                deferAsyncInFlightStoredCandidates()
                hasUnavailablePersistedSources = true
                break
            }
            guard remainingRestoreCandidateCount > 0 else {
                deferAsyncInFlightStoredCandidates()
                hasUnavailablePersistedSources = true
                break
            }
            remainingRestoreCandidateCount -= 1
            guard let record = PersistedSourceRecord(
                storedValue: storedValue
            ) else {
                preserveUnavailableStoredRecord(storedValue)
                advanceAsyncInFlightStoredCandidate()
                continue
            }
            let pendingLinkedCandidateCount = pendingLinkedCandidates.count
            let didProcessCandidate = await restoreAsync(
                RestoreCandidate(
                    record: record,
                    origin: .typed(storedValue: storedValue)
                ),
                pendingLinkedCandidates: &pendingLinkedCandidates,
                generation: generation
            )
            guard generation == lifecycleGeneration else {
                return
            }
            guard didProcessCandidate else {
                interruptAsyncRestore(
                    pendingLinkedCandidates: pendingLinkedCandidates,
                    generation: generation
                )
                return
            }
            registerAsyncPendingLinkedCandidates(
                pendingLinkedCandidates.dropFirst(pendingLinkedCandidateCount)
            )
            advanceAsyncInFlightStoredCandidate()
        }

        for bookmark in legacyBookmarks {
            guard generation == lifecycleGeneration else {
                return
            }
            guard !Task.isCancelled else {
                interruptAsyncRestore(
                    pendingLinkedCandidates: pendingLinkedCandidates,
                    generation: generation
                )
                return
            }
            guard remainingRestoreCandidateCount > 0 else {
                deferAsyncInFlightLegacyCandidates()
                hasUnavailablePersistedSources = true
                break
            }
            remainingRestoreCandidateCount -= 1
            let pendingLinkedCandidateCount = pendingLinkedCandidates.count
            let didProcessCandidate = await restoreAsync(
                RestoreCandidate(
                    record: PersistedSourceRecord(
                        kind: .folder,
                        bookmark: bookmark
                    ),
                    origin: .legacy(bookmark: bookmark)
                ),
                pendingLinkedCandidates: &pendingLinkedCandidates,
                generation: generation
            )
            guard generation == lifecycleGeneration else {
                return
            }
            guard didProcessCandidate else {
                interruptAsyncRestore(
                    pendingLinkedCandidates: pendingLinkedCandidates,
                    generation: generation
                )
                return
            }
            registerAsyncPendingLinkedCandidates(
                pendingLinkedCandidates.dropFirst(pendingLinkedCandidateCount)
            )
            advanceAsyncInFlightLegacyCandidate()
        }

        preserveUncoveredLinkedCandidates(pendingLinkedCandidates)
        finishAsyncRestore(generation: generation)
    }

    private func interruptAsyncRestore(
        pendingLinkedCandidates: [PendingLinkedCandidate],
        generation: UInt
    ) {
        guard asyncRestoreGeneration == generation else {
            return
        }
        deferAsyncInFlightStoredCandidates()
        deferAsyncInFlightLegacyCandidates()
        if !deferredStoredRecordValues.isEmpty
            || !deferredLegacyBookmarks.isEmpty {
            hasUnavailablePersistedSources = true
        }
        preserveUncoveredLinkedCandidates(pendingLinkedCandidates)
        finishAsyncRestore(generation: generation)
    }

    private func registerAsyncPendingLinkedCandidates(
        _ candidates: ArraySlice<PendingLinkedCandidate>
    ) {
        for pending in candidates {
            switch pending.candidate.origin {
            case let .typed(storedValue):
                asyncPendingLinkedStoredRecordValues.append(storedValue)
            case let .legacy(bookmark):
                asyncPendingLinkedLegacyBookmarks.append(bookmark)
            }
        }
    }

    private func advanceAsyncInFlightStoredCandidate() {
        precondition(!asyncInFlightStoredRecordValues.isEmpty)
        asyncInFlightStoredRecordValues =
            asyncInFlightStoredRecordValues.dropFirst()
        refreshHasUnavailablePersistedSources()
    }

    private func advanceAsyncInFlightLegacyCandidate() {
        precondition(!asyncInFlightLegacyBookmarks.isEmpty)
        asyncInFlightLegacyBookmarks =
            asyncInFlightLegacyBookmarks.dropFirst()
        refreshHasUnavailablePersistedSources()
    }

    private func deferAsyncInFlightStoredCandidates() {
        guard !asyncInFlightStoredRecordValues.isEmpty else {
            return
        }
        deferredStoredRecordValues = ArraySlice(
            Array(deferredStoredRecordValues)
                + Array(asyncInFlightStoredRecordValues)
        )
        asyncInFlightStoredRecordValues = []
        refreshHasUnavailablePersistedSources()
    }

    private func deferAsyncInFlightLegacyCandidates() {
        guard !asyncInFlightLegacyBookmarks.isEmpty else {
            return
        }
        deferredLegacyBookmarks = ArraySlice(
            Array(deferredLegacyBookmarks)
                + Array(asyncInFlightLegacyBookmarks)
        )
        asyncInFlightLegacyBookmarks = []
        refreshHasUnavailablePersistedSources()
    }

    private func finishAsyncRestore(generation: UInt) {
        guard asyncRestoreGeneration == generation else {
            return
        }
        precondition(asyncInFlightStoredRecordValues.isEmpty)
        precondition(asyncInFlightLegacyBookmarks.isEmpty)
        asyncPendingLinkedStoredRecordValues.removeAll()
        asyncPendingLinkedLegacyBookmarks.removeAll()
        asyncRestoreGeneration = nil
        refreshHasUnavailablePersistedSources()
    }

    private func refreshHasUnavailablePersistedSources() {
        hasUnavailablePersistedSources =
            !unavailableStoredRecordValues.isEmpty
                || !unavailableLegacyBookmarks.isEmpty
                || !deferredStoredRecordValues.isEmpty
                || !deferredLegacyBookmarks.isEmpty
                || !asyncInFlightStoredRecordValues.isEmpty
                || !asyncInFlightLegacyBookmarks.isEmpty
                || !asyncPendingLinkedStoredRecordValues.isEmpty
                || !asyncPendingLinkedLegacyBookmarks.isEmpty
    }

    private func preserveUncoveredLinkedCandidates(
        _ pendingLinkedCandidates: [PendingLinkedCandidate]
    ) {
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
        addSources(urls, incomingScopePolicy: .sessionManaged)
    }

    func addSources(
        _ urls: [URL],
        incomingScopePolicy: MediaAccessIncomingScopePolicy
    ) -> MediaAccessUpdate {
        _ = restoreSources()
        var requestedFileURLs: [URL] = []
        var requestedFileIDs: Set<LibraryMediaItem.ID> = []
        var acceptedRequestCount = 0
        var rejectedRequestCount = 0
        var actionableRejectionCounts: [MediaAccessRejectionReason: Int] = [:]
        var didChangeSources = false
        var hasUnpersistedSourceChanges = false

        func recordRejection(
            _ reason: MediaAccessRejectionReason? = nil
        ) {
            rejectedRequestCount += 1
            if let reason {
                actionableRejectionCounts[reason, default: 0] += 1
            }
        }

        for (requestIndex, selectedURL) in urls.enumerated() {
            // URLs returned by NSOpenPanel already hold an implicit Powerbox
            // security scope. The default policy relinquishes that grant after
            // converting it into the persistent bookmark used by this session.
            defer {
                if incomingScopePolicy == .sessionManaged {
                    securityAccess.stopAccess(selectedURL)
                }
            }

            guard requestIndex < MediaImportPolicy.maximumTopLevelSourceCount else {
                recordRejection()
                continue
            }

            let selectedLinkResolution = MediaSourceURLInspector.linkResolution(
                for: selectedURL
            )
            guard let selectedKind = sourceKindResolver(
                selectedLinkResolution.targetURL
            ) else {
                recordRejection()
                continue
            }
            guard MediaSourceURLInspector.isSupported(
                kind: selectedKind,
                url: selectedLinkResolution.targetURL
            ) else {
                recordRejection(.unsupportedFileFormat)
                continue
            }
            let selectedSource = MediaSource(
                url: selectedLinkResolution.didResolveLink
                    ? selectedLinkResolution.targetURL
                    : selectedURL,
                kind: selectedKind
            )
            let selectedComparisonURL = selectedLinkResolution.targetURL
                .standardizedFileURL
            let selectedDisposition = disposition(
                for: selectedSource,
                comparisonURL: selectedComparisonURL,
                resourceIdentifier: MediaSourceURLInspector.resourceIdentifier(
                    for: selectedComparisonURL
                )
            )
            if selectedLinkResolution.didResolveLink {
                if case .covered = selectedDisposition {
                    acceptedRequestCount += 1
                    if selectedKind == .file {
                        appendRequestedFileURL(
                            playbackURL(for: selectedSource),
                            to: &requestedFileURLs,
                            seenIDs: &requestedFileIDs
                        )
                    }
                } else {
                    recordRejection()
                }
                continue
            }
            switch selectedDisposition {
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
            case let .rejected(reason):
                recordRejection(reason)
                continue
            case let .insert(replacingKeys):
                guard canInstallSource(replacingKeys: replacingKeys) else {
                    recordRejection()
                    continue
                }
            }

            guard let bookmark = securityAccess.makeBookmark(selectedURL),
                  Self.bookmarkIsWithinPersistenceLimit(bookmark),
                  let resolvedBookmark = securityAccess.resolveBookmark(bookmark),
                  securityAccess.startAccess(resolvedBookmark.url) else {
                recordRejection()
                continue
            }

            let resolvedURL = resolvedBookmark.url
            let resolvedLinkResolution = MediaSourceURLInspector.linkResolution(
                for: resolvedURL
            )
            guard let resolvedKind = sourceKindResolver(
                resolvedLinkResolution.targetURL
            ) else {
                securityAccess.stopAccess(resolvedURL)
                recordRejection()
                continue
            }
            guard MediaSourceURLInspector.isSupported(
                kind: resolvedKind,
                url: resolvedLinkResolution.targetURL
            ) else {
                securityAccess.stopAccess(resolvedURL)
                recordRejection(.unsupportedFileFormat)
                continue
            }
            let resolvedSource = MediaSource(
                url: resolvedLinkResolution.didResolveLink
                    ? resolvedLinkResolution.targetURL
                    : resolvedURL,
                kind: resolvedKind
            )
            let resolvedComparisonURL = resolvedLinkResolution.targetURL
                .standardizedFileURL
            let resolvedResourceIdentifier = MediaSourceURLInspector
                .resourceIdentifier(
                for: resolvedComparisonURL
            )
            if resolvedLinkResolution.didResolveLink {
                securityAccess.stopAccess(resolvedURL)
                let linkedDisposition = disposition(
                    for: resolvedSource,
                    comparisonURL: resolvedComparisonURL,
                    resourceIdentifier: resolvedResourceIdentifier
                )
                if case .covered = linkedDisposition {
                    acceptedRequestCount += 1
                    if resolvedKind == .file {
                        appendRequestedFileURL(
                            playbackURL(for: resolvedSource),
                            to: &requestedFileURLs,
                            seenIDs: &requestedFileIDs
                        )
                    }
                } else {
                    recordRejection()
                }
                continue
            }
            let resolvedDisposition = disposition(
                for: resolvedSource,
                comparisonURL: resolvedComparisonURL,
                resourceIdentifier: resolvedResourceIdentifier
            )
            if case let .rejected(reason) = resolvedDisposition {
                securityAccess.stopAccess(resolvedURL)
                recordRejection(reason)
                continue
            }
            if case let .insert(replacingKeys) = resolvedDisposition,
               !canInstallSource(replacingKeys: replacingKeys) {
                securityAccess.stopAccess(resolvedURL)
                recordRejection()
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
                    recordRejection()
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
                    replacingKeys: replacingKeys,
                    resourceIdentifier: resolvedResourceIdentifier
                )
                hasUnpersistedSourceChanges = true
                // A replacement is the one mid-batch durability barrier: the
                // broader grant must be persisted before exact-file scopes are
                // relinquished. Ordinary additions are stored once below.
                if !replacedURLs.isEmpty {
                    storeSourceRecords(currentStoredRecordValues)
                    hasUnpersistedSourceChanges = false
                }
                for replacedURL in replacedURLs {
                    securityAccess.stopAccess(replacedURL)
                }
                didChangeSources = true
            }
        }

        if hasUnpersistedSourceChanges {
            storeSourceRecords(currentStoredRecordValues)
        }

        return MediaAccessUpdate(
            activeSources: activeSources,
            requestedFileURLs: requestedFileURLs,
            acceptedRequestCount: acceptedRequestCount,
            rejectedRequestCount: rejectedRequestCount,
            actionableRejectionCounts: actionableRejectionCounts,
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
        removeIndexes(forActiveKey: activeKey)
        securityAccess.stopAccess(activeSource.url)
        return activeSources
    }

    func removeFolder(_ url: URL) -> [URL] {
        removeSource(MediaSource(url: url, kind: .folder)).compactMap { source in
            source.kind == .folder ? source.url : nil
        }
    }

    func removeUnavailableSource(_ source: UnavailableMediaSource) {
        unavailableStoredRecordValues.removeAll { storedValue in
            PersistedSourceRecord(storedValue: storedValue)?
                .unavailableSource?.id == source.id
        }
        storeSourceRecords(currentStoredRecordValues)
        refreshHasUnavailablePersistedSources()
    }

    func stop() {
        lifecycleGeneration &+= 1
        for source in activeSourcesByKey.values {
            securityAccess.stopAccess(source.url)
        }
        activeSourcesByKey.removeAll()
        activeRecordsByKey.removeAll()
        activeResourceIdentifiersByKey.removeAll()
        activeKeyByResourceIdentifier.removeAll()
        activeFolderKeys.removeAll()
        unavailableStoredRecordValues.removeAll()
        unavailableLegacyBookmarks.removeAll()
        deferredStoredRecordValues.removeAll()
        deferredLegacyBookmarks.removeAll()
        asyncInFlightStoredRecordValues.removeAll()
        asyncInFlightLegacyBookmarks.removeAll()
        asyncPendingLinkedStoredRecordValues.removeAll()
        asyncPendingLinkedLegacyBookmarks.removeAll()
        asyncRestoreGeneration = nil
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
                + asyncInFlightStoredRecordValues.count
                + asyncPendingLinkedStoredRecordValues.count
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
        storedValues.append(contentsOf: asyncInFlightStoredRecordValues)
        storedValues.append(contentsOf: asyncPendingLinkedStoredRecordValues)
        storedValues.append(contentsOf: unavailableStoredRecordValues)
        return storedValues
    }

    private var currentLegacyBookmarks: [Data] {
        var bookmarks: [Data] = []
        bookmarks.reserveCapacity(
            deferredLegacyBookmarks.count
                + asyncInFlightLegacyBookmarks.count
                + asyncPendingLinkedLegacyBookmarks.count
                + unavailableLegacyBookmarks.count
        )
        bookmarks.append(contentsOf: deferredLegacyBookmarks)
        bookmarks.append(contentsOf: asyncInFlightLegacyBookmarks)
        bookmarks.append(contentsOf: asyncPendingLinkedLegacyBookmarks)
        bookmarks.append(contentsOf: unavailableLegacyBookmarks)
        return bookmarks
    }

    private func sourceKey(for url: URL) -> String {
        Self.comparisonURL(for: url).path
    }

    private func storeSourceRecords(_ storedValues: [Any]) {
        sourceRecordStore(storedValues)
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
        case rejected(MediaAccessRejectionReason)
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
        return disposition(
            for: candidate,
            comparisonURL: candidateComparisonURL,
            resourceIdentifier: MediaSourceURLInspector.resourceIdentifier(
                for: candidateComparisonURL
            )
        )
    }

    private func disposition(
        for candidate: MediaSource,
        comparisonURL candidateComparisonURL: URL,
        resourceIdentifier candidateIdentifier: NSObject?
    ) -> SourceDisposition {
        let candidateKey = candidateComparisonURL.path
        if activeSourcesByKey[candidateKey] != nil {
            return .covered
        }
        if let candidateIdentifier,
           activeKeyByResourceIdentifier[candidateIdentifier] != nil {
            return .covered
        }

        guard candidate.kind == .folder else {
            if activeFolderKeys.contains(where: { key in
                Self.folder(
                    URL(fileURLWithPath: key, isDirectory: true),
                    covers: candidateComparisonURL
                )
            }) {
                return .covered
            }
            return .insert(replacingKeys: [])
        }

        for key in activeFolderKeys {
            let activeFolderURL = URL(
                fileURLWithPath: key,
                isDirectory: true
            )
            if Self.folder(activeFolderURL, covers: candidateComparisonURL) {
                return .rejected(.activeFolderContainsSelectedFolder)
            }
            if Self.folder(candidateComparisonURL, covers: activeFolderURL) {
                return .rejected(.selectedFolderContainsActiveFolder)
            }
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
        replacingKeys: [String],
        resourceIdentifier: NSObject?,
        persistedRecord: PersistedSourceRecord? = nil
    ) -> [URL] {
        let replacedURLs = replacingKeys.compactMap {
            activeSourcesByKey.removeValue(forKey: $0)?.url
        }
        for key in replacingKeys {
            activeRecordsByKey.removeValue(forKey: key)
            removeIndexes(forActiveKey: key)
        }
        let key = sourceKey(for: source.url)
        activeSourcesByKey[key] = source
        activeRecordsByKey[key] = (
            persistedRecord
                ?? PersistedSourceRecord(
                    kind: source.kind,
                    bookmark: bookmark
                )
        ).identified(at: source.url)
        if source.kind == .folder {
            activeFolderKeys.insert(key)
        }
        if let identifier = resourceIdentifier {
            activeResourceIdentifiersByKey[key] = identifier
            activeKeyByResourceIdentifier[identifier] = key
        }
        return replacedURLs
    }

    private func removeIndexes(forActiveKey key: String) {
        activeFolderKeys.remove(key)
        guard let identifier = activeResourceIdentifiersByKey.removeValue(
            forKey: key
        ) else {
            return
        }
        if activeKeyByResourceIdentifier[identifier] == key {
            activeKeyByResourceIdentifier[identifier] = nil
        }
    }

    private func activeKey(matching source: MediaSource) -> String? {
        let comparisonURL = Self.comparisonURL(for: source.url)
        if activeSourcesByKey[comparisonURL.path] != nil {
            return comparisonURL.path
        }
        guard let identifier = MediaSourceURLInspector.resourceIdentifier(
            for: comparisonURL
        ) else {
            return nil
        }
        return activeKeyByResourceIdentifier[identifier]
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
        let linkResolution = MediaSourceURLInspector.linkResolution(
            for: resolvedURL
        )
        guard sourceKindResolver(linkResolution.targetURL) == record.kind,
              MediaSourceURLInspector.isSupported(
                  kind: record.kind,
                  url: linkResolution.targetURL
              ) else {
            securityAccess.stopAccess(resolvedURL)
            preserveUnavailable(candidate)
            return
        }

        let refreshedBookmark = securityAccess.makeBookmark(resolvedURL)
            .flatMap { bookmark in
                Self.bookmarkIsWithinPersistenceLimit(bookmark)
                    ? bookmark
                    : nil
            }
        applyPreparedRestore(
            PreparedMediaSourceRestore(
                resolvedURL: resolvedURL,
                linkResolution: linkResolution,
                refreshedBookmark: refreshedBookmark,
                resourceIdentifier: MediaSourceURLInspector.resourceIdentifier(
                    for: linkResolution.targetURL.standardizedFileURL
                )
            ),
            to: candidate,
            pendingLinkedCandidates: &pendingLinkedCandidates
        )
    }

    private func restoreAsync(
        _ candidate: RestoreCandidate,
        pendingLinkedCandidates: inout [PendingLinkedCandidate],
        generation: UInt
    ) async -> Bool {
        let record = candidate.record
        guard Self.bookmarkIsWithinPersistenceLimit(record.bookmark),
              let restoreExecutor else {
            preserveUnavailable(candidate)
            return true
        }

        guard generation == lifecycleGeneration, !Task.isCancelled else {
            return false
        }
        let preparation = await restoreExecutor.prepare(
            kind: record.kind,
            bookmark: record.bookmark
        )
        guard generation == lifecycleGeneration, !Task.isCancelled else {
            if case let .resolved(preparedRestore) = preparation {
                preparedRestore.closeScopeIfOwned()
            }
            return false
        }

        switch preparation {
        case .unavailable:
            preserveUnavailable(candidate)
        case let .resolved(executorOwnedRestore):
            applyPreparedRestore(
                executorOwnedRestore.restore,
                to: candidate,
                pendingLinkedCandidates: &pendingLinkedCandidates,
                executorOwnedRestore: executorOwnedRestore
            )
        }
        return true
    }

    private func applyPreparedRestore(
        _ preparedRestore: PreparedMediaSourceRestore,
        to candidate: RestoreCandidate,
        pendingLinkedCandidates: inout [PendingLinkedCandidate],
        executorOwnedRestore: ExecutorOwnedPreparedMediaSourceRestore? = nil
    ) {
        let record = candidate.record
        let resolvedURL = preparedRestore.resolvedURL
        let linkResolution = preparedRestore.linkResolution
        let refreshedCandidate = candidateByReplacingBookmark(
            candidate,
            replacingBookmarkWith: preparedRestore.refreshedBookmark
        )

        if linkResolution.didResolveLink {
            closePreparedScope(
                at: resolvedURL,
                executorOwnedRestore: executorOwnedRestore
            )
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
        let comparisonURL = linkResolution.targetURL.standardizedFileURL
        switch disposition(
            for: source,
            comparisonURL: comparisonURL,
            resourceIdentifier: preparedRestore.resourceIdentifier
        ) {
        case .covered:
            closePreparedScope(
                at: resolvedURL,
                executorOwnedRestore: executorOwnedRestore
            )
        case .rejected:
            closePreparedScope(
                at: resolvedURL,
                executorOwnedRestore: executorOwnedRestore
            )
            preserveUnavailable(refreshedCandidate)
        case let .insert(replacingKeys):
            guard canInstallSource(replacingKeys: replacingKeys) else {
                closePreparedScope(
                    at: resolvedURL,
                    executorOwnedRestore: executorOwnedRestore
                )
                preserveUnavailable(refreshedCandidate)
                return
            }
            let replacedURLs = install(
                source,
                bookmark: refreshedCandidate.record.bookmark,
                replacingKeys: replacingKeys,
                resourceIdentifier: preparedRestore.resourceIdentifier,
                persistedRecord: refreshedCandidate.record
            )
            executorOwnedRestore?.transferScopeToSession()
            for replacedURL in replacedURLs {
                securityAccess.stopAccess(replacedURL)
            }
        }
    }

    private func closePreparedScope(
        at resolvedURL: URL,
        executorOwnedRestore: ExecutorOwnedPreparedMediaSourceRestore?
    ) {
        if let executorOwnedRestore {
            executorOwnedRestore.closeScopeIfOwned()
        } else {
            securityAccess.stopAccess(resolvedURL)
        }
    }

    private func candidateByReplacingBookmark(
        _ candidate: RestoreCandidate,
        replacingBookmarkWith refreshedBookmark: Data?
    ) -> RestoreCandidate {
        // Refresh every successfully resolved persisted grant when the
        // current signing identity can create a replacement. A failed or
        // oversized refresh must not discard the still-working bookmark.
        guard let refreshedBookmark else {
            return candidate
        }
        let refreshedRecord = PersistedSourceRecord(
            kind: candidate.record.kind,
            bookmark: refreshedBookmark,
            identifier: candidate.record.identifier,
            displayName: candidate.record.displayName,
            lastKnownPath: candidate.record.lastKnownPath
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
        if let identifier = MediaSourceURLInspector.resourceIdentifier(
            for: comparisonURL
        ),
           let matchingKey = activeKeyByResourceIdentifier[identifier],
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
        MediaSourceURLInspector.linkResolution(for: url).targetURL
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
