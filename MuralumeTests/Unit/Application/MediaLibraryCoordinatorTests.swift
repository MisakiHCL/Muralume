import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryCoordinatorTests: XCTestCase {
    func testUnsupportedFileFormatShowsSpecificImportNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 0,
            rejectedRequestCount: 1,
            actionableRejectionCounts: [.unsupportedFileFormat: 1],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Unsupported.mkv")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(
            fixture.coordinator.importNotice,
            .unsupportedFileFormat
        )
    }

    func testPartiallyAcceptedUnsupportedFormatShowsSpecificNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 1,
            rejectedRequestCount: 1,
            actionableRejectionCounts: [.unsupportedFileFormat: 1],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Supported.mp4"),
            URL(fileURLWithPath: "/tmp/Unsupported.mkv")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(
            fixture.coordinator.importNotice,
            .partialUnsupportedFileFormat
        )
    }

    func testParentFolderConflictShowsActionableImportNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 0,
            rejectedRequestCount: 1,
            actionableRejectionCounts: [
                .selectedFolderContainsActiveFolder: 1
            ],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Library")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(
            fixture.coordinator.importNotice,
            .selectedFolderContainsActiveFolder
        )
        XCTAssertEqual(
            fixture.session.incomingScopePolicies,
            [.sessionManaged]
        )
    }

    func testCoveredChildFolderShowsInformationalImportNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 0,
            rejectedRequestCount: 1,
            actionableRejectionCounts: [
                .activeFolderContainsSelectedFolder: 1
            ],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Library/Child")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(
            fixture.coordinator.importNotice,
            .activeFolderContainsSelectedFolder
        )
    }

    func testMixedImportRejectionsKeepGenericNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 0,
            rejectedRequestCount: 2,
            actionableRejectionCounts: [
                .selectedFolderContainsActiveFolder: 1
            ],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Library"),
            URL(fileURLWithPath: "/tmp/Unsupported.txt")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(fixture.coordinator.importNotice, .failure)
    }

    func testPartiallyAcceptedFolderConflictKeepsPartialNotice() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: [])
        )
        fixture.session.nextAddSourcesUpdate = MediaAccessUpdate(
            activeSources: [],
            requestedFileURLs: [],
            acceptedRequestCount: 1,
            rejectedRequestCount: 1,
            actionableRejectionCounts: [
                .selectedFolderContainsActiveFolder: 1
            ],
            didChangeSources: false
        )

        let preparation = fixture.coordinator.prepareImport([
            URL(fileURLWithPath: "/tmp/Accepted.mov"),
            URL(fileURLWithPath: "/tmp/Library")
        ])

        XCTAssertNil(preparation)
        XCTAssertEqual(fixture.coordinator.importNotice, .partialFailure)
    }

    func testInjectedPreferencesDriveInitialOrderAndScanSortWithoutWrites() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let small = makeItem(
            rootURL: rootURL,
            name: "Small",
            path: "Small.mov",
            fileSize: 1
        )
        let large = makeItem(
            rootURL: rootURL,
            name: "Large",
            path: "Large.mov",
            fileSize: 2
        )
        let preferencesStore = TestAppPreferencesStore()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [small, large]
            ),
            playbackOrder: .shuffled,
            sort: MediaLibrarySort(
                field: .fileSize,
                direction: .descending
            ),
            preferencesStore: preferencesStore
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.playbackOrder, .shuffled)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Large", "Small"]
        )
        XCTAssertTrue(preferencesStore.savedPlaybackOrders.isEmpty)
        XCTAssertTrue(preferencesStore.savedLibrarySorts.isEmpty)
    }

    func testOrderAndSortPersistOnlyAfterRealChanges() {
        let preferencesStore = TestAppPreferencesStore()
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: []),
            preferencesStore: preferencesStore
        )

        fixture.coordinator.setPlaybackOrder(.ordered)
        fixture.coordinator.setPlaybackOrder(.shuffled)
        fixture.coordinator.setPlaybackOrder(.shuffled)
        fixture.coordinator.setSortField(.name)
        fixture.coordinator.setSortDirection(.ascending)
        fixture.coordinator.setSortField(.fileSize)
        fixture.coordinator.toggleSortDirection()

        XCTAssertEqual(
            preferencesStore.savedPlaybackOrders,
            [.shuffled]
        )
        XCTAssertEqual(
            preferencesStore.savedLibrarySorts,
            [
                MediaLibrarySort(
                    field: .fileSize,
                    direction: .ascending
                ),
                MediaLibrarySort(
                    field: .fileSize,
                    direction: .descending
                )
            ]
        )
    }

    func testAddingFolderSourceScansAndPublishesSortedPlaylist() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let itemB = makeItem(rootURL: rootURL, name: "Clip 10", path: "B.mov")
        let itemA = makeItem(rootURL: rootURL, name: "Clip 2", path: "A.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [itemB, itemA]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.session.addedURLs, [rootURL])
        XCTAssertEqual(fixture.scanner.scannedRootURLs, [[rootURL]])
        XCTAssertEqual(
            fixture.scanner.scannedSources,
            [[MediaSource(url: rootURL, kind: .folder)]]
        )
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Clip 2", "Clip 10"]
        )
        XCTAssertEqual(fixture.coordinator.scanState, .ready)
    }

    func testResourceLimitFailuresRemainVisibleToTheUser() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Oversized Library")
        let cases: [(MediaLibraryScanError, MediaLibraryScanFailure)] = [
            (.timeLimitExceeded, .timeLimitExceeded),
            (.memoryLimitExceeded, .memoryLimitExceeded),
        ]

        for (error, expectedFailure) in cases {
            let fixture = makeFixture(
                selectedURLs: [rootURL],
                snapshot: .empty
            )
            fixture.scanner.enqueueScanError(error)

            fixture.coordinator.addMedia()
            await waitForScan(fixture.coordinator)

            XCTAssertEqual(
                fixture.coordinator.scanState,
                .failed(expectedFailure)
            )
            XCTAssertTrue(fixture.coordinator.items.isEmpty)
        }
    }

    func testCanonicalItemLookupIndexIsReusedUntilItemsChange()
        async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MuralumeLookup-\(UUID().uuidString)")
        let realRootURL = testDirectory.appendingPathComponent("Real")
        let linkedRootURL = testDirectory.appendingPathComponent("Linked")
        let firstRealURL = realRootURL.appendingPathComponent("First.mov")
        let secondRealURL = realRootURL.appendingPathComponent("Second.mov")
        try fileManager.createDirectory(
            at: realRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: linkedRootURL,
            withDestinationURL: realRootURL
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: firstRealURL.path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: secondRealURL.path,
                contents: Data()
            )
        )
        defer { try? fileManager.removeItem(at: testDirectory) }

        let firstItem = makeItem(
            rootURL: linkedRootURL,
            name: "First",
            path: "First.mov"
        )
        let secondItem = makeItem(
            rootURL: linkedRootURL,
            name: "Second",
            path: "Second.mov"
        )
        let root = MediaLibraryRoot(
            url: linkedRootURL,
            displayName: "Linked"
        )
        let fixture = makeFixture(
            selectedURLs: [linkedRootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [firstItem]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        for _ in 0..<50 {
            XCTAssertEqual(
                fixture.coordinator.libraryItem(matching: firstRealURL),
                firstItem
            )
        }
        XCTAssertEqual(
            fixture.coordinator
                .canonicalItemLookupIndexBuildCountForTesting,
            1
        )

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [firstItem, secondItem]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(
            fixture.coordinator.libraryItem(matching: secondRealURL),
            secondItem
        )
        XCTAssertEqual(
            fixture.coordinator
                .canonicalItemLookupIndexBuildCountForTesting,
            2
        )
    }

    func testCanonicalItemLookupIndexRebuildsWhenSymlinkRootRetargets()
        async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MuralumeRetarget-\(UUID().uuidString)")
        let firstRealRootURL = testDirectory.appendingPathComponent("First")
        let secondRealRootURL = testDirectory.appendingPathComponent("Second")
        let linkedRootURL = testDirectory.appendingPathComponent("Linked")
        try fileManager.createDirectory(
            at: firstRealRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: secondRealRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: linkedRootURL,
            withDestinationURL: firstRealRootURL
        )
        defer { try? fileManager.removeItem(at: testDirectory) }

        let firstRealURL = firstRealRootURL.appendingPathComponent("Clip.mov")
        let secondRealURL = secondRealRootURL.appendingPathComponent("Clip.mov")
        XCTAssertTrue(
            fileManager.createFile(
                atPath: firstRealURL.path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: secondRealURL.path,
                contents: Data()
            )
        )
        let item = makeItem(
            rootURL: linkedRootURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [linkedRootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: linkedRootURL,
                        displayName: "Linked"
                    )
                ],
                items: [item]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(
            fixture.coordinator.libraryItem(matching: firstRealURL),
            item
        )
        XCTAssertEqual(
            fixture.coordinator
                .canonicalItemLookupIndexBuildCountForTesting,
            1
        )

        try fileManager.removeItem(at: linkedRootURL)
        try fileManager.createSymbolicLink(
            at: linkedRootURL,
            withDestinationURL: secondRealRootURL
        )

        XCTAssertEqual(
            fixture.coordinator.libraryItem(matching: secondRealURL),
            item
        )
        XCTAssertNil(fixture.coordinator.libraryItem(matching: firstRealURL))
        XCTAssertEqual(
            fixture.coordinator
                .canonicalItemLookupIndexBuildCountForTesting,
            2
        )
    }

    func testManualRefreshAddsMembersWithoutResettingPlaybackContext()
        async {
        let rootURL = URL(fileURLWithPath: "/tmp/Refresh Library")
        let existingItem = makeItem(
            rootURL: rootURL,
            name: "Existing",
            path: "Existing.mov"
        )
        let addedItem = makeItem(
            rootURL: rootURL,
            name: "Added",
            path: "Added.mp4"
        )
        let root = MediaLibraryRoot(
            url: rootURL,
            displayName: "Refresh Library"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [existingItem]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(existingItem)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.engine.progressHandler?(27)

        let queueSnapshot = fixture.coordinator.makeQueueSnapshot()
        let queueRevision = fixture.coordinator.queueRevision
        let playbackSource = fixture.playback.source
        let playbackTime = fixture.playback.currentTime
        let isPlaybackRequested = fixture.playback.isPlaybackRequested

        fixture.scanner.blockNextScan()
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [existingItem, addedItem]
            )
        )
        fixture.coordinator.refresh()
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        XCTAssertFalse(fixture.coordinator.canRefresh)
        fixture.coordinator.refresh()
        XCTAssertEqual(fixture.scanner.scannedSources.count, 2)

        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)

        XCTAssertTrue(fixture.coordinator.canRefresh)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.id),
            [addedItem.id, existingItem.id]
        )
        XCTAssertNotEqual(
            fixture.coordinator.makeQueueSnapshot(),
            queueSnapshot
        )
        XCTAssertGreaterThan(
            fixture.coordinator.queueRevision,
            queueRevision
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, existingItem.id)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(fixture.playback.source, playbackSource)
        XCTAssertEqual(fixture.playback.currentTime, playbackTime)
        XCTAssertEqual(
            fixture.playback.isPlaybackRequested,
            isPlaybackRequested
        )
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.scanner.scannedSources.count, 2)
    }

    func testManualRefreshRemovesDeletedPendingItemFromQueue() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Refresh Deletion")
        let current = makeItem(
            rootURL: rootURL,
            name: "Current",
            path: "Current.mov"
        )
        let deleted = makeItem(
            rootURL: rootURL,
            name: "Deleted",
            path: "Deleted.mp4"
        )
        let root = MediaLibraryRoot(
            url: rootURL,
            displayName: "Refresh Deletion"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [current, deleted]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(current)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [current]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.items.map(\.id), [current.id])
        XCTAssertEqual(fixture.coordinator.queueCount, 1)
        XCTAssertTrue(fixture.coordinator.upNextItems.isEmpty)
        XCTAssertEqual(fixture.coordinator.currentItemID, current.id)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
    }

    func testTemporaryPlaybackCanonicalizesLargeLibraryOffMainThread()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Large Temporary Match")
        let itemCount = 50_000
        let libraryItems = (0..<itemCount).map { index in
            makeItem(
                rootURL: rootURL,
                name: "Clip \(index)",
                path: "Clip-\(index).mp4"
            )
        }
        let requestedItem = try XCTUnwrap(libraryItems.last)
        let probe = CanonicalPathThreadProbe()
        let session = TemporaryPlaybackSession(
            scanner: TestMediaLibraryScanner(snapshot: .empty),
            canonicalPath: { probe.resolve($0) }
        )

        let resolution = try await session.resolve(
            [requestedItem.url],
            libraryItems: libraryItems
        )

        XCTAssertEqual(resolution.items, [requestedItem])
        XCTAssertTrue(resolution.temporaryItemIDs.isEmpty)
        // One filesystem normalization for the shared library root and one
        // for the requested URL; all 50,000 item paths are indexed off-main.
        XCTAssertEqual(probe.callCount, 2)
        XCTAssertFalse(probe.didRunOnMainThread)
        session.end()
    }

    func testSecondTemporaryResolveCancelsActiveMatcherWithoutPublishingOldPlan()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Superseded Temporary Match")
        let firstItem = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mp4"
        )
        let secondItem = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mp4"
        )
        let probe = CanonicalPathThreadProbe(blockingCallNumber: 1)
        let session = TemporaryPlaybackSession(
            scanner: TestMediaLibraryScanner(snapshot: .empty),
            canonicalPath: { probe.resolve($0) }
        )
        defer {
            probe.finishBlockedCall()
            session.end()
        }
        let firstResolution = Task {
            try await session.resolve(
                [firstItem.url],
                libraryItems: [firstItem]
            )
        }
        while !probe.didBeginBlockedCall {
            await Task.yield()
        }

        let secondResolution = try await session.resolve(
            [secondItem.url],
            libraryItems: [secondItem]
        )
        probe.finishBlockedCall()

        do {
            _ = try await firstResolution.value
            XCTFail("A superseded matcher must not publish its result")
        } catch is CancellationError {
            // Expected: the second resolve invalidates and cancels the first.
        }
        XCTAssertEqual(secondResolution.items, [secondItem])
        XCTAssertTrue(secondResolution.temporaryItemIDs.isEmpty)
    }

    func testEndingTemporarySessionCancelsActiveMatcherWithoutPublishingPlan()
        async {
        let rootURL = URL(fileURLWithPath: "/tmp/Ended Temporary Match")
        let item = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mp4"
        )
        let probe = CanonicalPathThreadProbe(blockingCallNumber: 1)
        let session = TemporaryPlaybackSession(
            scanner: TestMediaLibraryScanner(snapshot: .empty),
            canonicalPath: { probe.resolve($0) }
        )
        defer {
            probe.finishBlockedCall()
            session.end()
        }
        let resolution = Task {
            try await session.resolve([item.url], libraryItems: [item])
        }
        while !probe.didBeginBlockedCall {
            await Task.yield()
        }

        session.end()
        probe.finishBlockedCall()

        do {
            _ = try await resolution.value
            XCTFail("An ended session must not publish an active match")
        } catch is CancellationError {
            // Expected: ending the session invalidates and cancels the match.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTemporaryPlaybackSurvivesRefreshAndRestoresPlaybackContext()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Temporary Playback Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let root = MediaLibraryRoot(
            url: rootURL,
            displayName: "Temporary Playback Library"
        )
        let librarySnapshot = MediaLibrarySnapshot(
            roots: [root],
            items: [first, second]
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: librarySnapshot
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.playback.seek(to: 37)
        fixture.playback.setPlaybackIntent(.paused)

        let context = try XCTUnwrap(
            fixture.coordinator.capturePlaybackContext()
        )
        let originalQueueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(originalQueueSnapshot.history.map(\.item), [first.id])

        let externalURL = URL(
            fileURLWithPath: "/tmp/External Temporary Clip.mp4"
        )
        let externalItem = makeFileItem(
            url: externalURL,
            name: "External Temporary Clip"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: externalURL,
                        displayName: externalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [externalItem]
            )
        )

        let didOpen = await fixture.coordinator.openFilesTemporarily([
            externalURL
        ])
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        XCTAssertTrue(fixture.coordinator.isTemporaryPlayback)
        XCTAssertTrue(fixture.coordinator.currentItemIsTemporary)
        XCTAssertEqual(fixture.coordinator.temporaryItemIDs, [externalItem.id])
        XCTAssertEqual(fixture.coordinator.currentItemID, externalItem.id)
        XCTAssertEqual(fixture.coordinator.queueCount, 1)
        XCTAssertEqual(fixture.playback.source?.url, externalURL)
        XCTAssertEqual(Set(fixture.coordinator.items), Set([first, second]))

        let temporaryQueueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        fixture.scanner.enqueueSnapshot(librarySnapshot)
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertTrue(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            temporaryQueueSnapshot
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, externalItem.id)
        XCTAssertEqual(fixture.playback.source?.url, externalURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 3)

        let restoreResult = await fixture.coordinator.restorePlaybackContext(
            context
        )

        XCTAssertEqual(restoreResult, .restored)
        XCTAssertFalse(fixture.coordinator.isTemporaryPlayback)
        XCTAssertFalse(fixture.coordinator.currentItemIsTemporary)
        XCTAssertTrue(fixture.coordinator.temporaryItemIDs.isEmpty)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            originalQueueSnapshot
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.playback.source?.url, second.url)
        XCTAssertEqual(fixture.playback.currentTime, 37)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(fixture.engine.soughtTimes.last, 37)
        XCTAssertEqual(fixture.engine.loadedSources.count, 4)
    }

    func testSupersededPlaybackContextRestoreCannotOverwriteNewExternalOpen()
        async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/Superseded Playback Context Restore"
        )
        let libraryItem = makeItem(
            rootURL: rootURL,
            name: "Library",
            path: "Library.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Superseded Playback Context Restore"
                    )
                ],
                items: [libraryItem]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(libraryItem)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.engine.progressHandler?(37)
        fixture.playback.setPlaybackIntent(.paused)
        let context = try XCTUnwrap(
            fixture.coordinator.capturePlaybackContext()
        )

        let firstExternalURL = URL(
            fileURLWithPath: "/tmp/First External Restore Race.mp4"
        )
        let firstExternalItem = makeFileItem(
            url: firstExternalURL,
            name: "First External"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: firstExternalURL,
                        displayName: firstExternalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [firstExternalItem]
            )
        )
        let didOpenFirstExternal = await fixture.coordinator
            .openFilesTemporarily([firstExternalURL])
        XCTAssertTrue(didOpenFirstExternal)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        fixture.engine.shouldBlockLoads = true
        let restoreTask = Task {
            await fixture.coordinator.restorePlaybackContext(context)
        }
        while !fixture.engine.didBeginBlockedLoad {
            await Task.yield()
        }

        let secondExternalURL = URL(
            fileURLWithPath: "/tmp/Second External Restore Race.mp4"
        )
        let secondExternalItem = makeFileItem(
            url: secondExternalURL,
            name: "Second External"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: secondExternalURL,
                        displayName: secondExternalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [secondExternalItem]
            )
        )
        fixture.engine.shouldBlockLoads = false
        let didOpenSecondExternal = await fixture.coordinator
            .openFilesTemporarily([secondExternalURL])
        XCTAssertTrue(didOpenSecondExternal)
        await waitForLoads(fixture.engine, count: 4)
        await waitForReady(fixture.playback)
        let secondExternalQueue = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertTrue(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(
            fixture.coordinator.currentItemID,
            secondExternalItem.id
        )
        XCTAssertEqual(fixture.playback.source?.url, secondExternalURL)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        fixture.engine.finishBlockedLoad()
        let restoreResult = await restoreTask.value

        XCTAssertEqual(restoreResult, .cancelled)
        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertTrue(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(
            fixture.coordinator.temporaryItemIDs,
            [secondExternalItem.id]
        )
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            secondExternalQueue
        )
        XCTAssertEqual(
            fixture.coordinator.currentItemID,
            secondExternalItem.id
        )
        XCTAssertEqual(fixture.playback.source?.url, secondExternalURL)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.soughtTimes.isEmpty)
    }

    func testPermanentExternalRestoreFailureEndsExternalContext()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Permanent Restore Failure")
        let libraryItem = makeItem(
            rootURL: rootURL,
            name: "Library",
            path: "Library.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Permanent Restore Failure"
                    )
                ],
                items: [libraryItem]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(libraryItem)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let context = try XCTUnwrap(
            fixture.coordinator.capturePlaybackContext()
        )

        let externalURL = URL(
            fileURLWithPath: "/tmp/Permanent Restore External.mp4"
        )
        let externalItem = makeFileItem(
            url: externalURL,
            name: "External"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: externalURL,
                        displayName: externalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [externalItem]
            )
        )
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            externalURL
        ])
        XCTAssertTrue(didOpen)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.engine.loadErrorsByURL[libraryItem.url] = .unsupported

        let result = await fixture.coordinator.restorePlaybackContext(context)

        XCTAssertEqual(result, .permanentlyUnavailable)
        XCTAssertFalse(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertFalse(fixture.coordinator.isTemporaryPlayback)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
    }

    func testKnownExternalBatchRemainsIndependentUntilAdopted() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Known External Batch")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Third",
            path: "Third.mov"
        )
        let root = MediaLibraryRoot(
            url: rootURL,
            displayName: "Known External Batch"
        )
        let snapshot = MediaLibrarySnapshot(
            roots: [root],
            items: [first, second, third]
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: snapshot
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.scanner.enqueueSnapshot(.empty)
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            first.url,
            second.url,
        ])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertFalse(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertTrue(fixture.coordinator.canMoveToNext)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.coordinator.upNextItems.map(\.id), [second.id])

        fixture.scanner.enqueueSnapshot(snapshot)
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(fixture.coordinator.upNextItems.map(\.id), [second.id])

        fixture.coordinator.adoptExternalPlaybackContext()
        XCTAssertFalse(fixture.coordinator.isExternalPlaybackContext)

        fixture.scanner.enqueueSnapshot(snapshot)
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.queueCount, 3)
        XCTAssertEqual(
            Set(fixture.coordinator.upNextItems.map(\.id)),
            Set([second.id, third.id])
        )
    }

    func testSingleKnownExternalFileUsesIndependentContext() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Known External File")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let snapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: rootURL,
                    displayName: "Known External File"
                )
            ],
            items: [first, second]
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: snapshot
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.scanner.enqueueSnapshot(.empty)
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            first.url
        ])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertFalse(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(fixture.coordinator.queueCount, 1)
        XCTAssertFalse(fixture.coordinator.canMoveToPrevious)
        XCTAssertFalse(fixture.coordinator.canMoveToNext)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertTrue(fixture.coordinator.upNextItems.isEmpty)
    }

    func testAddingCurrentTemporaryItemUsesCallerManagedIncomingScope()
        async {
        let externalURL = URL(
            fileURLWithPath: "/tmp/Caller Managed Current.mp4"
        )
        let externalItem = makeFileItem(url: externalURL)
        let snapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: externalURL,
                    displayName: externalURL.lastPathComponent,
                    kind: .file
                )
            ],
            items: [externalItem]
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: snapshot
        )

        let didOpen = await fixture.coordinator.openFilesTemporarily([
            externalURL
        ])
        XCTAssertTrue(didOpen)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(
            fixture.coordinator.addCurrentTemporaryItemToLibrary()
        )
        XCTAssertEqual(
            fixture.session.incomingScopePolicies,
            [.callerManaged]
        )
        await waitForScan(fixture.coordinator)
    }

    func testAddingAllTemporaryItemsUsesCallerManagedIncomingScope()
        async {
        let firstURL = URL(
            fileURLWithPath: "/tmp/Caller Managed First.mp4"
        )
        let secondURL = URL(
            fileURLWithPath: "/tmp/Caller Managed Second.mov"
        )
        let items = [firstURL, secondURL].map {
            makeFileItem(url: $0)
        }
        let snapshot = MediaLibrarySnapshot(
            roots: [firstURL, secondURL].map {
                MediaLibraryRoot(
                    url: $0,
                    displayName: $0.lastPathComponent,
                    kind: .file
                )
            },
            items: items
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: snapshot
        )

        let didOpen = await fixture.coordinator.openFilesTemporarily([
            firstURL,
            secondURL,
        ])
        XCTAssertTrue(didOpen)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(fixture.coordinator.addTemporaryItemsToLibrary())
        XCTAssertEqual(
            fixture.session.incomingScopePolicies,
            [.callerManaged]
        )
        await waitForScan(fixture.coordinator)
    }

    func testRestoredExternalReturnContextUsesCurrentPlaybackOrder()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/External Restore Order")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let snapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: rootURL,
                    displayName: "External Restore Order"
                )
            ],
            items: [first, second]
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: snapshot
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.setPlaybackMode(.ordered)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let context = try XCTUnwrap(
            fixture.coordinator.capturePlaybackContext()
        )

        fixture.scanner.enqueueSnapshot(.empty)
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            second.url
        ])
        XCTAssertTrue(didOpen)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.coordinator.setPlaybackMode(.shuffled)

        let result = await fixture.coordinator.restorePlaybackContext(context)
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.coordinator.playbackMode, .shuffled)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.order,
            .shuffled
        )
    }

    func testSelectingFromMediaLibraryEndsExternalContextAndKeepsBackHistory()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Exit External Context")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Third",
            path: "Third.mov"
        )
        let snapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: rootURL,
                    displayName: "Exit External Context"
                )
            ],
            items: [first, second, third]
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: snapshot
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.scanner.enqueueSnapshot(.empty)
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            first.url,
            second.url,
        ])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        fixture.coordinator.playLibraryItem(third)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertFalse(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertEqual(fixture.coordinator.queueCount, 3)
        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(fixture.coordinator.recentlyPlayedItems.map(\.id), [
            first.id
        ])
        XCTAssertTrue(fixture.coordinator.canMoveToPrevious)

        fixture.coordinator.playPrevious()
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.playback.source?.url, first.url)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.url),
            [first.url, third.url, first.url]
        )
    }

    func testSelectingLibraryItemAfterTemporaryExternalDoesNotCreatePhantomHistory()
        async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/Temporary External History Library"
        )
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Third",
            path: "Third.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Temporary External History Library"
                    )
                ],
                items: [first, second, third]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        let externalURL = URL(
            fileURLWithPath: "/tmp/Temporary External History.mp4"
        )
        let externalItem = makeFileItem(
            url: externalURL,
            name: "Temporary External"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: externalURL,
                        displayName: externalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [externalItem]
            )
        )
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            externalURL
        ])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        XCTAssertTrue(fixture.coordinator.currentItemIsTemporary)
        XCTAssertEqual(fixture.coordinator.currentItemID, externalItem.id)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [externalURL])

        fixture.coordinator.playLibraryItem(third)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        let queueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertFalse(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertFalse(fixture.coordinator.isTemporaryPlayback)
        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(fixture.playback.source?.url, third.url)
        XCTAssertTrue(queueSnapshot.history.isEmpty)
        XCTAssertTrue(fixture.coordinator.recentlyPlayedItems.isEmpty)
        XCTAssertFalse(fixture.coordinator.canMoveToPrevious)

        fixture.coordinator.playPrevious()
        await Task.yield()

        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(fixture.playback.source?.url, third.url)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.url),
            [externalURL, third.url]
        )
    }

    func testSelectingLibraryItemAfterMixedExternalQueueDoesNotRecordUnplayedItem()
        async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/Mixed External History Library"
        )
        let unplayed = makeItem(
            rootURL: rootURL,
            name: "Unplayed",
            path: "Unplayed.mov"
        )
        let other = makeItem(
            rootURL: rootURL,
            name: "Other",
            path: "Other.mov"
        )
        let selected = makeItem(
            rootURL: rootURL,
            name: "Selected",
            path: "Selected.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Mixed External History Library"
                    )
                ],
                items: [unplayed, other, selected]
            ),
            playbackOrder: .shuffled
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        let externalURL = URL(
            fileURLWithPath: "/tmp/Mixed External History.mp4"
        )
        let externalItem = makeFileItem(
            url: externalURL,
            name: "Temporary External"
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: externalURL,
                        displayName: externalURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [externalItem]
            )
        )
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            externalURL,
            unplayed.url,
        ])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(didOpen)
        XCTAssertEqual(fixture.coordinator.currentItemID, externalItem.id)
        XCTAssertEqual(
            fixture.coordinator.upNextItems.map(\.id),
            [unplayed.id]
        )
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [externalURL])

        fixture.coordinator.playLibraryItem(selected)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        let queueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(queueSnapshot.order, .shuffled)
        XCTAssertTrue(queueSnapshot.history.isEmpty)
        XCTAssertTrue(fixture.coordinator.recentlyPlayedItems.isEmpty)
        XCTAssertFalse(fixture.coordinator.canMoveToPrevious)
        XCTAssertEqual(fixture.coordinator.currentItemID, selected.id)
        XCTAssertEqual(fixture.playback.source?.url, selected.url)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.url),
            [externalURL, selected.url]
        )
    }

    func testLibraryQueueKeepsSynchronizingWhileExternalPersistenceIsFrozen()
        async {
        let rootURL = URL(fileURLWithPath: "/tmp/Frozen Library Queue")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Third",
            path: "Third.mov"
        )
        let root = MediaLibraryRoot(
            url: rootURL,
            displayName: "Frozen Library Queue"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.coordinator.beginExternalPlaybackContext()
        fixture.coordinator.playLibraryItem(
            second,
            preservingExternalContext: true
        )
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [first, second, third]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertTrue(fixture.coordinator.isExternalPlaybackContext)
        XCTAssertEqual(fixture.coordinator.queueCount, 3)
        XCTAssertEqual(
            Set(fixture.coordinator.makeQueueSnapshot()?.items ?? []),
            Set([first.id, second.id, third.id])
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
    }

    func testAddingVideoSourcesImportsAllAndPlaysFirstExplicitFile() async {
        let firstURL = URL(fileURLWithPath: "/tmp/First.mov")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.mp4")
        let first = makeFileItem(url: firstURL, name: "First")
        let second = makeFileItem(url: secondURL, name: "Second")
        let fixture = makeFixture(
            selectedURLs: [secondURL, firstURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: firstURL,
                        displayName: firstURL.lastPathComponent,
                        kind: .file
                    ),
                    MediaLibraryRoot(
                        url: secondURL,
                        displayName: secondURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [first, second]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(fixture.coordinator.items.count, 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.playback.source?.url, secondURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(
            fixture.scanner.scannedSources.first?.map(\.kind),
            [.file, .file]
        )

        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.playback.source?.url, firstURL)
    }

    func testAddingMixedSourcesPlaysFirstExplicitVideoAndScansFolder() async {
        let folderURL = URL(fileURLWithPath: "/tmp/Mixed Library")
        let firstExplicitURL = URL(fileURLWithPath: "/tmp/Chosen First.mov")
        let laterExplicitURL = URL(fileURLWithPath: "/tmp/Chosen Later.mp4")
        let folderVideo = makeItem(
            rootURL: folderURL,
            name: "Ambient",
            path: "Ambient.mp4"
        )
        let firstExplicit = makeFileItem(
            url: firstExplicitURL,
            name: "Chosen First"
        )
        let laterExplicit = makeFileItem(
            url: laterExplicitURL,
            name: "Chosen Later"
        )
        let selectedURLs = [folderURL, firstExplicitURL, laterExplicitURL]
        let fixture = makeFixture(
            selectedURLs: selectedURLs,
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: folderURL,
                        displayName: folderURL.lastPathComponent
                    ),
                    MediaLibraryRoot(
                        url: firstExplicitURL,
                        displayName: firstExplicitURL.lastPathComponent,
                        kind: .file
                    ),
                    MediaLibraryRoot(
                        url: laterExplicitURL,
                        displayName: laterExplicitURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [folderVideo, firstExplicit, laterExplicit]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(fixture.session.addedURLs, selectedURLs)
        XCTAssertEqual(fixture.coordinator.items.count, 3)
        XCTAssertEqual(fixture.coordinator.currentItemID, firstExplicit.id)
        XCTAssertEqual(fixture.playback.source?.url, firstExplicitURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(
            fixture.scanner.scannedSources.map { $0.map(\.kind) },
            [
                [.file, .file],
                [.folder, .file, .file]
            ]
        )
    }

    func testAddingCurrentVideoSourceAgainIsIdempotent() async {
        let fileURL = URL(fileURLWithPath: "/tmp/Current.mov")
        let item = makeFileItem(url: fileURL, name: "Current")
        let fixture = makeFixture(
            selectedURLs: [fileURL],
            subsequentSelectedURLs: [[fileURL]],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fileURL,
                        displayName: fileURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [item]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let queueRevision = fixture.coordinator.queueRevision

        fixture.coordinator.addMedia()
        await Task.yield()

        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
    }

    func testFolderOnlyImportExpandsQueueWithoutInterruptingPlayback()
        async throws {
        let firstRootURL = URL(fileURLWithPath: "/tmp/First Library")
        let secondRootURL = URL(fileURLWithPath: "/tmp/Second Library")
        let first = makeItem(
            rootURL: firstRootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: secondRootURL,
            name: "Second",
            path: "Second.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [firstRootURL],
            subsequentSelectedURLs: [[secondRootURL]],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: firstRootURL,
                        displayName: "First Library"
                    ),
                    MediaLibraryRoot(
                        url: secondRootURL,
                        displayName: "Second Library"
                    )
                ],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.engine.progressHandler?(27)
        let queueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        let playbackTime = fixture.playback.currentTime

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let expandedQueueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertEqual(
            fixture.session.addedURLs,
            [firstRootURL, secondRootURL]
        )
        XCTAssertEqual(fixture.coordinator.items.count, 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(
            expandedQueueSnapshot.items,
            [first.id, second.id]
        )
        XCTAssertEqual(
            expandedQueueSnapshot.currentItem,
            queueSnapshot.currentItem
        )
        XCTAssertEqual(
            expandedQueueSnapshot.currentRoundPosition,
            queueSnapshot.currentRoundPosition
        )
        XCTAssertEqual(
            expandedQueueSnapshot.history,
            queueSnapshot.history
        )
        XCTAssertEqual(
            expandedQueueSnapshot.forwardHistory,
            queueSnapshot.forwardHistory
        )
        XCTAssertEqual(fixture.coordinator.upNextItems, [second])
        XCTAssertEqual(fixture.playback.currentTime, playbackTime)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
    }

    func testParentFolderAdoptionKeepsMediaIdentityAndDoesNotReload()
        async throws {
        let folderURL = URL(fileURLWithPath: "/tmp/Adopted Library")
        let fileURL = folderURL.appendingPathComponent("Clip.mov")
        let fileItem = makeFileItem(url: fileURL, name: "Clip")
        let folderItem = makeItem(
            rootURL: folderURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [fileURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fileURL,
                        displayName: fileURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [fileItem]
            )
        )
        fixture.session.replacesFilesCoveredByAddedFolder = true
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)
        let fileQueue = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        let fileQueueStateRevision = fixture.coordinator.queueStateRevision
        XCTAssertEqual(fileQueue.currentItem.rootPath, fileURL.path)
        XCTAssertEqual(fileQueue.currentItem.relativePath, "")
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: folderURL,
                        displayName: folderURL.lastPathComponent
                    )
                ],
                items: [folderItem]
            )
        )

        let preparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [folderURL]
            )
        )
        fixture.coordinator.commitImport(preparation)
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fileItem.id, folderItem.id)
        XCTAssertEqual(fixture.coordinator.currentItemID, folderItem.id)
        XCTAssertEqual(fixture.coordinator.currentItem?.rootURL, folderURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertGreaterThan(
            fixture.coordinator.queueStateRevision,
            fileQueueStateRevision
        )
        let persistedQueue = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(persistedQueue.currentItem.rootPath, folderURL.path)
        XCTAssertEqual(persistedQueue.currentItem.relativePath, "Clip.mov")
    }

    func testFolderImportPreservesPendingExplicitPlaybackIntent() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/Pending.mov")
        let folderURL = URL(fileURLWithPath: "/tmp/Later Folder")
        let fileItem = makeFileItem(url: fileURL, name: "Pending")
        let folderItem = makeItem(
            rootURL: folderURL,
            name: "Later",
            path: "Later.mp4"
        )
        let candidateSnapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: fileURL,
                    displayName: fileURL.lastPathComponent,
                    kind: .file
                )
            ],
            items: [fileItem]
        )
        let fullSnapshot = MediaLibrarySnapshot(
            roots: candidateSnapshot.roots + [
                MediaLibraryRoot(
                    url: folderURL,
                    displayName: folderURL.lastPathComponent
                )
            ],
            items: [fileItem, folderItem]
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: fullSnapshot
        )
        fixture.scanner.blockNextScan()
        fixture.scanner.enqueueSnapshot(candidateSnapshot)
        fixture.scanner.enqueueSnapshot(fullSnapshot)

        let videoPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [fileURL]
            )
        )
        fixture.coordinator.commitImport(videoPreparation)
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        let folderPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [folderURL]
            )
        )
        fixture.coordinator.commitImport(folderPreparation)
        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(fixture.coordinator.currentItemID, fileItem.id)
        XCTAssertEqual(fixture.playback.source?.url, fileURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
    }

    func testLatestExplicitImportKeepsEarlierPendingFilesInQueue()
        async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/Pending First.mov")
        let latestURL = URL(fileURLWithPath: "/tmp/Pending Latest.mp4")
        let first = makeFileItem(url: firstURL, name: "First")
        let latest = makeFileItem(url: latestURL, name: "Latest")
        let snapshot = MediaLibrarySnapshot(
            roots: [firstURL, latestURL].map {
                MediaLibraryRoot(
                    url: $0,
                    displayName: $0.lastPathComponent,
                    kind: .file
                )
            },
            items: [first, latest]
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: snapshot)
        fixture.scanner.blockNextScan()
        fixture.scanner.enqueueSnapshot(snapshot)

        let firstPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [firstURL]
            )
        )
        fixture.coordinator.commitImport(firstPreparation)
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        let latestPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [latestURL]
            )
        )
        fixture.coordinator.commitImport(latestPreparation)
        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(fixture.coordinator.currentItemID, latest.id)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(fixture.playback.source?.url, latestURL)
    }

    func testStaleImportPreparationCannotClearLatestExplicitPlayIntent()
        async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/Stale First.mov")
        let latestURL = URL(fileURLWithPath: "/tmp/Stale Latest.mov")
        let first = makeFileItem(url: firstURL, name: "First")
        let latest = makeFileItem(url: latestURL, name: "Latest")
        let snapshot = MediaLibrarySnapshot(
            roots: [firstURL, latestURL].map {
                MediaLibraryRoot(
                    url: $0,
                    displayName: $0.lastPathComponent,
                    kind: .file
                )
            },
            items: [first, latest]
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: snapshot)

        let stalePreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [firstURL]
            )
        )
        let latestPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [latestURL]
            )
        )

        fixture.coordinator.commitImport(
            stalePreparation,
            autoplayExplicitFiles: false
        )
        fixture.coordinator.commitImport(latestPreparation)
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(fixture.session.addedURLs, [firstURL, latestURL])
        XCTAssertEqual(
            fixture.scanner.scannedRootURLs,
            [[firstURL, latestURL]]
        )
        XCTAssertEqual(
            Set(fixture.coordinator.items),
            Set([first, latest])
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, latest.id)
        XCTAssertEqual(fixture.playback.source?.url, latestURL)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [latestURL])
    }

    func testRestoreTreatsAdoptedFileInsideIncompleteFolderAsTemporary()
        async {
        let folderURL = URL(fileURLWithPath: "/tmp/Incomplete Adoption")
        let fileURL = folderURL.appendingPathComponent("Missing For Now.mov")
        let legacyFileItem = makeFileItem(url: fileURL)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: folderURL,
                        displayName: folderURL.lastPathComponent
                    )
                ],
                items: [],
                incompleteRootPaths: [folderURL.path]
            )
        )
        fixture.session.restoredURLs = [folderURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let savedQueue = PlaybackQueue(items: [legacyFileItem.id])

        let result = await fixture.coordinator.restoreQueue(
            from: savedQueue.makeSnapshot()!
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
    }

    func testRemovingLastRootReturnsLibraryToEmptyIdleState() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let item = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(item)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        guard let root = fixture.coordinator.roots.first else {
            return XCTFail("Expected the selected root to be available.")
        }
        await fixture.coordinator.removeRoot(root)

        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
    }

    func testRootScopeIsReleasedOnlyAfterConsumersDrain() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/DrainingLibrary")
        let item = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let thumbnailProvider = TestMediaThumbnailProvider()
        thumbnailProvider.shouldBlockInvalidation = true
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [item]
            ),
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.scanner.blockNextScan()
        fixture.coordinator.refresh()
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        fixture.engine.shouldBlockLoads = true
        fixture.coordinator.play(item)
        while !fixture.engine.didBeginBlockedLoad {
            await Task.yield()
        }

        let root = try XCTUnwrap(fixture.coordinator.roots.first)
        let removalTask = Task {
            await fixture.coordinator.removeRoot(root)
        }
        while fixture.session.preparedRemovalURLs.isEmpty
            || thumbnailProvider.invalidatedRootIDs != [root.id] {
            await Task.yield()
        }

        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        fixture.scanner.finishBlockedScan()
        await Task.yield()
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        fixture.engine.finishBlockedLoad()
        await Task.yield()
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        thumbnailProvider.finishInvalidation(for: root.id)
        await removalTask.value

        XCTAssertEqual(fixture.session.preparedRemovalURLs, [rootURL])
        XCTAssertEqual(fixture.session.removedURLs, [rootURL])
        XCTAssertEqual(
            thumbnailProvider.invalidatedRootIDs,
            [root.id]
        )
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
    }

    func testRemovingAdoptingFolderDrainsSupersededFileThumbnailRoot()
        async throws {
        let folderURL = URL(fileURLWithPath: "/tmp/Adoption Drain")
        let fileURL = folderURL.appendingPathComponent("Clip.mov")
        let fileItem = makeFileItem(url: fileURL)
        let folderItem = makeItem(
            rootURL: folderURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let thumbnailProvider = TestMediaThumbnailProvider()
        thumbnailProvider.shouldBlockInvalidation = true
        let fixture = makeFixture(
            selectedURLs: [fileURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fileURL,
                        displayName: fileURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [fileItem]
            ),
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.session.replacesFilesCoveredByAddedFolder = true
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: folderURL,
                        displayName: folderURL.lastPathComponent
                    )
                ],
                items: [folderItem]
            )
        )
        let preparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [folderURL]
            )
        )
        fixture.coordinator.commitImport(preparation)
        await waitForScan(fixture.coordinator)

        let root = try XCTUnwrap(fixture.coordinator.roots.first)
        let fileRootID = MediaLibraryRoot.ID(
            standardizedPath: fileURL.standardizedFileURL.path
        )
        let removalTask = Task {
            await fixture.coordinator.removeRoot(root)
        }
        while thumbnailProvider.invalidatedRootIDs != [root.id] {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        thumbnailProvider.finishInvalidation(for: root.id)
        while thumbnailProvider.invalidatedRootIDs != [root.id, fileRootID] {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        thumbnailProvider.finishInvalidation(for: fileRootID)
        await removalTask.value

        XCTAssertEqual(fixture.session.removedURLs, [folderURL])
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testCoveredCandidateUsesFolderRootBeforeRemovalDrain()
        async throws {
        let siblingURL = URL(fileURLWithPath: "/tmp/Candidate Library")
        let folderURL = URL(
            fileURLWithPath: "/tmp/Candidate Library Archive"
        )
        let candidateURL = folderURL.appendingPathComponent("Candidate.mov")
        let candidate = makeFileItem(url: candidateURL)
        let thumbnailProvider = TestMediaThumbnailProvider()
        thumbnailProvider.shouldBlockInvalidation = true
        let initialSnapshot = MediaLibrarySnapshot(
            roots: [
                MediaLibraryRoot(
                    url: siblingURL,
                    displayName: siblingURL.lastPathComponent
                ),
                MediaLibraryRoot(
                    url: folderURL,
                    displayName: folderURL.lastPathComponent
                )
            ],
            items: []
        )
        let fixture = makeFixture(
            selectedURLs: [siblingURL, folderURL],
            snapshot: initialSnapshot,
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.session.treatsFilesInsideActiveFoldersAsCovered = true
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: candidateURL,
                        displayName: candidateURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [candidate]
            )
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: initialSnapshot.roots,
                items: [candidate]
            )
        )
        fixture.scanner.blockNextScan(
            matching: [siblingURL, folderURL]
        )
        fixture.engine.shouldBlockLoads = true

        let preparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [candidateURL]
            )
        )
        fixture.coordinator.commitImport(preparation)
        while !fixture.scanner.didBeginBlockedScan
            || !fixture.engine.didBeginBlockedLoad {
            await Task.yield()
        }

        let representedCandidate = try XCTUnwrap(
            fixture.coordinator.items.first
        )
        XCTAssertEqual(representedCandidate.id, candidate.id)
        XCTAssertEqual(representedCandidate.rootURL, folderURL)
        XCTAssertEqual(representedCandidate.kind, .folder)
        XCTAssertEqual(representedCandidate.relativePath, "Candidate.mov")
        XCTAssertEqual(fixture.coordinator.currentItemID, candidate.id)
        let removedRoot = try XCTUnwrap(
            fixture.coordinator.roots.first {
                $0.id.standardizedPath == folderURL.path
            }
        )
        let removalTask = Task {
            await fixture.coordinator.removeRoot(removedRoot)
        }
        while fixture.session.preparedRemovalURLs.isEmpty
            || thumbnailProvider.invalidatedRootIDs != [removedRoot.id] {
            await Task.yield()
        }

        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        fixture.scanner.finishBlockedScan()
        fixture.engine.finishBlockedLoad()
        thumbnailProvider.finishInvalidation(for: removedRoot.id)
        await removalTask.value
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.session.removedURLs, [folderURL])
        XCTAssertEqual(
            thumbnailProvider.invalidatedRootIDs,
            [removedRoot.id]
        )
        XCTAssertEqual(
            fixture.coordinator.roots.map(\.id.standardizedPath),
            [siblingURL.path]
        )
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        XCTAssertNil(fixture.playback.source)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [candidateURL])
    }

    func testCoveredCandidateKeepsFolderRootAfterFullScanPublishes()
        async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MuralumeCandidate-\(UUID().uuidString)")
        let realParentURL = testDirectory.appendingPathComponent("Real")
        let linkedParentURL = testDirectory.appendingPathComponent("Linked")
        let canonicalFolderURL = realParentURL
            .appendingPathComponent("Published Candidate")
        let folderURL = linkedParentURL
            .appendingPathComponent("Published Candidate")
        let candidateURL = canonicalFolderURL
            .appendingPathComponent("Candidate.mov")
        try fileManager.createDirectory(
            at: canonicalFolderURL,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: linkedParentURL,
            withDestinationURL: realParentURL
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: candidateURL.path,
                contents: Data()
            )
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let candidate = makeFileItem(url: candidateURL)
        let folderItem = makeItem(
            rootURL: folderURL,
            name: "Candidate",
            path: "Candidate.mov"
        )
        let root = MediaLibraryRoot(
            url: folderURL,
            displayName: folderURL.lastPathComponent
        )
        let fixture = makeFixture(
            selectedURLs: [folderURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: [])
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.session.treatsFilesInsideActiveFoldersAsCovered = true
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: candidateURL,
                        displayName: candidateURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [candidate]
            )
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(roots: [root], items: [folderItem])
        )
        fixture.scanner.blockNextScan(matching: [folderURL])

        let preparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [candidateURL]
            )
        )
        fixture.coordinator.commitImport(preparation)
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        let candidateBeforePublish = try XCTUnwrap(
            fixture.coordinator.items.first
        )
        XCTAssertEqual(candidateBeforePublish.id, folderItem.id)
        XCTAssertEqual(candidateBeforePublish.id.rootPath, folderURL.path)
        XCTAssertEqual(candidateBeforePublish.kind, .folder)
        XCTAssertEqual(candidateBeforePublish.url, folderItem.url)
        XCTAssertEqual(fixture.coordinator.currentItemID, folderItem.id)

        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)

        let candidateAfterPublish = try XCTUnwrap(
            fixture.coordinator.items.first
        )
        XCTAssertEqual(candidateAfterPublish, folderItem)
        XCTAssertEqual(candidateAfterPublish.id.rootPath, folderURL.path)
        XCTAssertEqual(candidateAfterPublish.kind, .folder)
    }

    func testRemovingExactFileThroughEscapingSymlinkDoesNotUseFolderScope()
        async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MuralumeScopeEscape-\(UUID().uuidString)")
        let folderURL = testDirectory.appendingPathComponent("Library")
        let outsideURL = testDirectory.appendingPathComponent("Outside")
        let linkedDirectoryURL = folderURL.appendingPathComponent("Linked")
        let canonicalFileURL = outsideURL.appendingPathComponent("Clip.mov")
        let linkedFileURL = linkedDirectoryURL
            .appendingPathComponent("Clip.mov")
        try fileManager.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: linkedDirectoryURL,
            withDestinationURL: outsideURL
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: canonicalFileURL.path,
                contents: Data()
            )
        )
        defer {
            try? fileManager.removeItem(at: testDirectory)
        }

        let folderRoot = MediaLibraryRoot(
            url: folderURL,
            displayName: folderURL.lastPathComponent
        )
        let fileRoot = MediaLibraryRoot(
            url: linkedFileURL,
            displayName: linkedFileURL.lastPathComponent,
            kind: .file
        )
        let fileItem = makeFileItem(url: linkedFileURL)
        let thumbnailProvider = TestMediaThumbnailProvider()
        thumbnailProvider.shouldBlockInvalidation = true
        let fixture = makeFixture(
            selectedURLs: [folderURL],
            subsequentSelectedURLs: [[linkedFileURL]],
            snapshot: MediaLibrarySnapshot(
                roots: [folderRoot],
                items: []
            ),
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(roots: [fileRoot], items: [fileItem])
        )
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [folderRoot, fileRoot],
                items: [fileItem]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        let exactFileRoot = try XCTUnwrap(
            fixture.coordinator.roots.first { $0.kind == .file }
        )
        let removalTask = Task {
            await fixture.coordinator.removeRoot(exactFileRoot)
        }
        while thumbnailProvider.invalidatedRootIDs != [exactFileRoot.id] {
            await Task.yield()
        }

        XCTAssertTrue(fixture.session.removedURLs.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)

        thumbnailProvider.finishInvalidation(for: exactFileRoot.id)
        await removalTask.value
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.session.removedURLs, [linkedFileURL])
        XCTAssertEqual(fixture.coordinator.roots, [folderRoot])
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
    }

    func testRemovingPlayingRootLoadsSurvivorAndPreservesPlaybackIntent()
        async throws {
        let firstRootURL = URL(fileURLWithPath: "/tmp/PlayingRoot")
        let secondRootURL = URL(fileURLWithPath: "/tmp/SurvivingRoot")
        let first = makeItem(
            rootURL: firstRootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: secondRootURL,
            name: "Second",
            path: "Second.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [firstRootURL, secondRootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: firstRootURL,
                        displayName: "Playing Root"
                    ),
                    MediaLibraryRoot(
                        url: secondRootURL,
                        displayName: "Surviving Root"
                    )
                ],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForReady(fixture.playback)

        let playingRoot = try XCTUnwrap(
            fixture.coordinator.roots.first {
                $0.id.standardizedPath == firstRootURL.path
            }
        )
        await fixture.coordinator.removeRoot(playingRoot)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.playback.source?.url, second.url)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["First", "Second"]
        )
        XCTAssertEqual(fixture.session.removedURLs, [firstRootURL])
    }

    func testPlayingAnItemCreatesStableQueueAndNavigates() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 2)
        fixture.coordinator.playPrevious()
        await waitForLoads(fixture.engine, count: 3)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["First", "Second", "First"]
        )
        XCTAssertEqual(fixture.coordinator.currentItem?.id, first.id)
        XCTAssertEqual(fixture.coordinator.currentPosition, 1)
    }

#if DEBUG
    func testTenThousandItemNavigationKeepsHistoryStorageAndCachesSnapshots()
        async throws {
        let itemCount = 10_000
        let rootURL = URL(fileURLWithPath: "/tmp/Large Library")
        let items = (0..<itemCount).map { index in
            let suffix = String(format: "%05d", index)
            return makeItem(
                rootURL: rootURL,
                name: "Clip \(suffix)",
                path: "Clip \(suffix).mov"
            )
        }
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Large Library"
                    )
                ],
                items: items
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let firstItem = try XCTUnwrap(fixture.coordinator.items.first)
        fixture.coordinator.play(firstItem)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        let historyStorage = try XCTUnwrap(
            fixture.coordinator.queueHistoryStorageIdentityForTesting
        )
        let initialStateRevision = fixture.coordinator.queueStateRevision
        let initialStructureRevision =
            fixture.coordinator.queueStructureRevision

        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        XCTAssertEqual(
            fixture.coordinator.queueHistoryStorageIdentityForTesting,
            historyStorage
        )
        XCTAssertEqual(
            fixture.coordinator.queueStateRevision,
            initialStateRevision + 1
        )
        XCTAssertEqual(
            fixture.coordinator.queueStructureRevision,
            initialStructureRevision
        )

        let firstSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        let cachedSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(firstSnapshot.history.count, 1)
        XCTAssertEqual(
            storageIdentity(of: firstSnapshot.history),
            storageIdentity(of: cachedSnapshot.history)
        )

        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        let advancedSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(advancedSnapshot.history.count, 2)
        XCTAssertNotEqual(
            storageIdentity(of: advancedSnapshot.history),
            storageIdentity(of: firstSnapshot.history)
        )
        XCTAssertEqual(
            fixture.coordinator.queueHistoryStorageIdentityForTesting,
            historyStorage
        )
        XCTAssertEqual(
            fixture.coordinator.queueStateRevision,
            initialStateRevision + 2
        )
        XCTAssertEqual(
            fixture.coordinator.queueStructureRevision,
            initialStructureRevision
        )

        fixture.coordinator.playPrevious()
        await waitForLoads(fixture.engine, count: 4)
        await waitForReady(fixture.playback)
        XCTAssertEqual(
            fixture.coordinator.queueHistoryStorageIdentityForTesting,
            historyStorage
        )
        XCTAssertEqual(
            fixture.coordinator.queueStateRevision,
            initialStateRevision + 3
        )
    }

    func testPreviousUnavailableTraversalRollsBackQueueAndCachedSnapshot()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Unavailable History")
        let first = makeItem(
            rootURL: rootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Second",
            path: "Second.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Third",
            path: "Third.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Unavailable History"
                    )
                ],
                items: [first, second, third]
            )
        )
        fixture.engine.loadErrorsByURL[first.url] = .cannotOpen
        fixture.engine.loadErrorsByURL[second.url] = .cannotOpen
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(
            fixture.coordinator.unavailableItemIDs,
            [first.id, second.id]
        )

        let snapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        let snapshotHistoryStorage = storageIdentity(of: snapshot.history)
        let queueHistoryStorage = fixture.coordinator
            .queueHistoryStorageIdentityForTesting
        let queueRevision = fixture.coordinator.queueRevision
        let queueStateRevision = fixture.coordinator.queueStateRevision

        fixture.coordinator.playPrevious()

        XCTAssertEqual(fixture.engine.loadedSources.count, 3)
        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
        XCTAssertEqual(
            fixture.coordinator.queueStateRevision,
            queueStateRevision
        )
        XCTAssertEqual(
            fixture.coordinator.queueHistoryStorageIdentityForTesting,
            queueHistoryStorage
        )
        let cachedSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(cachedSnapshot, snapshot)
        XCTAssertEqual(
            storageIdentity(of: cachedSnapshot.history),
            snapshotHistoryStorage
        )
    }
#endif

    func testQueueRevisionPublishesOrderAndNoncurrentRootChanges() async throws {
        let firstRootURL = URL(fileURLWithPath: "/tmp/FirstLibrary")
        let secondRootURL = URL(fileURLWithPath: "/tmp/SecondLibrary")
        let first = makeItem(
            rootURL: firstRootURL,
            name: "First",
            path: "First.mov"
        )
        let second = makeItem(
            rootURL: secondRootURL,
            name: "Second",
            path: "Second.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [firstRootURL, secondRootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: firstRootURL,
                        displayName: "First Library"
                    ),
                    MediaLibraryRoot(
                        url: secondRootURL,
                        displayName: "Second Library"
                    )
                ],
                items: [first, second]
            ),
            playbackOrder: .ordered
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)

        let revisionAfterPlay = fixture.coordinator.queueRevision
        fixture.coordinator.setPlaybackOrder(.shuffled)
        let revisionAfterOrder = fixture.coordinator.queueRevision
        let secondRoot = try XCTUnwrap(
            fixture.coordinator.roots.first {
                $0.id.standardizedPath == secondRootURL.path
            }
        )
        await fixture.coordinator.removeRoot(secondRoot)

        XCTAssertGreaterThan(revisionAfterOrder, revisionAfterPlay)
        XCTAssertGreaterThan(
            fixture.coordinator.queueRevision,
            revisionAfterOrder
        )
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id]
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.playback.readiness, .ready)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
    }

    func testClickingVisibleItemBranchesWithoutLosingHistory() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "A",
            path: "A.mov",
            fileSize: 3
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "B",
            path: "B.mov",
            fileSize: 2
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "C",
            path: "C.mov",
            fileSize: 1
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second, third]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.coordinator.setSortField(.fileSize)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["C", "B", "A"]
        )
        fixture.coordinator.setSortDirection(.descending)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["A", "B", "C"]
        )
        fixture.coordinator.setSortDirection(.ascending)
        fixture.coordinator.play(third)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.history.last?.item,
            first.id
        )
        XCTAssertTrue(fixture.coordinator.canMoveToPrevious)
        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 3)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["A", "C", "B"]
        )
    }

    func testPlaybackCompletionAutomaticallyAdvancesTheQueue() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)

        fixture.engine.emitItemEnded()
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(fixture.engine.loadedSources.last?.displayName, "Second")
        XCTAssertEqual(fixture.coordinator.currentItem?.id, second.id)
    }

    func testSingleItemCompletionSeeksToStartInEveryPlaybackMode() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Single Item Loop")
        let item = makeItem(
            rootURL: rootURL,
            name: "Only",
            path: "Only.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Single Item Loop"
                    )
                ],
                items: [item]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(item)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        for (index, mode) in PlaybackMode.allCases.enumerated() {
            fixture.coordinator.setPlaybackMode(mode)
            let queueSnapshot = fixture.coordinator.makeQueueSnapshot()
            let queueRevision = fixture.coordinator.queueRevision

            fixture.engine.emitItemEnded()

            XCTAssertEqual(fixture.engine.loadedSources.count, 1)
            XCTAssertEqual(
                fixture.engine.soughtTimes,
                Array(repeating: 0, count: index + 1)
            )
            XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
            XCTAssertEqual(
                fixture.coordinator.makeQueueSnapshot(),
                queueSnapshot
            )
            XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
            XCTAssertTrue(fixture.playback.isPlaybackRequested)
        }
    }

    func testTimelineSeekToEndAdvancesQueueOnlyAfterRelease() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.playback.beginTimelineSeek()
        fixture.playback.seek(to: 120)
        fixture.engine.emitItemEnded()

        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.coordinator.currentItem?.id, first.id)

        fixture.playback.endTimelineSeek()
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(fixture.engine.loadedSources.last?.displayName, "Second")
        XCTAssertEqual(fixture.coordinator.currentItem?.id, second.id)
    }

    func testFailedItemIsSkippedWithoutLoopingForever() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.engine.loadErrorsByURL[broken.url] = .cannotOpen
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid"]
        )
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.contains(broken.id))
        XCTAssertEqual(fixture.coordinator.currentItem?.id, valid.id)
    }

    func testRuntimeFailureMarksItemUnavailableAndAdvances() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.engine.emitFailure(.cannotOpen)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid"]
        )
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.contains(broken.id))
        XCTAssertEqual(fixture.coordinator.currentItem?.id, valid.id)
        XCTAssertEqual(fixture.playback.readiness, .ready)
    }

    func testKnownUnavailableItemIsSkippedOnLaterRounds() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.engine.loadErrorsByURL[broken.url] = .cannotOpen
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid", "Valid"]
        )
    }

    func testExhaustedQueueFinishesWithFailure() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.engine.loadErrorsByURL[first.url] = .cannotOpen
        fixture.engine.loadErrorsByURL[second.url] = .cannotOpen
        var reportedFailure: PlaybackFailure?
        fixture.playback.playbackFailureHandler = {
            reportedFailure = $0
        }
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 2)
        await waitForFailure(fixture.playback)

        XCTAssertEqual(reportedFailure, .cannotOpen)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(
            fixture.coordinator.unavailableItemIDs,
            [first.id, second.id]
        )
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
    }

    func testGlobalLoadFailureDoesNotMarkMediaUnavailableOrSkipQueue() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.engine.loadErrorsByURL[first.url] = .surfaceTimeout
        var reportedFailure: PlaybackFailure?
        fixture.playback.playbackFailureHandler = {
            reportedFailure = $0
        }
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForFailure(fixture.playback)

        XCTAssertEqual(reportedFailure, .surfaceTimeout)
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.isEmpty)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["First"]
        )
    }

    func testRestoredFileKindReachesTypedScannerEntryPoint() async {
        let fileURL = URL(fileURLWithPath: "/tmp/Restored File.mov")
        let item = makeFileItem(url: fileURL)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fileURL,
                        displayName: fileURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [fileURL]

        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(
            fixture.scanner.scannedSources,
            [[MediaSource(url: fileURL, kind: .file)]]
        )
    }

    func testQueueRestoreReconcilesOrderedSnapshotToGlobalShuffleMode() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RestoredLibrary")
        let restoredItems = ["A", "B", "C", "D"].map {
            makeItem(rootURL: rootURL, name: $0, path: "\($0).mov")
        }
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: restoredItems
            ),
            playbackOrder: .shuffled
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let orderedQueue = PlaybackQueue(
            items: restoredItems.map(\.id),
            startingAt: restoredItems[0].id,
            order: .ordered
        )

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(orderedQueue.makeSnapshot())
        )
        let restoredSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(restoredSnapshot.order, .shuffled)
        XCTAssertEqual(restoredSnapshot.currentItem, restoredItems[0].id)
    }

    func testQueueRestoreRefreshesShuffledPendingItemsAfterFilteringMissingMedia() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RestoredLibrary")
        let allItems = ["A", "B", "C", "D", "Missing"].map {
            makeItem(rootURL: rootURL, name: $0, path: "\($0).mov")
        }
        let availableItems = Array(allItems.dropLast())
        var didReshuffle = false
        var itemIDsSeenByShuffler: [LibraryMediaItem.ID] = []
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: availableItems
            ),
            playbackOrder: .shuffled,
            reshuffleRestoredQueue: { queue in
                didReshuffle = true
                itemIDsSeenByShuffler = queue.items
                var randomSource = TestSeededRandomNumberGenerator(seed: 1)
                queue.reshufflePendingItems(using: &randomSource)
            }
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let snapshot = PlaybackQueueSnapshot(
            items: allItems.map(\.id),
            order: .shuffled,
            currentItem: allItems[0].id,
            roundNumber: 2,
            currentRoundPosition: 1,
            remainingItems: Array(allItems.dropFirst()).map(\.id),
            remainingIndex: 0,
            history: [],
            forwardHistory: []
        )

        let result = await fixture.coordinator.restoreQueue(from: snapshot)
        let restoredSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertEqual(result, .restored)
        XCTAssertTrue(didReshuffle)
        XCTAssertEqual(Set(itemIDsSeenByShuffler), Set(availableItems.map(\.id)))
        XCTAssertFalse(itemIDsSeenByShuffler.contains(allItems[4].id))
        XCTAssertEqual(restoredSnapshot.order, .shuffled)
        XCTAssertEqual(restoredSnapshot.currentItem, availableItems[0].id)
        XCTAssertEqual(
            Set(restoredSnapshot.remainingItems),
            Set(availableItems.dropFirst().map(\.id))
        )
    }

    func testQueueRestoreReconcilesShuffledSnapshotToGlobalOrderedMode() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RestoredLibrary")
        let restoredItems = ["A", "B", "C", "D"].map {
            makeItem(rootURL: rootURL, name: $0, path: "\($0).mov")
        }
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: restoredItems
            ),
            playbackOrder: .ordered
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let snapshot = PlaybackQueueSnapshot(
            items: restoredItems.map(\.id),
            order: .shuffled,
            currentItem: restoredItems[1].id,
            roundNumber: 2,
            currentRoundPosition: 2,
            remainingItems: [
                restoredItems[3].id,
                restoredItems[1].id,
                restoredItems[0].id,
                restoredItems[2].id
            ],
            remainingIndex: 2,
            history: [
                PlaybackQueueSnapshotLocation(
                    item: restoredItems[3].id,
                    roundNumber: 2,
                    position: 1
                )
            ],
            forwardHistory: []
        )

        let result = await fixture.coordinator.restoreQueue(from: snapshot)
        let restoredSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(restoredSnapshot.order, .ordered)
        XCTAssertEqual(restoredSnapshot.currentItem, restoredItems[1].id)
        XCTAssertEqual(
            restoredSnapshot.remainingItems,
            [restoredItems[0].id, restoredItems[2].id]
        )
    }

    func testQueueRestoreChoosesCachedSuccessorBeforeRefreshingAfterCurrentItemIsMissing() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RestoredLibrary")
        let allItems = ["A", "Missing", "B", "C"].map {
            makeItem(rootURL: rootURL, name: $0, path: "\($0).mov")
        }
        let availableItems = [allItems[0], allItems[2], allItems[3]]
        var currentItemSeenByShuffler: LibraryMediaItem.ID?
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: availableItems
            ),
            playbackOrder: .shuffled,
            reshuffleRestoredQueue: { queue in
                currentItemSeenByShuffler = queue.currentItem
                var randomSource = TestSeededRandomNumberGenerator(seed: 1)
                queue.reshufflePendingItems(using: &randomSource)
            }
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let snapshot = PlaybackQueueSnapshot(
            items: allItems.map(\.id),
            order: .shuffled,
            currentItem: allItems[1].id,
            roundNumber: 4,
            currentRoundPosition: 2,
            remainingItems: allItems.map(\.id),
            remainingIndex: 2,
            history: [
                PlaybackQueueSnapshotLocation(
                    item: allItems[0].id,
                    roundNumber: 4,
                    position: 1
                )
            ],
            forwardHistory: []
        )

        let result = await fixture.coordinator.restoreQueue(from: snapshot)
        let restoredSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(currentItemSeenByShuffler, allItems[2].id)
        XCTAssertEqual(restoredSnapshot.currentItem, allItems[2].id)
        XCTAssertFalse(restoredSnapshot.items.contains(allItems[1].id))
    }

    func testDiscardingCancelledQueueRestoreReturnsPlaybackToEmptyState() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RestoredLibrary")
        let item = makeItem(
            rootURL: rootURL,
            name: "Restored",
            path: "Restored.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Restored Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        fixture.engine.shouldBlockLoads = true
        let queue = PlaybackQueue(items: [item.id])
        let snapshot = try XCTUnwrap(queue.makeSnapshot())

        let restoreTask = Task {
            await fixture.coordinator.restoreQueue(from: snapshot)
        }
        while !fixture.engine.didBeginBlockedLoad {
            await Task.yield()
        }

        restoreTask.cancel()
        fixture.coordinator.discardRestoredQueue()
        fixture.engine.finishBlockedLoad()
        let didRestore = await restoreTask.value

        XCTAssertEqual(start, .scanStarted)
        XCTAssertEqual(didRestore, .cancelled)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testQueueRestoreWaitsForRequestedRootThatFailedToScan() async throws {
        let availableRootURL = URL(fileURLWithPath: "/tmp/AvailableLibrary")
        let unavailableRootURL = URL(
            fileURLWithPath: "/Volumes/OfflineLibrary"
        )
        let availableItem = makeItem(
            rootURL: availableRootURL,
            name: "Available",
            path: "Available.mov"
        )
        let missingItem = makeItem(
            rootURL: unavailableRootURL,
            name: "Offline",
            path: "Offline.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: availableRootURL,
                        displayName: "Available Library"
                    )
                ],
                items: [availableItem]
            )
        )
        fixture.session.restoredURLs = [
            availableRootURL,
            unavailableRootURL
        ]
        let start = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [missingItem.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(start, .scanStarted)
        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testQueueRestorePreservesUnknownRootWhenBookmarkIsUnavailable() async throws {
        let availableRootURL = URL(fileURLWithPath: "/tmp/AvailableLibrary")
        let unavailableRootURL = URL(
            fileURLWithPath: "/Volumes/UnresolvedLibrary"
        )
        let missingItem = makeItem(
            rootURL: unavailableRootURL,
            name: "Unresolved",
            path: "Unresolved.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: availableRootURL,
                        displayName: "Available Library"
                    )
                ],
                items: []
            )
        )
        fixture.session.restoredURLs = [availableRootURL]
        fixture.session.hasUnavailablePersistedSources = true
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [missingItem.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
    }

    func testQueueRestoreWaitsForMissingItemUnderIncompleteRoot() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/IncompleteLibrary")
        let missingItem = makeItem(
            rootURL: rootURL,
            name: "Temporarily Hidden",
            path: "Unreadable/Hidden.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Incomplete Library"
                    )
                ],
                items: [],
                incompleteRootPaths: [rootURL.standardizedFileURL.path]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [missingItem.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testQueueRestoreTreatsCannotOpenExistingFileAsTemporary() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let item = makeItem(
            rootURL: rootURL,
            name: "Transient",
            path: "Transient.mov"
        )
        try Data([0x00]).write(to: item.url)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Transient Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        fixture.engine.loadErrorsByURL[item.url] = .cannotOpen
        fixture.scanner.availabilityByItemID[item.id] = .available
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [item.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertTrue(fixture.coordinator.hasActiveQueue)
        XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
        XCTAssertFalse(
            fixture.coordinator.unavailableItemIDs.contains(item.id)
        )
    }

    func testQueueRestoreRejectsConfirmedMissingFileAfterSuccessfulScan() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let item = makeItem(
            rootURL: rootURL,
            name: "Deleted After Scan",
            path: "Deleted.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Deleted Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        fixture.engine.loadErrorsByURL[item.url] = .cannotOpen
        fixture.scanner.availabilityByItemID[item.id] = .missing
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [item.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .permanentlyUnavailable)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testQueueRestoreRejectsUnsupportedExistingFile() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let item = makeItem(
            rootURL: rootURL,
            name: "Unsupported",
            path: "Unsupported.mov"
        )
        try Data([0x00]).write(to: item.url)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Unsupported Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        fixture.engine.loadErrorsByURL[item.url] = .unsupported
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [item.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .permanentlyUnavailable)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testQueueRestoreRejectsDeletedMediaFromSuccessfullyScannedRoot() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/DeletedMediaLibrary")
        let deletedItem = makeItem(
            rootURL: rootURL,
            name: "Deleted",
            path: "Deleted.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Deleted Media Library"
                    )
                ],
                items: []
            )
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let queue = PlaybackQueue(items: [deletedItem.id])

        let result = await fixture.coordinator.restoreQueue(
            from: try XCTUnwrap(queue.makeSnapshot())
        )

        XCTAssertEqual(result, .permanentlyUnavailable)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testUnavailableSourceAccessRetriesIntoAvailableLibrary() async {
        let rootURL = URL(
            fileURLWithPath: "/Volumes/Reconnected/Muralume Library",
            isDirectory: true
        )
        let item = makeItem(
            rootURL: rootURL,
            name: "Recovered",
            path: "Recovered.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Recovered Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.hasUnavailablePersistedSources = true

        let start = fixture.coordinator.start()

        XCTAssertEqual(
            start,
            .noRestorableRoots(hasTemporarilyUnavailableRoots: true)
        )
        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertTrue(fixture.coordinator.canRetrySourceAccess)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertTrue(fixture.scanner.scannedSources.isEmpty)

        fixture.session.restoredURLs = [rootURL]
        fixture.session.hasUnavailablePersistedSources = false
        fixture.coordinator.retryUnavailableSourceAccess()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertFalse(fixture.coordinator.canRetrySourceAccess)
        XCTAssertEqual(fixture.coordinator.roots.map(\.url), [rootURL])
        XCTAssertEqual(fixture.coordinator.items, [item])
        XCTAssertEqual(
            fixture.scanner.scannedSources,
            [[MediaSource(url: rootURL, kind: .folder)]]
        )
    }

    func testAnonymousUnavailableBookmarkDoesNotWarnAboutVisibleSources()
        async
    {
        let rootURL = URL(
            fileURLWithPath: "/tmp/Visible Muralume Library",
            isDirectory: true
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Visible Muralume Library"
                    )
                ],
                items: []
            )
        )
        fixture.session.restoredURLs = [rootURL]
        fixture.session.hasUnavailablePersistedSources = true
        fixture.session.exposesUnavailableSourceMetadata = false

        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertTrue(fixture.coordinator.unavailableSources.isEmpty)
        XCTAssertTrue(fixture.coordinator.canRetrySourceAccess)
    }

    func testCancelledAsyncSourceAccessRetryCannotPublishOrStartScan()
        async
    {
        let staleRootURL = URL(
            fileURLWithPath: "/Volumes/Stale/Muralume Library",
            isDirectory: true
        )
        let fixture = makeControlledRetryFixture(snapshot: .empty)
        _ = fixture.coordinator.start()

        let retryTask = Task {
            await fixture.coordinator.retryUnavailableSourceAccessAsync()
        }
        for _ in 0..<1_000 where !fixture.session.asyncRetryDidBegin {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.asyncRetryDidBegin)

        retryTask.cancel()
        fixture.session.completeAsyncRetry(
            with: [MediaSource(url: staleRootURL, kind: .folder)]
        )

        let retryDisposition = await retryTask.value
        XCTAssertEqual(retryDisposition, .alreadyStarted)
        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.scanner.scannedSources.isEmpty)
    }

    func testManualRefreshDoesNotDiscardInFlightSourceRetryResult() async {
        let availableRootURL = URL(
            fileURLWithPath: "/Volumes/Available/Muralume Library",
            isDirectory: true
        )
        let recoveredRootURL = URL(
            fileURLWithPath: "/Volumes/Recovered/Muralume Library",
            isDirectory: true
        )
        let availableSource = MediaSource(
            url: availableRootURL,
            kind: .folder
        )
        let recoveredSource = MediaSource(
            url: recoveredRootURL,
            kind: .folder
        )
        let fixture = makeControlledRetryFixture(snapshot: .empty)
        _ = fixture.coordinator.start()
        fixture.session.synchronousRetrySources = [availableSource]
        XCTAssertEqual(
            fixture.coordinator.retryUnavailableSourceAccess(),
            .scanStarted
        )
        await waitForScan(fixture.coordinator)

        let retryTask = Task {
            await fixture.coordinator.retryUnavailableSourceAccessAsync()
        }
        for _ in 0..<1_000 where !fixture.session.asyncRetryDidBegin {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.asyncRetryDidBegin)

        fixture.coordinator.refresh()
        fixture.session.hasUnavailablePersistedSources = false
        fixture.session.completeAsyncRetry(
            with: [availableSource, recoveredSource]
        )

        let retryDisposition = await retryTask.value
        XCTAssertEqual(retryDisposition, .scanStarted)
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(
            fixture.scanner.scannedSources.last,
            [availableSource, recoveredSource]
        )
        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
    }

    func testCancelledAsyncStartupKeepsUnavailableSourcesRetryableWithoutScan()
        async
    {
        let fixture = makeControlledRetryFixture(snapshot: .empty)

        let startupTask = Task {
            await fixture.coordinator.startAsync()
        }
        for _ in 0..<1_000 where !fixture.session.asyncRestoreDidBegin {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.asyncRestoreDidBegin)

        startupTask.cancel()
        fixture.session.completeAsyncRestore(with: [])

        let startupDisposition = await startupTask.value
        XCTAssertEqual(startupDisposition, .alreadyStarted)
        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertTrue(fixture.coordinator.canRetrySourceAccess)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertTrue(fixture.scanner.scannedSources.isEmpty)
    }

    func testCancelledAsyncStartupDefersAccessibleSourcesWithoutScan()
        async
    {
        let rootURL = URL(
            fileURLWithPath: "/Volumes/Deferred/Muralume Library",
            isDirectory: true
        )
        let fixture = makeControlledRetryFixture(snapshot: .empty)
        fixture.session.hasUnavailablePersistedSources = false

        let startupTask = Task {
            await fixture.coordinator.startAsync()
        }
        for _ in 0..<1_000 where !fixture.session.asyncRestoreDidBegin {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.asyncRestoreDidBegin)

        startupTask.cancel()
        fixture.session.completeAsyncRestore(
            with: [MediaSource(url: rootURL, kind: .folder)]
        )

        let startupDisposition = await startupTask.value
        XCTAssertEqual(startupDisposition, .alreadyStarted)
        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertTrue(fixture.coordinator.canRefresh)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertTrue(fixture.scanner.scannedSources.isEmpty)

        XCTAssertTrue(
            fixture.coordinator.refreshDeferredSourcesIfNeeded()
        )
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(
            fixture.scanner.scannedSources,
            [[MediaSource(url: rootURL, kind: .folder)]]
        )
        XCTAssertFalse(
            fixture.coordinator.refreshDeferredSourcesIfNeeded()
        )
    }

    func testSyncRetrySupersedesOlderAsyncRetryResult() async {
        let staleRootURL = URL(
            fileURLWithPath: "/Volumes/Stale/Muralume Library",
            isDirectory: true
        )
        let currentRootURL = URL(
            fileURLWithPath: "/Volumes/Current/Muralume Library",
            isDirectory: true
        )
        let currentItem = makeItem(
            rootURL: currentRootURL,
            name: "Current",
            path: "Current.mov"
        )
        let fixture = makeControlledRetryFixture(
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: currentRootURL,
                        displayName: "Current Library"
                    )
                ],
                items: [currentItem]
            )
        )
        _ = fixture.coordinator.start()

        let staleRetryTask = Task {
            await fixture.coordinator.retryUnavailableSourceAccessAsync()
        }
        for _ in 0..<1_000 where !fixture.session.asyncRetryDidBegin {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.asyncRetryDidBegin)

        let currentSource = MediaSource(
            url: currentRootURL,
            kind: .folder
        )
        fixture.session.synchronousRetrySources = [currentSource]
        fixture.session.hasUnavailablePersistedSources = false
        XCTAssertEqual(
            fixture.coordinator.retryUnavailableSourceAccess(),
            .scanStarted
        )

        fixture.session.completeAsyncRetry(
            with: [MediaSource(url: staleRootURL, kind: .folder)]
        )
        let staleRetryDisposition = await staleRetryTask.value
        XCTAssertEqual(staleRetryDisposition, .alreadyStarted)
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertEqual(fixture.coordinator.roots.map(\.url), [currentRootURL])
        XCTAssertEqual(fixture.coordinator.items, [currentItem])
        XCTAssertEqual(fixture.scanner.scannedSources, [[currentSource]])
    }

    func testRetryParentTakeoverDrainsSupersededExactThumbnailRoot()
        async throws
    {
        let folderURL = URL(
            fileURLWithPath: "/tmp/Retry Adoption Drain",
            isDirectory: true
        )
        let fileURL = folderURL.appendingPathComponent("Clip.mov")
        let fileItem = makeFileItem(url: fileURL)
        let folderItem = makeItem(
            rootURL: folderURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let thumbnailProvider = TestMediaThumbnailProvider()
        thumbnailProvider.shouldBlockInvalidation = true
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fileURL,
                        displayName: fileURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [fileItem]
            ),
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.session.restoredURLs = [fileURL]
        fixture.session.hasUnavailablePersistedSources = true
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: folderURL,
                        displayName: folderURL.lastPathComponent
                    )
                ],
                items: [folderItem]
            )
        )
        fixture.session.restoredURLs = [folderURL]
        fixture.session.hasUnavailablePersistedSources = false

        XCTAssertEqual(
            fixture.coordinator.retryUnavailableSourceAccess(),
            .scanStarted
        )
        await waitForScan(fixture.coordinator)

        let parentRoot = try XCTUnwrap(fixture.coordinator.roots.first)
        let exactFileRootID = MediaLibraryRoot.ID(
            standardizedPath: fileURL.standardizedFileURL.path
        )
        let removalTask = Task {
            await fixture.coordinator.removeRoot(parentRoot)
        }
        for _ in 0..<1_000 {
            if thumbnailProvider.invalidatedRootIDs == [parentRoot.id] {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            thumbnailProvider.invalidatedRootIDs,
            [parentRoot.id]
        )
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        thumbnailProvider.finishInvalidation(for: parentRoot.id)
        for _ in 0..<1_000 {
            if thumbnailProvider.invalidatedRootIDs
                == [parentRoot.id, exactFileRootID] {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            thumbnailProvider.invalidatedRootIDs,
            [parentRoot.id, exactFileRootID]
        )
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        thumbnailProvider.finishInvalidation(for: exactFileRootID)
        await removalTask.value

        XCTAssertEqual(fixture.session.removedURLs, [folderURL])
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
    }

    func testFailedSourceAccessRetryRemainsTemporaryAndRetryable() {
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: .empty
        )
        fixture.session.hasUnavailablePersistedSources = true
        _ = fixture.coordinator.start()

        fixture.coordinator.retryUnavailableSourceAccess()

        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertTrue(fixture.coordinator.canRetrySourceAccess)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.scanner.scannedSources.isEmpty)
    }

    func testPartialSourceAccessCanResolveWithoutRescanningActiveRoots()
        async
    {
        let rootURL = URL(
            fileURLWithPath: "/tmp/Muralume Available Library",
            isDirectory: true
        )
        let item = makeItem(
            rootURL: rootURL,
            name: "Available",
            path: "Available.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Available Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        fixture.session.hasUnavailablePersistedSources = true
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        let scanCount = fixture.scanner.scannedSources.count

        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .partiallyUnavailable
        )
        XCTAssertTrue(fixture.coordinator.canRetrySourceAccess)

        fixture.session.hasUnavailablePersistedSources = false
        fixture.coordinator.retryUnavailableSourceAccess()

        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertFalse(fixture.coordinator.canRetrySourceAccess)
        XCTAssertEqual(fixture.scanner.scannedSources.count, scanCount)
        XCTAssertEqual(fixture.coordinator.items, [item])
    }

    func testReauthorizationCancelIsInertAndSuccessExpandsQueueWithoutReload()
        async throws {
        let availableRootURL = URL(
            fileURLWithPath: "/tmp/Muralume Existing Library",
            isDirectory: true
        )
        let reauthorizedRootURL = URL(
            fileURLWithPath: "/Volumes/Reauthorized/Muralume Library",
            isDirectory: true
        )
        let currentItem = makeItem(
            rootURL: availableRootURL,
            name: "Current",
            path: "Current.mov"
        )
        let recoveredItem = makeItem(
            rootURL: reauthorizedRootURL,
            name: "Recovered",
            path: "Recovered.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            subsequentSelectedURLs: [[reauthorizedRootURL]],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: availableRootURL,
                        displayName: "Existing Library"
                    )
                ],
                items: [currentItem]
            )
        )
        fixture.session.restoredURLs = [availableRootURL]
        fixture.session.hasUnavailablePersistedSources = true
        _ = fixture.coordinator.start()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(currentItem)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.engine.progressHandler?(27)
        let queueBeforeReauthorization = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        let playbackTime = fixture.playback.currentTime
        let scanCountBeforeCancel = fixture.scanner.scannedSources.count

        fixture.coordinator.reauthorizeMediaSources()

        XCTAssertTrue(fixture.session.addedURLs.isEmpty)
        XCTAssertEqual(
            fixture.coordinator.sourceAccessState,
            .partiallyUnavailable
        )
        XCTAssertEqual(
            fixture.scanner.scannedSources.count,
            scanCountBeforeCancel
        )
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            queueBeforeReauthorization
        )
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: availableRootURL,
                        displayName: "Existing Library"
                    ),
                    MediaLibraryRoot(
                        url: reauthorizedRootURL,
                        displayName: "Reauthorized Library"
                    )
                ],
                items: [currentItem, recoveredItem]
            )
        )
        fixture.session.hasUnavailablePersistedSources = false
        fixture.coordinator.reauthorizeMediaSources()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(
            fixture.session.addedURLs,
            [reauthorizedRootURL]
        )
        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertEqual(
            Set(fixture.coordinator.items),
            Set([currentItem, recoveredItem])
        )
        let expandedQueueSnapshot = try XCTUnwrap(
            fixture.coordinator.makeQueueSnapshot()
        )
        XCTAssertEqual(
            expandedQueueSnapshot.items,
            [currentItem.id, recoveredItem.id]
        )
        XCTAssertEqual(
            expandedQueueSnapshot.currentItem,
            queueBeforeReauthorization.currentItem
        )
        XCTAssertEqual(
            expandedQueueSnapshot.currentRoundPosition,
            queueBeforeReauthorization.currentRoundPosition
        )
        XCTAssertEqual(
            expandedQueueSnapshot.history,
            queueBeforeReauthorization.history
        )
        XCTAssertEqual(
            expandedQueueSnapshot.forwardHistory,
            queueBeforeReauthorization.forwardHistory
        )
        XCTAssertEqual(fixture.coordinator.upNextItems, [recoveredItem])
        XCTAssertEqual(fixture.coordinator.currentItemID, currentItem.id)
        XCTAssertEqual(fixture.playback.source?.url, currentItem.url)
        XCTAssertEqual(fixture.playback.currentTime, playbackTime)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(
            fixture.sourceSelector.intents,
            [.reauthorizingSources, .reauthorizingSources]
        )
    }

    func testAddAndReauthorizationUseDistinctPickerIntents() {
        let fixture = makeFixture(
            selectedURLs: [],
            subsequentSelectedURLs: [[]],
            snapshot: .empty
        )

        fixture.coordinator.addMedia()
        fixture.coordinator.reauthorizeMediaSources()

        XCTAssertEqual(
            fixture.sourceSelector.intents,
            [.addingMedia, .reauthorizingSources]
        )
    }

}

@MainActor
private struct ControlledRetryFixture {
    let coordinator: MediaLibraryCoordinator
    let session: ControlledRetryMediaAccessSession
    let scanner: TestMediaLibraryScanner
}

@MainActor
private func makeControlledRetryFixture(
    snapshot: MediaLibrarySnapshot
) -> ControlledRetryFixture {
    let playback = PlaybackCoordinator(engine: TestPlaybackEngine())
    let session = ControlledRetryMediaAccessSession()
    let scanner = TestMediaLibraryScanner(snapshot: snapshot)
    let coordinator = MediaLibraryCoordinator(
        playback: playback,
        sourceSelector: TestMediaSourceSelector(selections: [[]]),
        mediaSession: session,
        scanner: scanner,
        mediaThumbnailProvider: TestMediaThumbnailProvider(),
        playbackOrder: .ordered
    )
    return ControlledRetryFixture(
        coordinator: coordinator,
        session: session,
        scanner: scanner
    )
}

@MainActor
private final class ControlledRetryMediaAccessSession: MediaAccessSession {
    var hasUnavailablePersistedSources = true
    var unavailablePersistedSources: [UnavailableMediaSource] {
        guard hasUnavailablePersistedSources else {
            return []
        }
        return [
            UnavailableMediaSource(
                id: .init(rawValue: "controlled-unavailable-source"),
                displayName: "Unavailable Source",
                lastKnownURL: URL(
                    fileURLWithPath: "/Volumes/Unavailable Source",
                    isDirectory: true
                ),
                kind: .folder
            )
        ]
    }
    var synchronousRetrySources: [MediaSource] = []
    private(set) var asyncRestoreDidBegin = false
    private(set) var asyncRetryDidBegin = false
    private var asyncRestoreContinuation:
        CheckedContinuation<[MediaSource], Never>?
    private var asyncRetryContinuation:
        CheckedContinuation<[MediaSource], Never>?

    func restoreSources() -> [MediaSource] {
        []
    }

    func restoreSourcesAsync() async -> [MediaSource] {
        asyncRestoreDidBegin = true
        return await withCheckedContinuation { continuation in
            asyncRestoreContinuation = continuation
        }
    }

    func retryUnavailableSources() -> [MediaSource] {
        synchronousRetrySources
    }

    func retryUnavailableSourcesAsync() async -> [MediaSource] {
        asyncRetryDidBegin = true
        return await withCheckedContinuation { continuation in
            asyncRetryContinuation = continuation
        }
    }

    func completeAsyncRestore(with sources: [MediaSource]) {
        let continuation = asyncRestoreContinuation
        asyncRestoreContinuation = nil
        continuation?.resume(returning: sources)
    }

    func completeAsyncRetry(with sources: [MediaSource]) {
        let continuation = asyncRetryContinuation
        asyncRetryContinuation = nil
        continuation?.resume(returning: sources)
    }

    func stop() {
        completeAsyncRestore(with: [])
        completeAsyncRetry(with: [])
    }
}

private func storageIdentity<Element>(of values: [Element]) -> UInt {
    values.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return 0
        }
        return UInt(bitPattern: baseAddress)
    }
}
