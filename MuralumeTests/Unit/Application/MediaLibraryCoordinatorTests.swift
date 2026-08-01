import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryCoordinatorTests: XCTestCase {
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

        fixture.coordinator.addFolders()
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

    func testAddingFoldersScansAndPublishesSortedPlaylist() async {
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

        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.session.addedURLs, [rootURL])
        XCTAssertEqual(fixture.scanner.scannedRootURLs, [[rootURL]])
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Clip 2", "Clip 10"]
        )
        XCTAssertEqual(fixture.coordinator.scanState, .ready)
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
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(item)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        guard let root = fixture.coordinator.roots.first else {
            return XCTFail("Expected the selected root to be available.")
        }
        fixture.coordinator.removeRoot(root)

        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
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
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.removeRoot(secondRoot)

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
    }

    func testClickingVisibleItemRebuildsQueueFromCurrentSortOrder() async {
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)

        fixture.engine.emitItemEnded()
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(fixture.engine.loadedSources.last?.displayName, "Second")
        XCTAssertEqual(fixture.coordinator.currentItem?.id, second.id)
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
        fixture.session.hasUnavailablePersistedFolders = true
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

}
