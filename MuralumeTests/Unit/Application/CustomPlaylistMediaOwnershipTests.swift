import Combine
import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistMediaOwnershipTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/tmp/Playlist Ownership")

    func testVersionOneMigratesWithoutChangingEntryIDsOrOrder() throws {
        var original = CustomPlaylistCollection.empty
        let id = try original.createPlaylist(named: "Legacy")
        try original.add(items: [item("B"), item("A")], to: id)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "accessGrants")
        let migrated = try JSONDecoder().decode(
            CustomPlaylistCollection.self, from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.schemaVersion, CustomPlaylistCollection.currentSchemaVersion)
        XCTAssertEqual(migrated.playlists, original.playlists)
        XCTAssertTrue(migrated.accessGrants.isEmpty)
        XCTAssertTrue(migrated.allEntries.allSatisfy { $0.accessGrantID == nil })
        XCTAssertTrue(migrated.isValid)
    }

    func testSharedGrantRoundTripsAndIsCollectedOnlyAfterLastReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCustomPlaylistStore(fileURL: directory.appendingPathComponent("playlists.json"))
        let first = item("A"), second = item("B")
        let grant = grant()
        var collection = CustomPlaylistCollection.empty
        let firstID = try collection.createPlaylist(named: "First")
        let secondID = try collection.createPlaylist(named: "Second")
        try collection.add(items: [first], to: firstID, grantsByItemID: [first.id: grant])
        // Capture may assign a fresh UUID for the same source; persistence still
        // owns one canonical authorization rather than one bookmark per entry.
        try collection.add(items: [second], to: secondID, grantsByItemID: [second.id: self.grant()])
        XCTAssertEqual(collection.accessGrants.count, 1)
        XCTAssertEqual(Set(collection.allEntries.compactMap(\.accessGrantID)), [grant.id])
        try await store.save(collection)
        let restored = try await store.load()
        XCTAssertEqual(restored, collection)

        XCTAssertTrue(collection.removePlaylist(id: firstID))
        XCTAssertEqual(collection.accessGrants.count, 1)
        let entry = try XCTUnwrap(collection.playlist(id: secondID)?.entries.first)
        try collection.removeEntry(entry.id, from: secondID)
        XCTAssertTrue(collection.accessGrants.isEmpty)
    }

    func testGrantLimitsAndInvalidReferencesNeverReplacePersistedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("playlists.json")
        let store = FileCustomPlaylistStore(fileURL: fileURL)
        var valid = CustomPlaylistCollection.empty
        let id = try valid.createPlaylist(named: "Kept")
        try await store.save(valid)
        let originalData = try Data(contentsOf: fileURL)
        let entry = CustomPlaylistEntry(media: MediaReference(item: item("A")), accessGrantID: UUID())
        let playlist = CustomPlaylist(name: "Invalid", entries: [entry], createdAt: .distantPast, updatedAt: .distantPast)
        let invalid = CustomPlaylistCollection(playlists: [playlist])
        XCTAssertFalse(invalid.isValid)
        do {
            try await store.save(invalid)
            XCTFail("Dangling access grants must fail validation")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        }
        let oversizedGrant = CustomPlaylistMediaGrant(
            sourcePath: sourceURL.path, kind: .folder,
            bookmark: Data(repeating: 1, count: MediaImportPolicy.maximumBookmarkByteCount + 1)
        )
        let before = valid
        XCTAssertThrowsError(try valid.add(
            items: [item("A")], to: id, grantsByItemID: [item("A").id: oversizedGrant]
        ))
        XCTAssertEqual(valid, before)
        let repeated = (0...MediaImportPolicy.maximumActiveSourceCount).map { index in
            CustomPlaylistMediaGrant(sourcePath: "/tmp/Source \(index)", kind: .folder, bookmark: Data([1]))
        }
        let bounded = CustomPlaylistCollection(playlists: [], accessGrants: repeated)
        XCTAssertThrowsError(try JSONDecoder().decode(
            CustomPlaylistCollection.self, from: JSONEncoder().encode(bounded)
        ))
    }

    func testMovedGrantReplacesSameIDAndMergesExistingDestinationAtomically() throws {
        let first = item("A")
        let oldGrant = grant()
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Moved")
        try collection.add(items: [first], to: id, grantsByItemID: [first.id: oldGrant])
        let entry = try XCTUnwrap(collection.allEntries.first)
        let destinationURL = URL(fileURLWithPath: "/tmp/Playlist Destination")
        let moved = LibraryMediaItem(rootURL: destinationURL, rootName: "Destination", url: destinationURL.appendingPathComponent("A.mov"), displayName: "A", relativePath: "A.mov", relativeDirectory: "", creationDate: nil, fileSize: 1)
        let movedGrant = CustomPlaylistMediaGrant(id: oldGrant.id, sourcePath: destinationURL.path, kind: .folder, bookmark: Data([4]))
        XCTAssertTrue(try collection.applyMediaResolution(.init(itemsByEntryID: [entry.id: moved], refreshedGrants: [movedGrant])))
        XCTAssertEqual(collection.accessGrants, [movedGrant])
        XCTAssertEqual(collection.allEntries.first?.id, entry.id)
        XCTAssertEqual(collection.allEntries.first?.media.mediaItemID, moved.id)
        XCTAssertTrue(collection.isValid)

        let other = CustomPlaylistMediaGrant(sourcePath: sourceURL.path, kind: .folder, bookmark: Data([5]))
        let otherID = try collection.createPlaylist(named: "Other")
        try collection.add(items: [item("B")], to: otherID, grantsByItemID: [item("B").id: other])
        let merged = CustomPlaylistMediaGrant(id: other.id, sourcePath: destinationURL.path, kind: .folder, bookmark: Data([6]))
        XCTAssertTrue(try collection.installReauthorizedGrant(merged, legacySourcePath: sourceURL.path))
        XCTAssertEqual(collection.accessGrants.count, 1)
        XCTAssertEqual(collection.accessGrants.first?.id, movedGrant.id)
        XCTAssertEqual(Set(collection.allEntries.compactMap(\.accessGrantID)), [movedGrant.id])
        XCTAssertTrue(collection.isValid)
    }

    func testMovedRootPreservesMissingChildAcrossPersistenceRepeatedResolutionAndRecovery() async throws {
        try await verifyPartialRootMove(reauthorize: false)
    }

    func testReauthorizationRelocatesMissingChildAlongWithSuccessfulChildren() async throws {
        try await verifyPartialRootMove(reauthorize: true)
    }

    func testRootMigrationDoesNotRepairAnUnsafeReferenceIntoAuthorizedMedia() throws {
        let access = grant()
        let escaped = CustomPlaylistEntry(
            media: MediaReference(
                mediaItemID: .init(rootPath: sourceURL.path, relativePath: "../escape.mov"),
                fileIdentity: nil, lastKnownDisplayName: "Escape"
            ), accessGrantID: access.id
        )
        let playlist = CustomPlaylist(
            name: "Untrusted", entries: [escaped], createdAt: .distantPast, updatedAt: .distantPast
        )
        var collection = CustomPlaylistCollection(playlists: [playlist], accessGrants: [access])
        let moved = CustomPlaylistMediaGrant(
            id: access.id, sourcePath: "/tmp/Moved Ownership", kind: .folder, bookmark: access.bookmark
        )
        _ = try collection.applyMediaResolution(.init(
            issuesByEntryID: [escaped.id: .permissionDenied], refreshedGrants: [moved]
        ))
        XCTAssertEqual(collection.allEntries.first?.media, escaped.media)
        XCTAssertEqual(collection.allEntries.first?.id, escaped.id)
    }

    private func verifyPartialRootMove(reauthorize: Bool) async throws {
        let movedURL = URL(fileURLWithPath: "/tmp/Moved Ownership")
        let unrelatedURL = URL(fileURLWithPath: "/tmp/Unrelated Ownership")
        let access = grant()
        let unrelatedGrant = CustomPlaylistMediaGrant(
            sourcePath: unrelatedURL.path, kind: .folder, bookmark: Data([9])
        )
        let identity = MediaFileIdentity(volumeIdentifier: Data([4]), fileIdentifier: Data([5]))
        let first = item("A")
        let missing = LibraryMediaItem(
            rootURL: sourceURL, rootName: "Source", url: sourceURL.appendingPathComponent("Missing.mov"),
            displayName: "Missing", relativePath: "Missing.mov", relativeDirectory: "",
            creationDate: nil, fileSize: 1, fileIdentity: identity
        )
        let unrelated = LibraryMediaItem(
            rootURL: unrelatedURL, rootName: "Other", url: unrelatedURL.appendingPathComponent("Other.mov"),
            displayName: "Other", relativePath: "Other.mov", relativeDirectory: "", creationDate: nil, fileSize: 1
        )
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Partial Move")
        let otherID = try collection.createPlaylist(named: "Unrelated")
        try collection.add(items: [first, missing], to: id, grantsByItemID: [first.id: access, missing.id: access])
        try collection.add(items: [unrelated], to: otherID, grantsByItemID: [unrelated.id: unrelatedGrant])
        let originalEntries = collection.allEntries
        let missingEntry = try XCTUnwrap(collection.playlist(id: id)?.entries.last)
        let state = OwnershipMissingChildState()
        let operations = CustomPlaylistBookmarkOperations(
            resolve: { data in .init(url: data == Data([9]) ? unrelatedURL : movedURL) },
            startAccess: { _ in true }, stopAccess: { _ in }, makeBookmark: { _ in Data([1, 2, 3]) },
            metadata: { url in
                if url == movedURL || url == unrelatedURL {
                    return CustomPlaylistFileMetadata(isDirectory: true, isRegularFile: false)
                }
                if url.lastPathComponent == "Missing.mov", state.isMissing {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
                }
                return CustomPlaylistFileMetadata(fileSize: 1)
            }, canonicalURL: { $0.standardizedFileURL }
        )
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: operations)
        if reauthorize {
            let relocated = CustomPlaylistMediaGrant(
                id: access.id, sourcePath: movedURL.path, kind: .folder, bookmark: access.bookmark
            )
            _ = try collection.installReauthorizedGrant(relocated, legacySourcePath: sourceURL.path)
        }
        let initial = await resolver.resolve(grants: collection.accessGrants, entries: collection.allEntries)
        XCTAssertEqual(initial.issuesByEntryID[missingEntry.id], .fileMissing)
        _ = try collection.applyMediaResolution(initial)
        XCTAssertEqual(collection.allEntries.map(\.id), originalEntries.map(\.id))
        let movedMissing = try XCTUnwrap(collection.playlist(id: id)?.entries.last)
        XCTAssertEqual(movedMissing.media.mediaItemID.rootPath, movedURL.path)
        XCTAssertEqual(movedMissing.media.mediaItemID.relativePath, "Missing.mov")
        XCTAssertEqual(movedMissing.media.fileIdentity, identity)
        XCTAssertEqual(movedMissing.media.lastKnownDisplayName, missingEntry.media.lastKnownDisplayName)
        XCTAssertEqual(collection.playlist(id: otherID)?.entries.first?.media, originalEntries.last?.media)
        XCTAssertTrue(collection.isValid)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCustomPlaylistStore(fileURL: directory.appendingPathComponent("playlists.json"))
        try await store.save(collection)
        collection = try await store.load()
        let repeated = await resolver.resolve(grants: collection.accessGrants, entries: collection.allEntries)
        XCTAssertEqual(repeated.issuesByEntryID[missingEntry.id], .fileMissing)
        XCTAssertEqual(repeated.itemsByEntryID.count, 2)
        state.setMissing(false)
        let recovered = await resolver.resolve(grants: collection.accessGrants, entries: collection.allEntries)
        XCTAssertNil(recovered.issuesByEntryID[missingEntry.id])
        XCTAssertEqual(recovered.itemsByEntryID[missingEntry.id]?.url, movedURL.appendingPathComponent("Missing.mov"))
        _ = try collection.applyMediaResolution(recovered)
        XCTAssertEqual(collection.allEntries.map(\.id), originalEntries.map(\.id))
        XCTAssertEqual(collection.playlist(id: id)?.entries.map(\.media.lastKnownDisplayName), ["A", "Missing"])
        await resolver.shutdown()
    }

    func testCreateCapturesOncePerSourceAndCaptureFailureIsAtomic() async throws {
        let store = OwnershipPlaylistStore(.empty)
        let captured = grant()
        var captureCount = 0
        let controller = CustomPlaylistController(store: store, grantCapture: { _ in
            captureCount += 1
            return captured
        })
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Selected", items: [item("A"), item("B")])
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(controller.collection.accessGrants, [captured])
        XCTAssertEqual(controller.collection.playlist(id: id)?.entries.count, 2)
        await controller.shutdown()

        let failedStore = OwnershipPlaylistStore(.empty)
        let failed = CustomPlaylistController(store: failedStore, grantCapture: { _ in nil })
        await failed.startAndWait()
        let revision = failed.collectionRevision
        XCTAssertThrowsError(try failed.createPlaylist(named: "Failure", items: [item("A")])) {
            XCTAssertEqual($0 as? CustomPlaylistMutationError, .authorizationUnavailable)
        }
        XCTAssertEqual(failed.collectionRevision, revision)
        XCTAssertTrue(failed.playlists.isEmpty)
        await failed.shutdown()
        let failedSaves = await failedStore.savedCollections
        XCTAssertTrue(failedSaves.isEmpty)
    }

    func testOwnedCatalogSurvivesSourceRemovalAndColdRestore() async throws {
        let first = item("A"), second = item("B")
        let access = grant()
        let resolver = OwnershipResolver(items: [first, second])
        let store = OwnershipPlaylistStore(.empty)
        let controller = CustomPlaylistController(store: store, grantCapture: { _ in access }, resolver: resolver)
        await controller.startAndWait()
        controller.updateAvailableItems([first, second], itemsRevision: 1, contentRevision: 1)
        let id = try controller.createPlaylist(named: "Independent", items: [second, first])
        await controller.waitForMediaResolution()
        let root = MediaLibraryRoot(url: sourceURL, displayName: "Source")
        let prepared = await controller.prepareForSourceRemoval(root)
        XCTAssertTrue(prepared)
        controller.updateAvailableItems([], itemsRevision: 2, contentRevision: 2)
        await controller.waitForMediaResolution()
        XCTAssertEqual(controller.resolvedItems(in: id), [second, first])
        let saved = controller.collection
        await controller.shutdown()

        let restored = CustomPlaylistController(store: OwnershipPlaylistStore(saved), resolver: OwnershipResolver(items: [first, second]))
        await restored.startAndWait()
        XCTAssertEqual(restored.resolvedItems(in: id), [second, first])
        XCTAssertEqual(restored.collection.allEntries.map(\.id), saved.allEntries.map(\.id))
        await restored.shutdown()
    }

    func testLegacyBackfillMustResolveAndPersistBeforeSourceCanBeRemoved() async throws {
        let first = item("A")
        var legacy = CustomPlaylistCollection.empty
        let id = try legacy.createPlaylist(named: "Legacy")
        try legacy.add(items: [first], to: id)
        let store = OwnershipPlaylistStore(legacy)
        let access = grant()
        let controller = CustomPlaylistController(store: store, grantCapture: { _ in access }, resolver: OwnershipResolver(items: [first]))
        await controller.startAndWait()
        let entry = try XCTUnwrap(controller.collection.allEntries.first)
        XCTAssertEqual(controller.issue(for: entry), .authorizationRequired)
        await store.setSaveFailure(true)
        controller.updateAvailableItems([first], itemsRevision: 1)
        let rejected = await controller.prepareForSourceRemoval(MediaLibraryRoot(url: sourceURL, displayName: "Source"))
        XCTAssertFalse(rejected)
        XCTAssertNotNil(controller.collection.allEntries.first?.accessGrantID)
        XCTAssertEqual(controller.resolvedItems(in: id), [first])
        await store.setSaveFailure(false)
        let accepted = await controller.prepareForSourceRemoval(MediaLibraryRoot(url: sourceURL, displayName: "Source"))
        XCTAssertTrue(accepted)
        let saved = await store.savedCollections.last
        XCTAssertEqual(saved, controller.collection)
        await controller.shutdown()
    }

    func testMissingLegacyChildUsesExistingSourceBookmarkWithoutRequiringAuthorization() async throws {
        let missing = item("Missing")
        let access = grant()
        var legacy = CustomPlaylistCollection.empty
        let id = try legacy.createPlaylist(named: "Missing Child")
        try legacy.add(items: [missing], to: id)
        let entryIDs = legacy.allEntries.map(\.id)
        let resolver = OwnershipResolver(items: [])
        resolver.failure = .fileMissing
        var sourceCaptureCount = 0
        let controller = CustomPlaylistController(
            store: OwnershipPlaylistStore(legacy),
            sourceGrantCapture: { sourceID in
                sourceCaptureCount += 1
                return sourceID.standardizedPath == access.sourcePath ? access : nil
            }, resolver: resolver
        )
        // No library item exists for the missing file, so only the source's
        // saved Data can establish the correct reason.
        await controller.startAndWait()

        let entry = try XCTUnwrap(controller.collection.allEntries.first)
        XCTAssertEqual(sourceCaptureCount, 1)
        XCTAssertEqual(controller.collection.allEntries.map(\.id), entryIDs)
        XCTAssertEqual(entry.accessGrantID, access.id)
        XCTAssertEqual(controller.collection.accessGrants, [access])
        XCTAssertEqual(controller.issue(for: entry), .fileMissing)
        XCTAssertTrue(controller.resolvedItems(in: id).isEmpty)
        await controller.shutdown()
    }

    func testUnavailableSourceCannotBeRemovedUntilItsLegacyBookmarkIsDurable() async throws {
        let missing = item("Missing")
        let access = grant()
        var legacy = CustomPlaylistCollection.empty
        let id = try legacy.createPlaylist(named: "Offline")
        try legacy.add(items: [missing], to: id)
        let store = OwnershipPlaylistStore(legacy)
        let resolver = OwnershipResolver(items: [])
        resolver.failure = .temporarilyUnavailable
        var canCapture = false
        let controller = CustomPlaylistController(
            store: store,
            sourceGrantCapture: { sourceID in
                canCapture && sourceID.standardizedPath == access.sourcePath ? access : nil
            }, resolver: resolver
        )
        await controller.startAndWait()
        let source = UnavailableMediaSource(
            id: .init(rawValue: "offline-source"), displayName: "Offline",
            lastKnownURL: sourceURL, kind: .folder
        )
        let unavailableWithoutData = await controller.prepareForUnavailableSourceRemoval(source)
        XCTAssertFalse(unavailableWithoutData)
        canCapture = true
        await store.setSaveFailure(true)

        let rejected = await controller.prepareForUnavailableSourceRemoval(source)

        XCTAssertFalse(rejected)
        XCTAssertEqual(controller.collection.accessGrants, [access])
        XCTAssertEqual(controller.collection.allEntries.first?.accessGrantID, access.id)
        let failedSaves = await store.savedCollections
        XCTAssertTrue(failedSaves.isEmpty)
        await store.setSaveFailure(false)
        let accepted = await controller.prepareForUnavailableSourceRemoval(source)
        XCTAssertTrue(accepted)
        let persisted = await store.savedCollections.last
        XCTAssertEqual(persisted, controller.collection)
        XCTAssertEqual(persisted?.accessGrants.first?.bookmark, access.bookmark)
        await controller.shutdown()
    }

    func testReauthorizationBackfillsLegacySourceAcrossPlaylistsAndPersistsBeforeReturning() async throws {
        let first = item("A"), second = item("B")
        var legacy = CustomPlaylistCollection.empty
        let firstID = try legacy.createPlaylist(named: "First")
        let secondID = try legacy.createPlaylist(named: "Second")
        try legacy.add(items: [first], to: firstID)
        try legacy.add(items: [second], to: secondID)
        let ids = legacy.allEntries.map(\.id)
        let resolver = OwnershipResolver(items: [first, second])
        resolver.authorizedGrant = grant()
        let store = OwnershipPlaylistStore(legacy)
        let controller = CustomPlaylistController(store: store, resolver: resolver)
        await controller.startAndWait()
        let entry = try XCTUnwrap(controller.collection.playlist(id: firstID)?.entries.first)
        let source = try XCTUnwrap(controller.reauthorizationSource(for: entry.id, in: firstID))
        XCTAssertEqual(source.lastKnownURL, sourceURL)
        XCTAssertEqual(source.kind, .folder)
        try await controller.reauthorizeEntry(playlistID: firstID, entryID: entry.id, selectedURL: sourceURL)
        XCTAssertEqual(controller.collection.allEntries.map(\.id), ids)
        XCTAssertEqual(controller.collection.accessGrants.count, 1)
        XCTAssertEqual(controller.resolvedItems(in: firstID), [first])
        XCTAssertEqual(controller.resolvedItems(in: secondID), [second])
        let saved = await store.savedCollections.last
        XCTAssertEqual(saved, controller.collection)
        await controller.shutdown()
    }

    func testIssueChangesHaveTheirOwnRevisionAndPlaylistRenameDoesNotResolveAgain() async throws {
        let first = item("A")
        let access = grant()
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Offline")
        try collection.add(items: [first], to: id, grantsByItemID: [first.id: access])
        let resolver = OwnershipResolver(items: [])
        resolver.failure = .fileMissing
        let controller = CustomPlaylistController(store: OwnershipPlaylistStore(collection), resolver: resolver)
        await controller.startAndWait()
        let entry = try XCTUnwrap(controller.collection.allEntries.first)
        let revision = controller.resolutionRevision
        let availability = controller.availabilityRevision
        XCTAssertEqual(controller.issue(for: entry), .fileMissing)
        let count = resolver.resolveCount
        try controller.renamePlaylist(id: id, to: "Renamed")
        await controller.waitForMediaResolution()
        XCTAssertEqual(resolver.resolveCount, count)
        resolver.failure = .permissionDenied
        controller.retryResolution()
        await controller.waitForMediaResolution()
        XCTAssertEqual(controller.resolutionRevision, revision)
        XCTAssertGreaterThan(controller.availabilityRevision, availability)
        XCTAssertEqual(controller.issue(for: entry), .permissionDenied)
        await controller.shutdown()
    }

    func testLateResolutionCannotReintroduceDeletedEntries() async throws {
        let first = item("A")
        let access = grant()
        let resolver = OwnershipResolver(items: [first])
        let controller = CustomPlaylistController(store: OwnershipPlaylistStore(.empty), grantCapture: { _ in access }, resolver: resolver)
        await controller.startAndWait()
        resolver.blockNext = true
        let id = try controller.createPlaylist(named: "Temporary", items: [first])
        await waitUntil { resolver.isBlocked }
        try controller.removePlaylist(id: id)
        resolver.finishBlocked()
        await controller.waitForMediaResolution()
        XCTAssertTrue(controller.resolutionItems.isEmpty)
        XCTAssertTrue(controller.collection.accessGrants.isEmpty)
        XCTAssertEqual(resolver.maximumConcurrentResolutions, 1)
        await controller.shutdown()
        XCTAssertTrue(resolver.didShutdown)
    }

    func testBridgeRetainsActiveOwnedQueueWhileAllEntriesAreTemporarilyUnavailable() async throws {
        let lease = MediaSourceAccessLease(retaining: OwnershipAccessOwner())
        let first = item("A", accessLease: lease)
        let second = item("B", accessLease: lease)
        let access = grant()
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Independent")
        try collection.add(
            items: [first, second], to: id,
            grantsByItemID: [first.id: access, second.id: access]
        )
        let resolver = OwnershipResolver(items: [first, second])
        let playlists = CustomPlaylistController(
            store: OwnershipPlaylistStore(collection), resolver: resolver
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: .empty)
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let bridge = CustomPlaylistPlaybackBridge(playlists: playlists, library: fixture.coordinator)
        await bridge.startAndWait()
        fixture.coordinator.playCustomPlaylistItem(
            first, playlistID: id, playlistItems: playlists.resolvedItems(in: id)
        )
        await waitUntil {
            fixture.engine.loadedSources.count == 1 && fixture.playback.readiness == .ready
        }
        fixture.playback.setPlaybackIntent(.paused)
        let queue = try XCTUnwrap(fixture.coordinator.makeQueueSnapshot())
        let current = fixture.coordinator.currentItemID
        let entryIDs = playlists.collection.allEntries.map(\.id)
        let synchronizationCount = bridge.activeQueueSynchronizationCount

        resolver.items = []
        resolver.failure = .temporarilyUnavailable
        playlists.retryResolution()
        await playlists.waitForMediaResolution()

        XCTAssertTrue(playlists.resolutionItems.isEmpty)
        XCTAssertEqual(playlists.collection.allEntries.map(\.id), entryIDs)
        XCTAssertTrue(playlists.collection.allEntries.allSatisfy {
            playlists.issue(for: $0) == .temporarilyUnavailable
        })
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), queue)
        XCTAssertEqual(fixture.coordinator.currentItemID, current)
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .customPlaylist(id))
        XCTAssertEqual(bridge.activeQueueSynchronizationCount, synchronizationCount)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)

        resolver.items = [first, second]
        playlists.retryResolution()
        await playlists.waitForMediaResolution()

        XCTAssertEqual(playlists.resolvedItems(in: id), [first, second])
        XCTAssertGreaterThan(bridge.activeQueueSynchronizationCount, synchronizationCount)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), queue)
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .customPlaylist(id))
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitUntil {
            fixture.engine.loadedSources.count == 2 && fixture.playback.readiness == .ready
        }
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.engine.loadedSources.last?.accessLease, lease)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testUnavailableOwnedQueueStillAppliesEditsWithoutAddingUnresolvedEntries() async throws {
        let lease = MediaSourceAccessLease(retaining: OwnershipAccessOwner())
        let first = item("A", accessLease: lease)
        let second = item("B", accessLease: lease)
        let unresolved = item("C")
        let access = grant()
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Offline Edits")
        try collection.add(
            items: [first, second], to: id,
            grantsByItemID: [first.id: access, second.id: access]
        )
        let originalEntries = try XCTUnwrap(collection.playlist(id: id)).entries
        let resolver = OwnershipResolver(items: [first, second])
        let playlists = CustomPlaylistController(
            store: OwnershipPlaylistStore(collection),
            grantCapture: { _ in access }, resolver: resolver
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: .empty)
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let bridge = CustomPlaylistPlaybackBridge(playlists: playlists, library: fixture.coordinator)
        await bridge.startAndWait()
        fixture.coordinator.playCustomPlaylistItem(
            first, playlistID: id, playlistItems: playlists.resolvedItems(in: id)
        )
        await waitUntil {
            fixture.engine.loadedSources.count == 1 && fixture.playback.readiness == .ready
        }

        resolver.items = []
        resolver.failure = .temporarilyUnavailable
        playlists.retryResolution()
        await playlists.waitForMediaResolution()
        XCTAssertTrue(playlists.resolutionItems.isEmpty)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [first.id, second.id])

        try playlists.removeEntry(originalEntries[1].id, from: id)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [first.id])
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.coordinator.currentItem?.accessLease, lease)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        try playlists.add(items: [unresolved], to: id)
        await playlists.waitForMediaResolution()
        XCTAssertEqual(playlists.collection.playlist(id: id)?.entries.count, 2)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [first.id])
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)

        // Removing the last previously playable entry must stop its old
        // representation, even though a newly added unresolved entry remains.
        try playlists.removeEntry(originalEntries[0].id, from: id)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        await playlists.waitForMediaResolution()
        XCTAssertEqual(playlists.collection.playlist(id: id)?.entries.count, 1)
        XCTAssertTrue(playlists.resolvedItems(in: id).isEmpty)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testResolutionPublisherProvidesIncomingEntryMapBeforeCurrentSnapshotChanges() async throws {
        let first = item("A")
        let access = grant()
        let resolver = OwnershipResolver(items: [first])
        let controller = CustomPlaylistController(store: OwnershipPlaylistStore(.empty), grantCapture: { _ in access }, resolver: resolver)
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Incoming", items: [first])
        var observed = false
        let observation = controller.resolutionPublisher.dropFirst().sink { snapshot in
            guard !snapshot.items.isEmpty else { return }
            observed = true
            XCTAssertTrue(controller.resolutionItems.isEmpty)
            XCTAssertEqual(controller.resolvedItems(in: id, usingEntryItems: snapshot.itemsByEntryID), [first])
        }
        await controller.waitForMediaResolution()
        XCTAssertTrue(observed)
        XCTAssertEqual(controller.resolvedItems(in: id), [first])
        observation.cancel()
        await controller.shutdown()
    }

    func testLegacyPublisherUsesIncomingContentAndKeepsRevisionForLibrarySort() async throws {
        let controller = CustomPlaylistController(store: OwnershipPlaylistStore(.empty))
        await controller.startAndWait()
        let first = item("A"), second = item("B")
        var incoming: [[LibraryMediaItem]] = []
        let observation = controller.resolutionPublisher.dropFirst().sink { incoming.append($0.items) }
        controller.updateAvailableItems([first, second], itemsRevision: 1, contentRevision: 7)
        let revision = controller.resolutionRevision
        controller.updateAvailableItems([second, first], itemsRevision: 2, contentRevision: 7)
        XCTAssertEqual(incoming, [[first, second], [second, first]])
        XCTAssertEqual(controller.resolutionItems, [second, first])
        XCTAssertEqual(controller.resolutionRevision, revision)
        observation.cancel()
        await controller.shutdown()
    }

    private func item(_ name: String, accessLease: MediaSourceAccessLease? = nil) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: sourceURL, rootName: "Source",
            url: sourceURL.appendingPathComponent("\(name).mov"), displayName: name,
            relativePath: "\(name).mov", relativeDirectory: "", creationDate: nil,
            fileSize: 1, accessLease: accessLease
        )
    }

    private func grant() -> CustomPlaylistMediaGrant {
        CustomPlaylistMediaGrant(sourcePath: sourceURL.path, kind: .folder, bookmark: Data([1, 2, 3]))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for resolver gate")
    }
}

private final class OwnershipAccessOwner: @unchecked Sendable {}

private final class OwnershipMissingChildState: @unchecked Sendable {
    private let lock = NSLock()
    private var missing = true
    var isMissing: Bool { lock.withLock { missing } }
    func setMissing(_ value: Bool) { lock.withLock { missing = value } }
}

private actor OwnershipPlaylistStore: CustomPlaylistStoring {
    let initial: CustomPlaylistCollection
    private(set) var savedCollections: [CustomPlaylistCollection] = []
    private var shouldFail = false

    init(_ initial: CustomPlaylistCollection) { self.initial = initial }
    func load() -> CustomPlaylistCollection { initial }
    func setSaveFailure(_ value: Bool) { shouldFail = value }
    func save(_ collection: CustomPlaylistCollection) throws {
        if shouldFail { throw CustomPlaylistStoreError.invalidCollection }
        savedCollections.append(collection)
    }
}

@MainActor
private final class OwnershipResolver: CustomPlaylistMediaAccessResolving {
    var items: [LibraryMediaItem]
    var failure: CustomPlaylistMediaIssue = .fileMissing
    var authorizedGrant: CustomPlaylistMediaGrant?
    var blockNext = false
    private(set) var isBlocked = false
    private(set) var resolveCount = 0
    private(set) var maximumConcurrentResolutions = 0
    private(set) var didShutdown = false
    private var concurrent = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(items: [LibraryMediaItem]) { self.items = items }

    func resolve(grants: [CustomPlaylistMediaGrant], entries: [CustomPlaylistEntry]) async -> CustomPlaylistMediaResolution {
        resolveCount += 1
        concurrent += 1
        maximumConcurrentResolutions = max(maximumConcurrentResolutions, concurrent)
        defer { concurrent -= 1 }
        if blockNext {
            blockNext = false
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
            isBlocked = false
        }
        let grantIDs = Set(grants.map(\.id))
        var result = CustomPlaylistMediaResolution()
        result.authorizedRootIDs = Set(grants.map { MediaLibraryRoot.ID(standardizedPath: $0.sourcePath) })
        for entry in entries {
            guard let id = entry.accessGrantID, grantIDs.contains(id) else {
                result.issuesByEntryID[entry.id] = .authorizationRequired
                continue
            }
            if let item = items.first(where: { $0.id == entry.media.mediaItemID }) {
                result.itemsByEntryID[entry.id] = item
            } else {
                result.issuesByEntryID[entry.id] = failure
            }
        }
        return result
    }

    func authorize(selectedURL: URL, sourcePath: String, kind: MediaSourceKind, grantID: UUID?) async -> CustomPlaylistMediaGrant? {
        authorizedGrant
    }

    func finishBlocked() { continuation?.resume(); continuation = nil }
    func shutdown() async { didShutdown = true }
}
