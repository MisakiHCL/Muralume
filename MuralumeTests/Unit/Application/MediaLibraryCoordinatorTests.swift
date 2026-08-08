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
            fixture.scanner.scannedSources,
            [[MediaSource(url: rootURL, kind: .folder)]]
        )
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Clip 2", "Clip 10"]
        )
        XCTAssertEqual(fixture.coordinator.scanState, .ready)
    }

    func testManualRefreshDiscoversNewFolderItemsWithoutRebuildingQueue()
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

        fixture.coordinator.addFolders()
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
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            queueSnapshot
        )
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
        XCTAssertEqual(fixture.coordinator.currentItemID, existingItem.id)
        XCTAssertEqual(fixture.coordinator.queueCount, 1)
        XCTAssertEqual(fixture.playback.source, playbackSource)
        XCTAssertEqual(fixture.playback.currentTime, playbackTime)
        XCTAssertEqual(
            fixture.playback.isPlaybackRequested,
            isPlaybackRequested
        )
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.scanner.scannedSources.count, 2)
    }

    func testAddingVideosImportsAllAndPlaysFirstExplicitFile() async {
        let firstURL = URL(fileURLWithPath: "/tmp/First.mov")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.mp4")
        let first = makeFileItem(url: firstURL, name: "First")
        let second = makeFileItem(url: secondURL, name: "Second")
        let fixture = makeFixture(
            selectedURLs: [],
            selectedVideoURLs: [secondURL, firstURL],
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

        fixture.coordinator.addVideos()
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

    func testImportingCurrentVideoAgainIsIdempotent() async {
        let fileURL = URL(fileURLWithPath: "/tmp/Current.mov")
        let item = makeFileItem(url: fileURL, name: "Current")
        let fixture = makeFixture(
            selectedURLs: [],
            selectedVideoURLs: [fileURL],
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

        fixture.coordinator.addVideos()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let queueRevision = fixture.coordinator.queueRevision

        fixture.coordinator.addVideos()
        await Task.yield()

        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
    }

    func testFolderOnlyImportDoesNotInterruptActiveQueue() async throws {
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
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        let queueSnapshot = fixture.coordinator.makeQueueSnapshot()

        let preparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [secondRootURL],
                autoplayFirstExplicitFile: false
            )
        )
        fixture.coordinator.commitImport(preparation)
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.items.count, 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), queueSnapshot)
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
            selectedURLs: [],
            selectedVideoURLs: [fileURL],
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
        fixture.coordinator.addVideos()
        await waitForScan(fixture.coordinator)
        await waitForLoads(fixture.engine, count: 1)
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
                [folderURL],
                autoplayFirstExplicitFile: false
            )
        )
        fixture.coordinator.commitImport(preparation)
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fileItem.id, folderItem.id)
        XCTAssertEqual(fixture.coordinator.currentItemID, folderItem.id)
        XCTAssertEqual(fixture.coordinator.currentItem?.rootURL, folderURL)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
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
                [fileURL],
                autoplayFirstExplicitFile: true
            )
        )
        fixture.coordinator.commitImport(videoPreparation)
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        let folderPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [folderURL],
                autoplayFirstExplicitFile: false
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
                [firstURL],
                autoplayFirstExplicitFile: true
            )
        )
        fixture.coordinator.commitImport(firstPreparation)
        while !fixture.scanner.didBeginBlockedScan {
            await Task.yield()
        }

        let latestPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [latestURL],
                autoplayFirstExplicitFile: true
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
                [firstURL],
                autoplayFirstExplicitFile: true
            )
        )
        let latestPreparation = try XCTUnwrap(
            fixture.coordinator.prepareImport(
                [latestURL],
                autoplayFirstExplicitFile: true
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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
            selectedURLs: [],
            selectedVideoURLs: [fileURL],
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
        fixture.coordinator.addVideos()
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
                [folderURL],
                autoplayFirstExplicitFile: false
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
        fixture.coordinator.addFolders()
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
                [candidateURL],
                autoplayFirstExplicitFile: true
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
        fixture.coordinator.addFolders()
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
                [candidateURL],
                autoplayFirstExplicitFile: true
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
            selectedVideoURLs: [linkedFileURL],
            snapshot: MediaLibrarySnapshot(
                roots: [folderRoot],
                items: []
            ),
            mediaThumbnailProvider: thumbnailProvider
        )
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addVideos()
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
        fixture.coordinator.addFolders()
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
        fixture.coordinator.addFolders()
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

}
