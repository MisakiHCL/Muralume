import XCTest
@testable import Muralume

@MainActor
final class UserSelectedMediaSessionTests: XCTestCase {
    private enum TestStorage {
        static let suiteName = "com.muralume.tests.media-session"
        static let legacyBookmarkKey = "media-library.root-bookmarks"
        static let sourceRecordKey = "media-library.source-records"
        static let schemaVersion = 1

        enum RecordField {
            static let schemaVersion = "schemaVersion"
            static let kind = "kind"
            static let bookmark = "bookmark"
        }
    }

    private struct StoredSourceRecord: Hashable {
        let schemaVersion: Int
        let kind: MediaSourceKind
        let bookmark: Data

        init(
            schemaVersion: Int = TestStorage.schemaVersion,
            kind: MediaSourceKind,
            bookmark: Data
        ) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        init?(storedValue: Any) {
            guard let fields = storedValue as? [String: Any],
                  let schemaVersion = fields[
                      TestStorage.RecordField.schemaVersion
                  ] as? Int,
                  schemaVersion == TestStorage.schemaVersion,
                  let rawKind = fields[
                      TestStorage.RecordField.kind
                  ] as? String,
                  let kind = MediaSourceKind(rawValue: rawKind),
                  let bookmark = fields[
                      TestStorage.RecordField.bookmark
                  ] as? Data else {
                return nil
            }
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        var storedValue: [String: Any] {
            [
                TestStorage.RecordField.schemaVersion: schemaVersion,
                TestStorage.RecordField.kind: kind.rawValue,
                TestStorage.RecordField.bookmark: bookmark
            ]
        }
    }

    func testSelectedScopeIsReleasedAndResolvedScopeUsesExactURLUntilStop() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let selectedURL = URL(
            fileURLWithPath: "/tmp/Muralume Selected \(UUID().uuidString)",
            isDirectory: true
        )
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Muralume Scope/../Resolved \(UUID().uuidString)",
            isDirectory: true
        )
        fixture.recorder.resolvedURLByBookmark[
            fixture.recorder.bookmark(for: selectedURL)
        ] = resolvedURL

        let activeURLs = fixture.session.addFolders([selectedURL])

        XCTAssertEqual(activeURLs, [resolvedURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [resolvedURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [selectedURL])

        fixture.session.stop()

        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [selectedURL, resolvedURL]
        )
        XCTAssertNotEqual(resolvedURL, resolvedURL.standardizedFileURL)
    }

    func testCallerManagedScopesRemainCallerOwnedAcrossPartialFailure() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let selectedURL = URL(
            fileURLWithPath: "/tmp/Caller Managed \(UUID().uuidString)",
            isDirectory: true
        )
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Persisted Scope \(UUID().uuidString)",
            isDirectory: true
        )
        let rejectedURL = URL(
            fileURLWithPath: "/tmp/Rejected Scope \(UUID().uuidString)",
            isDirectory: true
        )
        fixture.recorder.resolvedURLByBookmark[
            fixture.recorder.bookmark(for: selectedURL)
        ] = resolvedURL

        let update = fixture.session.addSources(
            [selectedURL, rejectedURL],
            incomingScopePolicy: .callerManaged
        )

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: resolvedURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertEqual(fixture.recorder.startedURLs, [resolvedURL])
        XCTAssertTrue(fixture.recorder.stoppedURLs.isEmpty)

        fixture.session.stop()

        XCTAssertEqual(fixture.recorder.stoppedURLs, [resolvedURL])
    }

    func testSingleFileUsesAnExactBookmarkAndReturnsPlaybackIntent() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Selected.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL

        let update = fixture.session.addSources([fileURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertEqual(update.requestedFileURLs, [fileURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertTrue(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [fileURL])
        XCTAssertNotEqual(
            fixture.recorder.bookmarkedURLs.first,
            fileURL.deletingLastPathComponent()
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])

        fixture.session.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL, fileURL])
    }

    func testTypedFileRecordRestoresAsFileAcrossSessions() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Persisted.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL

        _ = fixture.session.addSources([fileURL])
        fixture.session.stop()

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        XCTAssertEqual(
            restoredSession.restoreSources(),
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertFalse(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .file, bookmark: bookmark)]
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )

        restoredSession.stop()
    }

    func testAsyncRestoreAppliesPreparedScopeAndPersistsRecord() async {
        let bookmark = Data("async-restore".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Async Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            preparedBookmark in
            XCTAssertEqual(kind, .folder)
            XCTAssertEqual(preparedBookmark, bookmark)
            return .resolved(
                ExecutorOwnedPreparedMediaSourceRestore(
                    restore: PreparedMediaSourceRestore(
                        resolvedURL: resolvedURL,
                        linkResolution: MediaSourceURLInspector.LinkResolution(
                            targetURL: resolvedURL.standardizedFileURL,
                            didResolveLink: false
                        ),
                        refreshedBookmark: nil,
                        resourceIdentifier: nil
                    ),
                    stopAccess: { _ in }
                )
            )
        }
        let fixture = makeSessionFixture(
            restoreExecutor: restoreExecutor
        )
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: bookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )

        let restoredSources = await fixture.session.restoreSourcesAsync()

        XCTAssertEqual(
            restoredSources,
            [MediaSource(url: resolvedURL, kind: .folder)]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: bookmark)]
        )
        fixture.session.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [resolvedURL])
    }

    func testAsyncRestoreCancellationStopsBeforeNextCandidateAndClosesScope()
        async
    {
        let firstBookmark = Data("cancel-first".utf8)
        let secondBookmark = Data("cancel-second".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Cancelled Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            bookmark in
            await controller.prepare(kind: kind, bookmark: bookmark)
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        let storedRecords = [firstBookmark, secondBookmark].map {
            StoredSourceRecord(kind: .folder, bookmark: $0).storedValue
        }
        fixture.defaults.set(
            storedRecords,
            forKey: TestStorage.sourceRecordKey
        )

        let restoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        restoreTask.cancel()
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: resolvedURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let restoredSources = await restoreTask.value
        let callCount = await controller.callCount
        let preparedBookmarks = await controller.bookmarks
        XCTAssertTrue(restoredSources.isEmpty)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(preparedBookmarks, [firstBookmark])
        XCTAssertEqual(scopeCloseRecorder.urls, [resolvedURL])
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(kind: .folder, bookmark: firstBookmark),
                StoredSourceRecord(kind: .folder, bookmark: secondBookmark)
            ]
        )
    }

    func testDetachedRestoreCancellationReturnsBeforeNonCooperativeResolver()
        async
    {
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Late Detached Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let resolver = NonCooperativeRestoreResolver(
            resolvedURL: resolvedURL,
            scopeCloseRecorder: scopeCloseRecorder
        )
        let restoreExecutor = UserSelectedMediaRestoreExecutor.detached {
            kind,
            bookmark in
            resolver.prepare(kind: kind, bookmark: bookmark)
        }
        let returnedPromptly = expectation(
            description: "cancelled detached restore returned promptly"
        )
        let preparationTask = Task { @MainActor in
            let result = await restoreExecutor.prepare(
                kind: .folder,
                bookmark: Data("blocked-resolver".utf8)
            )
            returnedPromptly.fulfill()
            return result
        }
        await Task.detached {
            resolver.waitUntilStarted()
        }.value

        preparationTask.cancel()
        await fulfillment(of: [returnedPromptly], timeout: 0.5)
        resolver.release()
        let result = await preparationTask.value
        guard case .unavailable = result else {
            if case let .resolved(preparedRestore) = result {
                preparedRestore.closeScopeIfOwned()
            }
            XCTFail("A cancelled detached restore must not publish a result")
            return
        }

        for _ in 0..<100 where scopeCloseRecorder.urls.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scopeCloseRecorder.urls, [resolvedURL])
    }

    func testDetachedRestoreRetryJoinsCancelledWorkerForSameBookmark()
        async
    {
        let bookmark = Data("coalesced-blocked-resolver".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Coalesced Detached Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let resolver = NonCooperativeRestoreResolver(
            resolvedURL: resolvedURL,
            scopeCloseRecorder: scopeCloseRecorder
        )
        let restoreExecutor = UserSelectedMediaRestoreExecutor.detached {
            kind,
            preparedBookmark in
            resolver.prepare(kind: kind, bookmark: preparedBookmark)
        }
        let cancelledPreparation = Task { @MainActor in
            await restoreExecutor.prepare(kind: .folder, bookmark: bookmark)
        }
        await Task.detached {
            resolver.waitUntilStarted()
        }.value

        cancelledPreparation.cancel()
        guard case .unavailable = await cancelledPreparation.value else {
            XCTFail("A cancelled preparation must return unavailable")
            resolver.release()
            return
        }

        let joinedPreparation = Task { @MainActor in
            await restoreExecutor.prepare(kind: .folder, bookmark: bookmark)
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(resolver.startedCount, 1)

        resolver.release()
        let joinedResult = await joinedPreparation.value
        guard case let .resolved(preparedRestore) = joinedResult else {
            XCTFail("The joined retry must receive the existing worker result")
            return
        }
        preparedRestore.closeScopeIfOwned()

        XCTAssertEqual(resolver.startedCount, 1)
        XCTAssertEqual(scopeCloseRecorder.urls, [resolvedURL])
    }

    func testDetachedRestoreRetryDoesNotInheritWorkerCancellation()
        async
    {
        let bookmark = Data("cancelled-worker-retry".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Detached Retry \(UUID().uuidString)",
            isDirectory: true
        )
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let resolver = CancelledThenResolvedRestoreResolver(
            resolvedURL: resolvedURL,
            scopeCloseRecorder: scopeCloseRecorder
        )
        let restoreExecutor = UserSelectedMediaRestoreExecutor.detached {
            kind,
            preparedBookmark in
            resolver.prepare(kind: kind, bookmark: preparedBookmark)
        }
        let cancelledPreparation = Task { @MainActor in
            await restoreExecutor.prepare(kind: .folder, bookmark: bookmark)
        }
        await Task.detached {
            resolver.waitUntilFirstPreparationStarted()
        }.value

        cancelledPreparation.cancel()
        guard case .unavailable = await cancelledPreparation.value else {
            XCTFail("A cancelled preparation must return unavailable")
            resolver.finishFirstPreparation()
            return
        }

        let retryPreparation = Task { @MainActor in
            await restoreExecutor.prepare(kind: .folder, bookmark: bookmark)
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(resolver.startedCount, 1)

        resolver.finishFirstPreparation()
        let retryResult = await retryPreparation.value
        guard case let .resolved(preparedRestore) = retryResult else {
            XCTFail("The retry must receive a fresh, uncancelled preparation")
            return
        }
        preparedRestore.closeScopeIfOwned()

        XCTAssertEqual(resolver.startedCount, 2)
        XCTAssertEqual(scopeCloseRecorder.urls, [resolvedURL])
    }

    func testDetachedRestoreHardLimitDropsRepeatedCancelledQueuedWork()
        async
    {
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Bounded Detached Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let resolver = NonCooperativeRestoreResolver(
            resolvedURL: resolvedURL,
            scopeCloseRecorder: scopeCloseRecorder
        )
        let restoreExecutor = UserSelectedMediaRestoreExecutor.detached {
            kind,
            bookmark in
            resolver.prepare(kind: kind, bookmark: bookmark)
        }
        let copiedExecutor = restoreExecutor
        let firstPreparation = Task { @MainActor in
            await restoreExecutor.prepare(
                kind: .folder,
                bookmark: Data("hard-limit-first".utf8)
            )
        }
        let secondPreparation = Task { @MainActor in
            await copiedExecutor.prepare(
                kind: .folder,
                bookmark: Data("hard-limit-second".utf8)
            )
        }
        await Task.detached {
            resolver.waitUntilStarted()
            resolver.waitUntilStarted()
        }.value
        XCTAssertEqual(resolver.startedCount, 2)

        var cancelledPreparations: [
            Task<MediaSourceRestorePreparation, Never>
        ] = []
        for index in 0..<32 {
            let preparation = Task { @MainActor in
                await restoreExecutor.prepare(
                    kind: .folder,
                    bookmark: Data("hard-limit-queued-\(index)".utf8)
                )
            }
            cancelledPreparations.append(preparation)
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        cancelledPreparations.forEach { $0.cancel() }
        for preparation in cancelledPreparations {
            guard case .unavailable = await preparation.value else {
                XCTFail("Cancelled queued work must return unavailable")
                continue
            }
        }

        XCTAssertEqual(resolver.startedCount, 2)
        resolver.release()
        resolver.release()

        let runningResults = await (
            firstPreparation.value,
            secondPreparation.value
        )
        for result in [runningResults.0, runningResults.1] {
            guard case let .resolved(preparedRestore) = result else {
                XCTFail("The two admitted workers must finish normally")
                continue
            }
            preparedRestore.closeScopeIfOwned()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(resolver.startedCount, 2)
        XCTAssertEqual(scopeCloseRecorder.urls.count, 2)
    }

    func testStopDuringAsyncPreparationClosesLateScopeWithoutRevivingSource()
        async
    {
        let bookmark = Data("stop-during-restore".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Stopped Restore \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            preparedBookmark in
            await controller.prepare(
                kind: kind,
                bookmark: preparedBookmark
            )
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: bookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )

        let restoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        fixture.session.stop()
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: resolvedURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let restoredSources = await restoreTask.value
        XCTAssertTrue(restoredSources.isEmpty)
        XCTAssertEqual(scopeCloseRecorder.urls, [resolvedURL])
        XCTAssertTrue(fixture.recorder.stoppedURLs.isEmpty)
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: bookmark)]
        )
    }

    func testAsyncRetryAdoptsPreviouslyUnavailableScope() async {
        let bookmark = Data("async-retry".utf8)
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Async Retry \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            preparedBookmark in
            await controller.prepare(
                kind: kind,
                bookmark: preparedBookmark
            )
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: bookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )

        let initialRestoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        await controller.resolveNext(with: .unavailable)
        let initiallyRestoredSources = await initialRestoreTask.value
        XCTAssertTrue(initiallyRestoredSources.isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        let retryTask = Task { @MainActor in
            await fixture.session.retryUnavailableSourcesAsync()
        }
        await controller.waitForCallCount(2)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: resolvedURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let retriedSources = await retryTask.value
        XCTAssertEqual(
            retriedSources,
            [MediaSource(url: resolvedURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertTrue(scopeCloseRecorder.urls.isEmpty)

        fixture.session.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [resolvedURL])
        XCTAssertTrue(scopeCloseRecorder.urls.isEmpty)
    }

    func testAsyncRetryCancellationAfterFirstAdoptionPreservesRemainingSource()
        async
    {
        let firstBookmark = Data("partial-retry-first".utf8)
        let secondBookmark = Data("partial-retry-second".utf8)
        let firstURL = URL(
            fileURLWithPath: "/tmp/Partial Retry A \(UUID().uuidString)",
            isDirectory: true
        )
        let secondURL = URL(
            fileURLWithPath: "/tmp/Partial Retry B \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            bookmark in
            await controller.prepare(kind: kind, bookmark: bookmark)
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [firstBookmark, secondBookmark].map {
                StoredSourceRecord(kind: .folder, bookmark: $0).storedValue
            },
            forKey: TestStorage.sourceRecordKey
        )

        let initialRestoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        await controller.resolveNext(with: .unavailable)
        await controller.waitForCallCount(2)
        await controller.resolveNext(with: .unavailable)
        let initiallyRestoredSources = await initialRestoreTask.value
        XCTAssertTrue(initiallyRestoredSources.isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        let cancelledRetryTask = Task { @MainActor in
            await fixture.session.retryUnavailableSourcesAsync()
        }
        await controller.waitForCallCount(3)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: firstURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )
        await controller.waitForCallCount(4)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        let concurrentRetrySources = await fixture.session
            .retryUnavailableSourcesAsync()
        let callCountBeforeCancellation = await controller.callCount
        XCTAssertEqual(
            concurrentRetrySources,
            [MediaSource(url: firstURL, kind: .folder)]
        )
        XCTAssertEqual(callCountBeforeCancellation, 4)
        cancelledRetryTask.cancel()
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: secondURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let partiallyRestoredSources = await cancelledRetryTask.value
        XCTAssertEqual(
            partiallyRestoredSources,
            [MediaSource(url: firstURL, kind: .folder)]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(scopeCloseRecorder.urls, [secondURL])
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set([
                StoredSourceRecord(kind: .folder, bookmark: firstBookmark),
                StoredSourceRecord(kind: .folder, bookmark: secondBookmark)
            ])
        )

        let completingRetryTask = Task { @MainActor in
            await fixture.session.retryUnavailableSourcesAsync()
        }
        await controller.waitForCallCount(5)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: secondURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let completelyRestoredSources = await completingRetryTask.value
        XCTAssertEqual(
            Set(completelyRestoredSources),
            Set([
                MediaSource(url: firstURL, kind: .folder),
                MediaSource(url: secondURL, kind: .folder)
            ])
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(scopeCloseRecorder.urls, [secondURL])

        fixture.session.stop()
        XCTAssertEqual(
            Set(fixture.recorder.stoppedURLs),
            Set([firstURL, secondURL])
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs.count, 2)
    }

    func testRemovingAdoptedSourceDuringNextPreparationDoesNotReviveIt()
        async
    {
        let firstBookmark = Data("remove-during-retry-first".utf8)
        let secondBookmark = Data("remove-during-retry-second".utf8)
        let firstURL = URL(
            fileURLWithPath: "/tmp/Remove During Retry A \(UUID().uuidString)",
            isDirectory: true
        )
        let secondURL = URL(
            fileURLWithPath: "/tmp/Remove During Retry B \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            bookmark in
            await controller.prepare(kind: kind, bookmark: bookmark)
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [firstBookmark, secondBookmark].map {
                StoredSourceRecord(kind: .folder, bookmark: $0).storedValue
            },
            forKey: TestStorage.sourceRecordKey
        )

        let initialRestoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        await controller.resolveNext(with: .unavailable)
        await controller.waitForCallCount(2)
        await controller.resolveNext(with: .unavailable)
        _ = await initialRestoreTask.value

        let retryTask = Task { @MainActor in
            await fixture.session.retryUnavailableSourcesAsync()
        }
        await controller.waitForCallCount(3)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: firstURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )
        await controller.waitForCallCount(4)

        XCTAssertTrue(
            fixture.session.removeSource(
                MediaSource(url: firstURL, kind: .folder)
            ).isEmpty
        )
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: secondURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let restoredSources = await retryTask.value
        XCTAssertEqual(
            restoredSources,
            [MediaSource(url: secondURL, kind: .folder)]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: secondBookmark)]
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs, [firstURL])
        XCTAssertTrue(scopeCloseRecorder.urls.isEmpty)

        fixture.session.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [firstURL, secondURL])
    }

    func testStopAfterRemovingAdoptedSourcePreservesUnprocessedCandidate()
        async
    {
        let firstBookmark = Data("remove-stop-first".utf8)
        let secondBookmark = Data("remove-stop-second".utf8)
        let firstURL = URL(
            fileURLWithPath: "/tmp/Remove Stop A \(UUID().uuidString)",
            isDirectory: true
        )
        let secondURL = URL(
            fileURLWithPath: "/tmp/Remove Stop B \(UUID().uuidString)",
            isDirectory: true
        )
        let controller = RestorePreparationController()
        let scopeCloseRecorder = ThreadSafeURLRecorder()
        let restoreExecutor = UserSelectedMediaRestoreExecutor {
            kind,
            bookmark in
            await controller.prepare(kind: kind, bookmark: bookmark)
        }
        let fixture = makeSessionFixture(restoreExecutor: restoreExecutor)
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            [firstBookmark, secondBookmark].map {
                StoredSourceRecord(kind: .folder, bookmark: $0).storedValue
            },
            forKey: TestStorage.sourceRecordKey
        )

        let initialRestoreTask = Task { @MainActor in
            await fixture.session.restoreSourcesAsync()
        }
        await controller.waitForCallCount(1)
        await controller.resolveNext(with: .unavailable)
        await controller.waitForCallCount(2)
        await controller.resolveNext(with: .unavailable)
        _ = await initialRestoreTask.value

        let retryTask = Task { @MainActor in
            await fixture.session.retryUnavailableSourcesAsync()
        }
        await controller.waitForCallCount(3)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: firstURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )
        await controller.waitForCallCount(4)

        _ = fixture.session.removeSource(
            MediaSource(url: firstURL, kind: .folder)
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: secondBookmark)]
        )
        fixture.session.stop()
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: secondURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let stoppedRetrySources = await retryTask.value
        XCTAssertTrue(stoppedRetrySources.isEmpty)
        XCTAssertEqual(scopeCloseRecorder.urls, [secondURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [firstURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: secondBookmark)]
        )

        let nextSession = UserSelectedMediaSession(
            defaults: fixture.defaults,
            securityAccess: fixture.recorder.makeAccess(),
            sourceKindResolver: {
                $0.hasDirectoryPath ? .folder : .file
            },
            restoreExecutor: restoreExecutor
        )
        let nextRestoreTask = Task { @MainActor in
            await nextSession.restoreSourcesAsync()
        }
        await controller.waitForCallCount(5)
        await controller.resolveNext(
            with: .resolved(
                makeExecutorOwnedRestore(
                    resolvedURL: secondURL,
                    scopeCloseRecorder: scopeCloseRecorder
                )
            )
        )

        let nextRestoredSources = await nextRestoreTask.value
        XCTAssertEqual(
            nextRestoredSources,
            [MediaSource(url: secondURL, kind: .folder)]
        )
        XCTAssertEqual(scopeCloseRecorder.urls, [secondURL])
        nextSession.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [firstURL, secondURL])
    }

    func testFolderCoversFileRequestWithoutAddingADuplicateGrant() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Covered.mov")
        try Data([0xA5]).write(to: fileURL)
        for url in [sandboxURL, fileURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([sandboxURL])

        let update = fixture.session.addSources([fileURL, fileURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: sandboxURL, kind: .folder)]
        )
        XCTAssertEqual(update.requestedFileURLs, [fileURL])
        XCTAssertEqual(update.acceptedRequestCount, 2)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [sandboxURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [sandboxURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: fixture.recorder.bookmark(for: sandboxURL)
                )
            ]
        )

        fixture.session.stop()
    }

    func testSameBatchParentFolderAndExplicitFileKeepsPlaybackIntentForEitherOrder()
        throws {
        for selectsFileFirst in [false, true] {
            let fixture = makeSessionFixture()
            defer { fixture.clearDefaults() }
            let sandboxURL = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandboxURL) }
            let parentURL = sandboxURL.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let nestedURL = parentURL.appendingPathComponent(
                "Nested",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            let canonicalFileURL = parentURL.appendingPathComponent(
                "Selected.mp4"
            )
            try Data([0xA5]).write(to: canonicalFileURL)
            let selectedFileURL = nestedURL.appendingPathComponent(
                "../Selected.mp4"
            )
            let parentBookmark = fixture.recorder.bookmark(for: parentURL)
            let fileBookmark = fixture.recorder.bookmark(for: selectedFileURL)
            fixture.recorder.resolvedURLByBookmark[parentBookmark] = parentURL
            fixture.recorder.resolvedURLByBookmark[fileBookmark] =
                canonicalFileURL
            let selectedURLs = selectsFileFirst
                ? [selectedFileURL, parentURL]
                : [parentURL, selectedFileURL]

            let update = fixture.session.addSources(selectedURLs)

            XCTAssertEqual(
                update.activeSources,
                [MediaSource(url: parentURL, kind: .folder)]
            )
            XCTAssertEqual(update.requestedFileURLs, [canonicalFileURL])
            XCTAssertEqual(update.acceptedRequestCount, 2)
            XCTAssertEqual(update.rejectedRequestCount, 0)
            XCTAssertTrue(update.didChangeSources)
            XCTAssertEqual(
                storedSourceRecords(in: fixture.defaults),
                [
                    StoredSourceRecord(
                        kind: .folder,
                        bookmark: parentBookmark
                    )
                ]
            )
            XCTAssertEqual(
                fixture.recorder.bookmarkedURLs,
                selectsFileFirst
                    ? [selectedFileURL, parentURL]
                    : [parentURL]
            )
            XCTAssertEqual(
                fixture.recorder.startedURLs,
                selectsFileFirst
                    ? [canonicalFileURL, parentURL]
                    : [parentURL]
            )
            if selectsFileFirst {
                XCTAssertTrue(
                    fixture.recorder.stoppedURLs.contains(canonicalFileURL)
                )
            }

            fixture.session.stop()
            let stopCount = fixture.recorder.stoppedURLs.count
            XCTAssertEqual(fixture.recorder.stoppedURLs.last, parentURL)

            fixture.session.stop()
            XCTAssertEqual(fixture.recorder.stoppedURLs.count, stopCount)
        }
    }

    func testCoveredSymbolicLinkReturnsCanonicalFilePlaybackIntent() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let targetURL = rootURL.appendingPathComponent("Target.mp4")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Linked.mp4")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let rootBookmark = fixture.recorder.bookmark(for: rootURL)
        fixture.recorder.resolvedURLByBookmark[rootBookmark] = rootURL
        _ = fixture.session.addSources([rootURL])

        let update = fixture.session.addSources([linkURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: rootURL, kind: .folder)]
        )
        XCTAssertEqual(update.requestedFileURLs, [targetURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [rootURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [rootURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [rootURL, linkURL])

        fixture.session.stop()
    }

    func testHardLinkDuplicateUsesPersistedFilePlaybackURL() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let persistedURL = sandboxURL.appendingPathComponent("Persisted.mp4")
        let duplicateURL = sandboxURL.appendingPathComponent("Duplicate.mp4")
        try Data([0xA5]).write(to: persistedURL)
        try FileManager.default.linkItem(
            at: persistedURL,
            to: duplicateURL
        )
        let bookmark = fixture.recorder.bookmark(for: persistedURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = persistedURL
        _ = fixture.session.addSources([persistedURL])

        let update = fixture.session.addSources([duplicateURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: persistedURL, kind: .file)]
        )
        XCTAssertEqual(update.requestedFileURLs, [persistedURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [persistedURL])

        fixture.session.stop()
    }

    func testUniqueSymbolicLinkIsRejectedWithoutPersistingOrStartingScope() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let targetURL = sandboxURL.appendingPathComponent("Target.mov")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Unique.mov")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let update = fixture.session.addSources([linkURL])

        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.actionableRejectionCounts.isEmpty)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(fixture.recorder.bookmarkedURLs.isEmpty)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [linkURL])
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )
    }

    func testFolderOverlapThroughSymbolicLinkKeepsGenericRejection() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        let linkURL = sandboxURL.appendingPathComponent(
            "Library Link",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: parentURL
        )
        fixture.recorder.resolvedURLByBookmark[
            fixture.recorder.bookmark(for: childURL)
        ] = childURL
        _ = fixture.session.addSources([childURL])

        let update = fixture.session.addSources([linkURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: childURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.actionableRejectionCounts.isEmpty)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [childURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [childURL])

        fixture.session.stop()
    }

    func testAddingParentFolderReplacesFileGrantAfterFolderPersists() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("First.m4v")
        try Data([0xA5]).write(to: fileURL)
        for url in [fileURL, sandboxURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([fileURL])

        let update = fixture.session.addSources([sandboxURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: sandboxURL, kind: .folder)]
        )
        XCTAssertTrue(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL, sandboxURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: fixture.recorder.bookmark(for: sandboxURL)
                )
            ]
        )
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [fileURL, fileURL, sandboxURL]
        )

        fixture.session.stop()
    }

    func testBatchAddPersistsOrdinarySourceRecordsOnce() throws {
        var sourceRecordStoreCount = 0
        let fixture = makeSessionFixture(
            sourceRecordStoreObserver: { _ in
                sourceRecordStoreCount += 1
            }
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileCount = 24
        let fileURLs = try (0..<fileCount).map { index in
            let fileURL = sandboxURL.appendingPathComponent(
                "Selected-\(index).mp4"
            )
            try Data([0xA5]).write(to: fileURL)
            let bookmark = fixture.recorder.bookmark(for: fileURL)
            fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL
            return fileURL
        }

        let update = fixture.session.addSources(fileURLs)

        XCTAssertEqual(update.acceptedRequestCount, fileCount)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertEqual(update.activeSources.count, fileCount)
        XCTAssertEqual(sourceRecordStoreCount, 1)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults).count,
            fileCount
        )
        fixture.session.stop()
    }

    func testEmptyRestoreDoesNotWriteSourceRecords() {
        var sourceRecordStoreCount = 0
        let fixture = makeSessionFixture(
            sourceRecordStoreObserver: { _ in
                sourceRecordStoreCount += 1
            }
        )
        defer { fixture.clearDefaults() }

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertEqual(sourceRecordStoreCount, 0)
        XCTAssertNil(
            fixture.defaults.object(forKey: TestStorage.sourceRecordKey)
        )
    }

    func testMalformedTopLevelPersistenceIsSanitizedDuringRestore() {
        var sourceRecordStoreCount = 0
        let fixture = makeSessionFixture(
            sourceRecordStoreObserver: { _ in
                sourceRecordStoreCount += 1
            }
        )
        defer { fixture.clearDefaults() }
        fixture.defaults.set(
            "invalid records",
            forKey: TestStorage.sourceRecordKey
        )
        fixture.defaults.set(
            "invalid bookmarks",
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertEqual(sourceRecordStoreCount, 1)
        XCTAssertEqual(
            fixture.defaults.array(forKey: TestStorage.sourceRecordKey)?.count,
            0
        )
        XCTAssertNil(
            fixture.defaults.object(forKey: TestStorage.legacyBookmarkKey)
        )
    }

    func testReplacementPersistsBeforeReleasingReplacedScope() throws {
        var events: [MediaSourcePersistenceEvent] = []
        let fixture = makeSessionFixture(
            sourceRecordStoreObserver: { _ in
                events.append(.persist)
            }
        )
        defer { fixture.clearDefaults() }
        fixture.recorder.stopAccessHandler = { url in
            events.append(.stopAccess(url))
        }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Replaced.mp4")
        try Data([0xA5]).write(to: fileURL)
        for url in [fileURL, sandboxURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([fileURL])
        events.removeAll()

        _ = fixture.session.addSources([sandboxURL])

        let persistenceIndex = try XCTUnwrap(
            events.firstIndex(of: .persist)
        )
        let replacedScopeStopIndex = try XCTUnwrap(
            events.firstIndex(of: .stopAccess(fileURL))
        )
        XCTAssertLessThan(persistenceIndex, replacedScopeStopIndex)
        XCTAssertEqual(
            events.filter { $0 == .persist }.count,
            1
        )
        fixture.session.stop()
    }

    func testParentFolderIsRejectedWhenChildFolderIsAlreadyActive() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        for url in [childURL, parentURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([childURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([parentURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: childURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertEqual(
            update.actionableRejectionCounts,
            [.selectedFolderContainsActiveFolder: 1]
        )
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [childURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [childURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, parentURL]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRequest
        )

        fixture.session.stop()
    }

    func testChildFolderIsRejectedWhenParentFolderIsAlreadyActive() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        for url in [parentURL, childURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([parentURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([childURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: parentURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertEqual(
            update.actionableRejectionCounts,
            [.activeFolderContainsSelectedFolder: 1]
        )
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [parentURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [parentURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [parentURL, childURL]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRequest
        )

        fixture.session.stop()
    }

    func testParentFolderConflictPreservesCoveredFileAndChildFolder() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        let fileURL = parentURL.appendingPathComponent("Loose.mp4")
        try Data([0xA5]).write(to: fileURL)
        for url in [fileURL, childURL, parentURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([fileURL, childURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([parentURL])

        XCTAssertEqual(
            Set(update.activeSources),
            Set([
                MediaSource(url: fileURL, kind: .file),
                MediaSource(url: childURL, kind: .folder)
            ])
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(
            fixture.recorder.bookmarkedURLs,
            [fileURL, childURL]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL, childURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [fileURL, childURL, parentURL]
        )
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(recordsBeforeRequest)
        )

        fixture.session.stop()
    }

    func testDeduplicatesSameChildAndSymbolicAliasRoots() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent(
            "Root",
            isDirectory: true
        )
        let childURL = rootURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        let symbolicAliasURL = sandboxURL.appendingPathComponent(
            "Root Alias",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicAliasURL,
            withDestinationURL: rootURL
        )
        defer {
            try? FileManager.default.removeItem(at: sandboxURL)
        }

        for url in [rootURL, childURL, symbolicAliasURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        XCTAssertEqual(fixture.session.addFolders([rootURL]), [rootURL])
        XCTAssertEqual(fixture.session.addFolders([rootURL]).count, 1)
        XCTAssertEqual(fixture.session.addFolders([childURL]).count, 1)
        XCTAssertEqual(
            fixture.session.addFolders([symbolicAliasURL]).count,
            1
        )

        XCTAssertEqual(fixture.recorder.startedURLs, [rootURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults).count,
            1
        )

        fixture.session.stop()
    }

    func testRestorePreservesRejectedLegacyOverlapAndStopsItsScope() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent(
            "Root",
            isDirectory: true
        )
        let childURL = rootURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: sandboxURL)
        }

        let rootBookmark = fixture.recorder.bookmark(for: rootURL)
        let childBookmark = fixture.recorder.bookmark(for: childURL)
        fixture.recorder.resolvedURLByBookmark[rootBookmark] = rootURL
        fixture.recorder.resolvedURLByBookmark[childBookmark] = childURL
        fixture.defaults.set(
            [rootBookmark, childBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredURLs = fixture.session.restoreFolders()

        XCTAssertEqual(restoredURLs, [rootURL])
        XCTAssertEqual(
            fixture.recorder.startedURLs,
            [rootURL, childURL]
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs, [childURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: rootBookmark)]
        )
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [childBookmark]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        fixture.session.stop()
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, rootURL]
        )
    }

    func testLegacyFolderBookmarkMigratesToTypedFolderRecord() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let folderURL = sandboxURL.appendingPathComponent(
            "Folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let bookmark = fixture.recorder.bookmark(for: folderURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = folderURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredSources = fixture.session.restoreSources()

        XCTAssertEqual(
            restoredSources,
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: bookmark)]
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )

        fixture.session.stop()
    }

    func testLegacyFileBookmarkIsNotUpgradedToTypedFileRecord() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Legacy.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
    }

    func testTypedFileRecordRejectsDirectoryAtSameURL() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let sourceURL = sandboxURL.appendingPathComponent("Changed.mp4")
        try Data([0xA5]).write(to: sourceURL)
        let bookmark = fixture.recorder.bookmark(for: sourceURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = sourceURL
        _ = fixture.session.addSources([sourceURL])
        fixture.session.stop()
        let recordsBeforeRestore = storedSourceRecords(in: fixture.defaults)
        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )

        XCTAssertTrue(restoredSession.restoreSources().isEmpty)
        XCTAssertTrue(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRestore
        )
        XCTAssertEqual(fixture.recorder.startedURLs.last, sourceURL)
        XCTAssertEqual(fixture.recorder.stoppedURLs.last, sourceURL)
        restoredSession.stop()
    }

    func testTypedFolderRecordRejectsFileAtSameURL() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let sourceURL = sandboxURL.appendingPathComponent("Changed")
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        let bookmark = fixture.recorder.bookmark(for: sourceURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = sourceURL
        _ = fixture.session.addSources([sourceURL])
        fixture.session.stop()
        let recordsBeforeRestore = storedSourceRecords(in: fixture.defaults)
        try FileManager.default.removeItem(at: sourceURL)
        try Data([0xA5]).write(to: sourceURL)

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )

        XCTAssertTrue(restoredSession.restoreSources().isEmpty)
        XCTAssertTrue(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRestore
        )
        XCTAssertEqual(fixture.recorder.startedURLs.last, sourceURL)
        XCTAssertEqual(fixture.recorder.stoppedURLs.last, sourceURL)
        restoredSession.stop()
    }

    func testTypedFileRecordWithUnsupportedExtensionRemainsUnavailable() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Unsupported.txt")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        let record = StoredSourceRecord(kind: .file, bookmark: bookmark)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL
        fixture.defaults.set(
            [record.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [record]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
    }

    func testStaleTypedBookmarkRefreshPreservesFileKind() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Stale.mp4")
        try Data([0xA5]).write(to: fileURL)
        let staleBookmark = Data("stale-bookmark".utf8)
        let refreshedBookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[staleBookmark] = fileURL
        fixture.recorder.staleBookmarks.insert(staleBookmark)
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .file,
                    bookmark: staleBookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .file,
                    bookmark: refreshedBookmark
                )
            ]
        )
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [fileURL])
        fixture.session.stop()
    }

    func testUnknownAndDamagedTypedRecordsRemainStored() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let unknownRecord: [String: Any] = [
            TestStorage.RecordField.schemaVersion: 99,
            TestStorage.RecordField.kind: MediaSourceKind.file.rawValue,
            TestStorage.RecordField.bookmark: Data([0xA5])
        ]
        let damagedRecord = "damaged-record"
        fixture.defaults.set(
            [unknownRecord, damagedRecord],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        let storedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(storedValues.count, 2)
        XCTAssertEqual(
            (storedValues[0] as? [String: Any])?[
                TestStorage.RecordField.schemaVersion
            ] as? Int,
            99
        )
        XCTAssertEqual(storedValues[1] as? String, damagedRecord)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertTrue(fixture.recorder.stoppedURLs.isEmpty)
    }

    func testFolderRemovalPersistsBeforeReleasingActiveScope() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let rootURL = URL(
            fileURLWithPath: "/tmp/Muralume Removal \(UUID().uuidString)",
            isDirectory: true
        )
        let bookmark = fixture.recorder.bookmark(for: rootURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = rootURL
        XCTAssertEqual(fixture.session.addFolders([rootURL]), [rootURL])

        fixture.session.prepareToRemoveFolder(rootURL)

        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [rootURL])

        let remainingURLs = fixture.session.removeFolder(rootURL)

        XCTAssertTrue(remainingURLs.isEmpty)
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [rootURL, rootURL]
        )
    }

    func testRestorePreservesBookmarkWhenSourceKindIsUnavailable() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in nil })
        defer { fixture.clearDefaults() }
        let unavailableURL = URL(fileURLWithPath: "/Volumes/Offline/Video.mp4")
        let bookmark = fixture.recorder.bookmark(for: unavailableURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = unavailableURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [unavailableURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [unavailableURL])
    }

    func testRestorePreservesUniqueSymbolicLinkWithoutActivatingIt() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let targetURL = sandboxURL.appendingPathComponent("Target.m4v")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Legacy.m4v")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let bookmark = fixture.recorder.bookmark(for: linkURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = linkURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredSources = fixture.session.restoreSources()

        XCTAssertTrue(restoredSources.isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [linkURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [linkURL])
    }

    func testImportLimitRejectsOverflowAndReleasesEverySelectedScope() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let requestedURLs = (0...MediaImportPolicy.maximumTopLevelSourceCount)
            .map {
                URL(fileURLWithPath: "/tmp/Muralume Import \($0).mp4")
            }
        for url in requestedURLs {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        let update = fixture.session.addSources(requestedURLs)

        XCTAssertEqual(
            update.acceptedRequestCount,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertEqual(
            update.activeSources.count,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.startedURLs.count,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.stoppedURLs.count,
            requestedURLs.count
        )

        fixture.session.stop()
    }

    func testActiveSourceLimitAppliesAcrossSeparateImports() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let initialURLs = (0..<MediaImportPolicy.maximumActiveSourceCount)
            .map {
                URL(fileURLWithPath: "/tmp/Muralume Active \($0).mp4")
            }
        let overflowURL = URL(
            fileURLWithPath: "/tmp/Muralume Active Overflow.mp4"
        )
        for url in initialURLs + [overflowURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        let initialUpdate = fixture.session.addSources(initialURLs)
        let bookmarkCountBeforeOverflow = fixture.recorder.bookmarkedURLs.count
        let overflowUpdate = fixture.session.addSources([overflowURL])

        XCTAssertEqual(
            initialUpdate.acceptedRequestCount,
            MediaImportPolicy.maximumActiveSourceCount
        )
        XCTAssertEqual(overflowUpdate.acceptedRequestCount, 0)
        XCTAssertEqual(overflowUpdate.rejectedRequestCount, 1)
        XCTAssertFalse(overflowUpdate.didChangeSources)
        XCTAssertEqual(
            overflowUpdate.activeSources.count,
            MediaImportPolicy.maximumActiveSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.bookmarkedURLs.count,
            bookmarkCountBeforeOverflow
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults).count,
            MediaImportPolicy.maximumActiveSourceCount
        )

        fixture.session.stop()
    }

    func testRestoreDefersOverflowRecordsWithoutDiscardingThem() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let recordCount =
            MediaImportPolicy.maximumRestoredSourceRecordCount + 1
        let records = (0..<recordCount).map { index in
            let name = String(format: "%03d", index)
            let url = URL(
                fileURLWithPath: "/tmp/Muralume Restored \(name).mp4"
            )
            let bookmark = fixture.recorder.bookmark(for: url)
            fixture.recorder.resolvedURLByBookmark[bookmark] = url
            return StoredSourceRecord(kind: .file, bookmark: bookmark)
        }
        fixture.defaults.set(
            records.map(\.storedValue),
            forKey: TestStorage.sourceRecordKey
        )

        let firstRestore = fixture.session.restoreSources()

        XCTAssertEqual(
            firstRestore.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(records)
        )
        XCTAssertEqual(
            fixture.recorder.startedURLs.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: { _ in .file }
        )
        let secondRestore = secondSession.restoreSources()

        XCTAssertEqual(Set(secondRestore), Set(firstRestore))
        XCTAssertTrue(secondSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(records)
        )

        secondSession.stop()
    }

    func testDeferredTypedRecordAdvancesPastMixedUnavailablePrefix() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let firstURL = URL(
            fileURLWithPath: "/tmp/Muralume Restored First.mp4"
        )
        let deferredURL = URL(
            fileURLWithPath: "/tmp/Muralume Restored Deferred.mp4"
        )
        let firstRecord = StoredSourceRecord(
            kind: .file,
            bookmark: fixture.recorder.bookmark(for: firstURL)
        )
        let deferredRecord = StoredSourceRecord(
            kind: .file,
            bookmark: fixture.recorder.bookmark(for: deferredURL)
        )
        fixture.recorder.resolvedURLByBookmark[firstRecord.bookmark] = firstURL
        fixture.recorder.resolvedURLByBookmark[deferredRecord.bookmark] =
            deferredURL
        let damagedValues: [Any] = (
            0..<(MediaImportPolicy.maximumRestoredSourceRecordCount - 1)
        ).map { "damaged-record-\($0)" }
        var storedValues: [Any] = [firstRecord.storedValue]
        storedValues.append(contentsOf: damagedValues)
        storedValues.append(deferredRecord.storedValue)
        fixture.defaults.set(
            storedValues,
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: firstURL, kind: .file)]
        )
        let reorderedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(reorderedValues.count, storedValues.count)
        XCTAssertEqual(
            StoredSourceRecord(storedValue: reorderedValues[0]),
            firstRecord
        )
        XCTAssertEqual(
            StoredSourceRecord(storedValue: reorderedValues[1]),
            deferredRecord
        )

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: { _ in .file }
        )
        XCTAssertEqual(
            Set(secondSession.restoreSources()),
            Set([
                MediaSource(url: firstURL, kind: .file),
                MediaSource(url: deferredURL, kind: .file)
            ])
        )
        let persistedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(persistedValues.count, storedValues.count)
        XCTAssertEqual(
            Set(persistedValues.compactMap { $0 as? String }),
            Set(damagedValues.compactMap { $0 as? String })
        )

        secondSession.stop()
    }

    func testDeferredLegacyBookmarkAdvancesPastUnavailablePrefix() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let unavailableBookmarks = (
            0..<MediaImportPolicy.maximumRestoredSourceRecordCount
        ).map { Data("unavailable-bookmark-\($0)".utf8) }
        let folderURL = URL(
            fileURLWithPath: "/tmp/Muralume Legacy Deferred",
            isDirectory: true
        )
        let deferredBookmark = fixture.recorder.bookmark(for: folderURL)
        fixture.recorder.resolvedURLByBookmark[deferredBookmark] = folderURL
        fixture.defaults.set(
            unavailableBookmarks + [deferredBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        let reorderedBookmarks = fixture.defaults.array(
            forKey: TestStorage.legacyBookmarkKey
        ) as? [Data]
        XCTAssertEqual(reorderedBookmarks?.count, unavailableBookmarks.count + 1)
        XCTAssertEqual(reorderedBookmarks?.first, deferredBookmark)

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder
        )
        XCTAssertEqual(
            secondSession.restoreSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertEqual(
            Set(
                fixture.defaults.array(
                    forKey: TestStorage.legacyBookmarkKey
                ) as? [Data] ?? []
            ),
            Set(unavailableBookmarks)
        )

        secondSession.stop()
    }

    func testLegacyRestoreProgressesPastOfflineTypedBudgetPrefix() {
        let fixture = makeSessionFixture(sourceKindResolver: { url in
            url.hasDirectoryPath ? .folder : .file
        })
        defer { fixture.clearDefaults() }
        let typedRecords = (
            0..<MediaImportPolicy.maximumRestoredSourceRecordCount
        ).map { index in
            StoredSourceRecord(
                kind: .file,
                bookmark: Data("offline-typed-bookmark-\(index)".utf8)
            )
        }
        let legacyFolderURL = URL(
            fileURLWithPath: "/tmp/Muralume Legacy Budget Progress",
            isDirectory: true
        )
        let legacyBookmark = fixture.recorder.bookmark(for: legacyFolderURL)
        fixture.recorder.resolvedURLByBookmark[legacyBookmark] = legacyFolderURL
        fixture.defaults.set(
            typedRecords.map(\.storedValue),
            forKey: TestStorage.sourceRecordKey
        )
        fixture.defaults.set(
            [legacyBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: legacyFolderURL, kind: .folder)]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.recorder.resolvedBookmarks.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(
                typedRecords + [
                    StoredSourceRecord(
                        kind: .folder,
                        bookmark: legacyBookmark
                    )
                ]
            )
        )

        fixture.session.stop()
    }

    func testReplacementBarrierFlushesDirtyBatchAndFinalAdditionOnce() throws {
        var events: [MediaSourcePersistenceEvent] = []
        var persistedRecordCounts: [Int] = []
        let fixture = makeSessionFixture(
            sourceRecordStoreObserver: { storedValues in
                events.append(.persist)
                persistedRecordCounts.append(storedValues.count)
            }
        )
        defer { fixture.clearDefaults() }
        fixture.recorder.stopAccessHandler = { url in
            events.append(.stopAccess(url))
        }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let replacedURL = parentURL.appendingPathComponent("Replaced.mp4")
        let beforeBarrierURL = sandboxURL.appendingPathComponent("Before.mp4")
        let afterBarrierURL = sandboxURL.appendingPathComponent("After.mp4")
        for fileURL in [replacedURL, beforeBarrierURL, afterBarrierURL] {
            try Data([0xA5]).write(to: fileURL)
        }
        for url in [
            replacedURL,
            beforeBarrierURL,
            parentURL,
            afterBarrierURL
        ] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([replacedURL])
        events.removeAll()
        persistedRecordCounts.removeAll()

        _ = fixture.session.addSources([
            beforeBarrierURL,
            parentURL,
            afterBarrierURL
        ])

        XCTAssertEqual(persistedRecordCounts, [2, 3])
        let barrierIndex = try XCTUnwrap(events.firstIndex(of: .persist))
        let replacedScopeStopIndex = try XCTUnwrap(
            events.firstIndex(of: .stopAccess(replacedURL))
        )
        XCTAssertLessThan(barrierIndex, replacedScopeStopIndex)
        XCTAssertEqual(
            events.filter { $0 == .persist }.count,
            2
        )

        fixture.session.stop()
    }

    func testOversizedPersistedBookmarkIsPreservedWithoutResolution() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let fileURL = URL(
            fileURLWithPath: "/tmp/Muralume Oversized Persisted.mp4"
        )
        let oversizedBookmark = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )
        let record = StoredSourceRecord(
            kind: .file,
            bookmark: oversizedBookmark
        )
        fixture.recorder.resolvedURLByBookmark[oversizedBookmark] = fileURL
        fixture.defaults.set(
            [record.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertTrue(fixture.recorder.resolvedBookmarks.isEmpty)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [record]
        )
    }

    func testOversizedGeneratedBookmarkIsRejectedBeforeResolution() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let fileURL = URL(
            fileURLWithPath: "/tmp/Muralume Oversized Generated.mp4"
        )
        fixture.recorder.generatedBookmarkByURL[fileURL] = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )

        let update = fixture.session.addSources([fileURL])

        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(fixture.recorder.resolvedBookmarks.isEmpty)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
    }

    func testOversizedStaleBookmarkRefreshIsRejectedBeforeAcceptance() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let selectedURL = URL(
            fileURLWithPath: "/tmp/Muralume Stale Selected.mp4"
        )
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Muralume Stale Resolved.mp4"
        )
        let initialBookmark = fixture.recorder.bookmark(for: selectedURL)
        fixture.recorder.resolvedURLByBookmark[initialBookmark] = resolvedURL
        fixture.recorder.staleBookmarks.insert(initialBookmark)
        fixture.recorder.generatedBookmarkByURL[resolvedURL] = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )

        let update = fixture.session.addSources([selectedURL])

        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.startedURLs, [resolvedURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [resolvedURL, selectedURL]
        )
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
    }

    func testTypedFolderRestoresAcrossFreshDefaultsAndSessionInstances() {
        let suiteName = "\(TestStorage.suiteName).\(UUID().uuidString)"
        let folderURL = URL(
            fileURLWithPath: "/tmp/Muralume Fresh Defaults Library",
            isDirectory: true
        )
        let bookmark = Data(folderURL.absoluteString.utf8)
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }

        do {
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let recorder = SecurityScopeRecorder()
            recorder.resolvedURLByBookmark[bookmark] = folderURL
            let session = makeSession(
                defaults: defaults,
                recorder: recorder
            )

            let update = session.addSources([folderURL])

            XCTAssertEqual(
                update.activeSources,
                [MediaSource(url: folderURL, kind: .folder)]
            )
            session.stop()
        }

        let freshDefaults = UserDefaults(suiteName: suiteName)!
        let freshRecorder = SecurityScopeRecorder()
        freshRecorder.resolvedURLByBookmark[bookmark] = folderURL
        let freshSession = makeSession(
            defaults: freshDefaults,
            recorder: freshRecorder
        )

        XCTAssertEqual(
            freshSession.restoreSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(freshSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: freshDefaults),
            [StoredSourceRecord(kind: .folder, bookmark: bookmark)]
        )
        freshSession.stop()
    }

    func testRetryUnavailableTypedFolderSucceedsWithoutRecreatingSession() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let folderURL = URL(
            fileURLWithPath: "/Volumes/Offline/Muralume Library",
            isDirectory: true
        )
        let bookmark = fixture.recorder.bookmark(for: folderURL)
        let record = StoredSourceRecord(
            kind: .folder,
            bookmark: bookmark
        )
        fixture.defaults.set(
            [record.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        fixture.recorder.resolvedURLByBookmark[bookmark] = folderURL
        let restoredSources = fixture.session.retryUnavailableSources()
        let resolutionCountAfterRecovery =
            fixture.recorder.resolvedBookmarks.count

        XCTAssertEqual(
            restoredSources,
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(storedSourceRecords(in: fixture.defaults), [record])
        XCTAssertEqual(fixture.recorder.startedURLs, [folderURL])

        XCTAssertEqual(
            fixture.session.retryUnavailableSources(),
            restoredSources
        )
        XCTAssertEqual(
            fixture.recorder.resolvedBookmarks.count,
            resolutionCountAfterRecovery
        )
        fixture.session.stop()
    }

    func testSuccessfulPersistedRestoreRefreshesBookmarkBestEffort() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let folderURL = URL(
            fileURLWithPath: "/tmp/Muralume Refreshed Bookmark",
            isDirectory: true
        )
        let originalBookmark = Data("original-bookmark".utf8)
        let refreshedBookmark = Data("refreshed-bookmark".utf8)
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: originalBookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )
        fixture.recorder.resolvedURLByBookmark[originalBookmark] = folderURL
        fixture.recorder.generatedBookmarkByURL[folderURL] = refreshedBookmark

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: refreshedBookmark
                )
            ]
        )
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [folderURL])
        fixture.session.stop()
    }

    func testFailedPersistedBookmarkRefreshKeepsOriginalGrant() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let folderURL = URL(
            fileURLWithPath: "/tmp/Muralume Oversized Refresh",
            isDirectory: true
        )
        let originalBookmark = Data("working-bookmark".utf8)
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: originalBookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )
        fixture.recorder.resolvedURLByBookmark[originalBookmark] = folderURL
        fixture.recorder.generatedBookmarkByURL[folderURL] = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: originalBookmark
                )
            ]
        )
        fixture.session.stop()
    }

    func testReauthorizationPreservesUnmatchedUnavailableTypedRecord() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let unavailableBookmark = Data("unmatched-v1-bookmark".utf8)
        let unavailableRecord = StoredSourceRecord(
            kind: .folder,
            bookmark: unavailableBookmark
        )
        fixture.defaults.set(
            [unavailableRecord.storedValue],
            forKey: TestStorage.sourceRecordKey
        )
        XCTAssertTrue(fixture.session.restoreSources().isEmpty)

        let reauthorizedURL = URL(
            fileURLWithPath: "/tmp/Muralume Reauthorized Library",
            isDirectory: true
        )
        let reauthorizedBookmark = fixture.recorder.bookmark(
            for: reauthorizedURL
        )
        fixture.recorder.resolvedURLByBookmark[reauthorizedBookmark] =
            reauthorizedURL

        let update = fixture.session.addSources([reauthorizedURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: reauthorizedURL, kind: .folder)]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set([
                unavailableRecord,
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: reauthorizedBookmark
                )
            ])
        )
        fixture.session.stop()
    }

    func testRetryDropsCoveredExactFileAfterParentFolderReauthorization()
        throws
    {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let folderURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let fileURL = folderURL.appendingPathComponent("Recovered.mov")
        try Data([0xA5]).write(to: fileURL)
        let fileBookmark = fixture.recorder.bookmark(for: fileURL)
        let fileRecord = StoredSourceRecord(
            kind: .file,
            bookmark: fileBookmark
        )
        fixture.defaults.set(
            [fileRecord.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        let folderBookmark = fixture.recorder.bookmark(for: folderURL)
        fixture.recorder.resolvedURLByBookmark[fileBookmark] = fileURL
        fixture.recorder.resolvedURLByBookmark[folderBookmark] = folderURL
        let folderUpdate = fixture.session.addSources([folderURL])

        XCTAssertEqual(
            folderUpdate.activeSources,
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        XCTAssertEqual(
            fixture.session.retryUnavailableSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: folderBookmark
                )
            ]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [folderURL, fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [folderURL, fileURL])
        fixture.session.stop()
    }

    func testRetryPreservesUnavailableParentRejectedByActiveChild()
        throws
    {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let parentURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let childURL = parentURL.appendingPathComponent(
            "Active Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )

        let parentBookmark = fixture.recorder.bookmark(for: parentURL)
        let parentRecord = StoredSourceRecord(
            kind: .folder,
            bookmark: parentBookmark
        )
        fixture.defaults.set(
            [parentRecord.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)

        let childBookmark = fixture.recorder.bookmark(for: childURL)
        fixture.recorder.resolvedURLByBookmark[childBookmark] = childURL
        XCTAssertEqual(
            fixture.session.addSources([childURL]).activeSources,
            [MediaSource(url: childURL, kind: .folder)]
        )

        fixture.recorder.resolvedURLByBookmark[parentBookmark] = parentURL
        XCTAssertEqual(
            fixture.session.retryUnavailableSources(),
            [MediaSource(url: childURL, kind: .folder)]
        )

        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set([
                parentRecord,
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: childBookmark
                )
            ])
        )
        XCTAssertEqual(
            fixture.recorder.startedURLs,
            [childURL, parentURL]
        )
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, parentURL]
        )
        fixture.session.stop()
    }

    private func makeSessionFixture(
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            $0.hasDirectoryPath ? .folder : .file
        },
        sourceRecordStoreObserver: (([Any]) -> Void)? = nil,
        restoreExecutor: UserSelectedMediaRestoreExecutor? = nil
    ) -> MediaSessionFixture {
        let suiteName = TestStorage.suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let recorder = SecurityScopeRecorder()
        let sourceRecordStore: UserSelectedMediaSession.SourceRecordStore?
        if let sourceRecordStoreObserver {
            sourceRecordStore = { storedValues in
                sourceRecordStoreObserver(storedValues)
                defaults.set(
                    storedValues,
                    forKey: TestStorage.sourceRecordKey
                )
            }
        } else {
            sourceRecordStore = nil
        }
        let session = UserSelectedMediaSession(
            defaults: defaults,
            securityAccess: recorder.makeAccess(),
            sourceKindResolver: sourceKindResolver,
            sourceRecordStore: sourceRecordStore,
            restoreExecutor: restoreExecutor
        )
        return MediaSessionFixture(
            suiteName: suiteName,
            defaults: defaults,
            recorder: recorder,
            session: session
        )
    }

    private func makeSession(
        defaults: UserDefaults,
        recorder: SecurityScopeRecorder,
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            $0.hasDirectoryPath ? .folder : .file
        }
    ) -> UserSelectedMediaSession {
        UserSelectedMediaSession(
            defaults: defaults,
            securityAccess: recorder.makeAccess(),
            sourceKindResolver: sourceKindResolver
        )
    }

    private func storedSourceRecords(
        in defaults: UserDefaults
    ) -> [StoredSourceRecord] {
        (defaults.array(forKey: TestStorage.sourceRecordKey) ?? [])
            .compactMap(StoredSourceRecord.init(storedValue:))
    }

    private func makeExecutorOwnedRestore(
        resolvedURL: URL,
        scopeCloseRecorder: ThreadSafeURLRecorder
    ) -> ExecutorOwnedPreparedMediaSourceRestore {
        ExecutorOwnedPreparedMediaSourceRestore(
            restore: PreparedMediaSourceRestore(
                resolvedURL: resolvedURL,
                linkResolution: MediaSourceURLInspector.LinkResolution(
                    targetURL: resolvedURL.standardizedFileURL,
                    didResolveLink: false
                ),
                refreshedBookmark: nil,
                resourceIdentifier: nil
            ),
            stopAccess: { url in
                scopeCloseRecorder.append(url)
            }
        )
    }

    nonisolated private static func liveSourceKind(
        at url: URL
    ) -> MediaSourceKind? {
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

    private func makeSandbox() throws -> URL {
        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        return sandboxURL
    }
}

private actor RestorePreparationController {
    private struct CallCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var pendingPreparations: [
        CheckedContinuation<MediaSourceRestorePreparation, Never>
    ] = []
    private var callCountWaiters: [CallCountWaiter] = []
    private(set) var bookmarks: [Data] = []

    var callCount: Int {
        bookmarks.count
    }

    func prepare(
        kind: MediaSourceKind,
        bookmark: Data
    ) async -> MediaSourceRestorePreparation {
        _ = kind
        bookmarks.append(bookmark)
        resumeSatisfiedCallCountWaiters()
        return await withCheckedContinuation { continuation in
            pendingPreparations.append(continuation)
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            callCountWaiters.append(
                CallCountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    func resolveNext(with preparation: MediaSourceRestorePreparation) {
        precondition(!pendingPreparations.isEmpty)
        pendingPreparations.removeFirst().resume(returning: preparation)
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfiedWaiters = callCountWaiters.filter {
            callCount >= $0.expectedCount
        }
        callCountWaiters.removeAll {
            callCount >= $0.expectedCount
        }
        for waiter in satisfiedWaiters {
            waiter.continuation.resume()
        }
    }
}

private final class ThreadSafeURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }

    func append(_ url: URL) {
        lock.lock()
        storedURLs.append(url)
        lock.unlock()
    }
}

private final class NonCooperativeRestoreResolver: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private let resolvedURL: URL
    private let scopeCloseRecorder: ThreadSafeURLRecorder
    private var startedCountStorage = 0

    var startedCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startedCountStorage
    }

    init(
        resolvedURL: URL,
        scopeCloseRecorder: ThreadSafeURLRecorder
    ) {
        self.resolvedURL = resolvedURL
        self.scopeCloseRecorder = scopeCloseRecorder
    }

    func prepare(
        kind: MediaSourceKind,
        bookmark: Data
    ) -> MediaSourceRestorePreparation {
        _ = kind
        _ = bookmark
        stateLock.lock()
        startedCountStorage += 1
        stateLock.unlock()
        started.signal()
        releaseGate.wait()
        return .resolved(
            ExecutorOwnedPreparedMediaSourceRestore(
                restore: PreparedMediaSourceRestore(
                    resolvedURL: resolvedURL,
                    linkResolution: MediaSourceURLInspector.LinkResolution(
                        targetURL: resolvedURL.standardizedFileURL,
                        didResolveLink: false
                    ),
                    refreshedBookmark: nil,
                    resourceIdentifier: nil
                ),
                stopAccess: { [scopeCloseRecorder] url in
                    scopeCloseRecorder.append(url)
                }
            )
        )
    }

    func waitUntilStarted() {
        started.wait()
    }

    func release() {
        releaseGate.signal()
    }
}

private final class CancelledThenResolvedRestoreResolver:
    @unchecked Sendable {
    private let firstPreparationStarted = DispatchSemaphore(value: 0)
    private let firstPreparationGate = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private let resolvedURL: URL
    private let scopeCloseRecorder: ThreadSafeURLRecorder
    private var startedCountStorage = 0

    var startedCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startedCountStorage
    }

    init(
        resolvedURL: URL,
        scopeCloseRecorder: ThreadSafeURLRecorder
    ) {
        self.resolvedURL = resolvedURL
        self.scopeCloseRecorder = scopeCloseRecorder
    }

    func prepare(
        kind: MediaSourceKind,
        bookmark: Data
    ) -> MediaSourceRestorePreparation {
        _ = kind
        _ = bookmark
        let callCount: Int
        stateLock.lock()
        startedCountStorage += 1
        callCount = startedCountStorage
        stateLock.unlock()

        if callCount == 1 {
            firstPreparationStarted.signal()
            firstPreparationGate.wait()
            return .unavailable
        }

        return .resolved(
            ExecutorOwnedPreparedMediaSourceRestore(
                restore: PreparedMediaSourceRestore(
                    resolvedURL: resolvedURL,
                    linkResolution: MediaSourceURLInspector.LinkResolution(
                        targetURL: resolvedURL.standardizedFileURL,
                        didResolveLink: false
                    ),
                    refreshedBookmark: nil,
                    resourceIdentifier: nil
                ),
                stopAccess: { [scopeCloseRecorder] url in
                    scopeCloseRecorder.append(url)
                }
            )
        )
    }

    func waitUntilFirstPreparationStarted() {
        firstPreparationStarted.wait()
    }

    func finishFirstPreparation() {
        firstPreparationGate.signal()
    }
}

private enum MediaSourcePersistenceEvent: Equatable {
    case persist
    case stopAccess(URL)
}

@MainActor
private struct MediaSessionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let recorder: SecurityScopeRecorder
    let session: UserSelectedMediaSession

    func clearDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class SecurityScopeRecorder {
    var resolvedURLByBookmark: [Data: URL] = [:]
    var staleBookmarks: Set<Data> = []
    var generatedBookmarkByURL: [URL: Data] = [:]
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []
    private(set) var bookmarkedURLs: [URL] = []
    private(set) var resolvedBookmarks: [Data] = []
    var stopAccessHandler: ((URL) -> Void)?

    func bookmark(for url: URL) -> Data {
        generatedBookmarkByURL[url] ?? Data(url.absoluteString.utf8)
    }

    func makeAccess() -> SecurityScopedMediaAccess {
        SecurityScopedMediaAccess(
            makeBookmark: { [weak self] url in
                self?.bookmarkedURLs.append(url)
                return self?.bookmark(for: url)
            },
            resolveBookmark: { [weak self] bookmark in
                self?.resolvedBookmarks.append(bookmark)
                guard let url = self?.resolvedURLByBookmark[bookmark] else {
                    return nil
                }
                return SecurityScopedMediaAccess.ResolvedBookmark(
                    url: url,
                    isStale: self?.staleBookmarks.contains(bookmark) == true
                )
            },
            startAccess: { [weak self] url in
                self?.startedURLs.append(url)
                return true
            },
            stopAccess: { [weak self] url in
                self?.stoppedURLs.append(url)
                self?.stopAccessHandler?(url)
            }
        )
    }
}
