import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaLibrarySourceHealthTests: XCTestCase {
    private let root = MediaLibraryRoot(
        url: URL(fileURLWithPath: "/tmp/Source Health Library"), displayName: "Library"
    )

    func testOnlyCompleteRootAdvancesSuccessfulRefreshDate() {
        let other = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/tmp/Source Health Other"), displayName: "Other"
        )
        let sources = [root, other].map { MediaSource(url: $0.url, kind: .folder) }
        let earlier = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 20)
        let previous = [root.id: MediaLibrarySourceHealth(
            status: .ready, lastSuccessfulRefresh: earlier
        ), other.id: MediaLibrarySourceHealth(status: .ready, lastSuccessfulRefresh: earlier)]
        let snapshot = MediaLibrarySnapshot(
            roots: [root, other], items: [], sourceDiagnostics: [
                other.id: .init(coverage: .incomplete, issue: .permissionDenied)
            ]
        )
        let next = MediaLibrarySourceHealthReducer.completed(
            previous, snapshot: snapshot, sources: sources, now: later
        )
        XCTAssertEqual(next[root.id]?.status, .ready)
        XCTAssertEqual(next[root.id]?.lastSuccessfulRefresh, later)
        XCTAssertEqual(next[other.id]?.status, .incomplete)
        XCTAssertEqual(next[other.id]?.issue, .permissionDenied)
        XCTAssertEqual(next[other.id]?.lastSuccessfulRefresh, earlier)
        XCTAssertTrue(snapshot.incompleteRootPaths.contains(other.id.standardizedPath))
    }

    func testUnobservedRestoredSourceHasUnknownReasonAndNoInventedDate() {
        let source = UnavailableMediaSource(
            id: .init(rawValue: "stored"), displayName: root.displayName,
            lastKnownURL: root.url, kind: .folder
        )
        let health = MediaLibrarySourceHealthReducer.reconcile(
            [:], active: [], unavailable: [source]
        )[root.id]
        XCTAssertEqual(health?.status, .unavailable)
        XCTAssertEqual(health?.issue, .unknown)
        XCTAssertNil(health?.lastSuccessfulRefresh)
        XCTAssertEqual(MediaLibrarySourceHealthIssue.filesystemError(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        ), .unknown)
        XCTAssertEqual(MediaLibrarySourceHealthIssue.filesystemError(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ), .permissionDenied)
    }

    func testUnavailableRecordDoesNotBorrowSamePathActiveHealthOrDate() async throws {
        let active = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/Volumes/Unavailable Source"), displayName: "Active Source"
        )
        let fixture = makeFixture(
            selectedURLs: [active.url], snapshot: .init(roots: [active], items: [])
        )
        fixture.session.hasUnavailablePersistedSources = true
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: active).status, .ready)
        XCTAssertNotNil(fixture.coordinator.sourceHealth(for: active).lastSuccessfulRefresh)
        let records = [MediaSourceKind.folder, .file].map { kind in
            UnavailableMediaSource(
                id: .init(rawValue: "unavailable-" + kind.rawValue), displayName: "Stored Source",
                lastKnownURL: active.url, kind: kind, issue: .permissionDenied
            )
        }
        for record in records {
            let health = fixture.coordinator.sourceHealth(for: record)
            XCTAssertEqual(health.status, .unavailable)
            XCTAssertEqual(health.issue, .permissionDenied)
            XCTAssertNil(health.lastSuccessfulRefresh)
        }
        let preservedRecord = try XCTUnwrap(fixture.coordinator.unavailableSources.first)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: preservedRecord).issue, .unknown)
        XCTAssertNil(fixture.coordinator.sourceHealth(for: active).issue)
        fixture.scanner.blockNextScan()
        fixture.coordinator.refresh()
        while !fixture.scanner.didBeginBlockedScan { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: active).status, .scanning)
        for record in records {
            let health = fixture.coordinator.sourceHealth(for: record)
            XCTAssertEqual(health.status, .unavailable)
            XCTAssertEqual(health.issue, .permissionDenied)
            XCTAssertNil(health.lastSuccessfulRefresh)
        }
        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)
        await fixture.coordinator.shutdown()
    }

    func testExplicitReauthorizationClearsOnlySelectedSamePathUnavailableRecord() async throws {
        let active = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/Volumes/Unavailable Source"), displayName: "Active Source"
        )
        for useAsyncAPI in [false, true] {
            let fixture = makeFixture(
                selectedURLs: [active.url], subsequentSelectedURLs: [[active.url], [active.url]],
                snapshot: .init(roots: [active], items: [])
            )
            fixture.session.hasUnavailablePersistedSources = true
            fixture.coordinator.addMedia()
            await waitForScan(fixture.coordinator)
            let unavailable = try XCTUnwrap(fixture.coordinator.unavailableSources.first)
            let result: MediaLibraryStartDisposition?
            if useAsyncAPI {
                result = await fixture.coordinator.reauthorizeMediaSourceAsync(unavailable)
            } else {
                result = fixture.coordinator.reauthorizeMediaSource(unavailable)
            }
            XCTAssertEqual(result, .scanStarted)
            await waitForScan(fixture.coordinator)
            XCTAssertEqual(fixture.session.removedUnavailableSources, [unavailable])
            XCTAssertTrue(fixture.coordinator.unavailableSources.isEmpty)
            XCTAssertEqual(fixture.coordinator.sourceRoots.map(\.id), [active.id])
            XCTAssertEqual(fixture.coordinator.sourceHealth(for: active).status, .ready)
            XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)

            // An active-row recovery must not consume another stored record,
            // even when its path happens to match the newly refreshed grant.
            fixture.session.hasUnavailablePersistedSources = true
            fixture.scanner.enqueueScanError(.permissionDenied(active.url))
            fixture.coordinator.refresh()
            await waitForScan(fixture.coordinator)
            let activeDescriptor = try XCTUnwrap(
                fixture.coordinator.reauthorizationSource(for: active)
            )
            if useAsyncAPI {
                _ = await fixture.coordinator.reauthorizeMediaSourceAsync(activeDescriptor)
            } else {
                _ = fixture.coordinator.reauthorizeMediaSource(activeDescriptor)
            }
            await waitForScan(fixture.coordinator)
            XCTAssertEqual(fixture.session.removedUnavailableSources, [unavailable])
            XCTAssertEqual(fixture.coordinator.unavailableSources.count, 1)
            await fixture.coordinator.shutdown()
        }
    }

    func testUnavailableRecordKeepsObservedDateWhenNoActiveSourceSharesItsPath() async throws {
        let active = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/Volumes/Unavailable Source"), displayName: "Active Source"
        )
        let fixture = makeFixture(
            selectedURLs: [active.url], snapshot: .init(roots: [active], items: [])
        )
        fixture.session.hasUnavailablePersistedSources = true
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let date = fixture.coordinator.sourceHealth(for: active).lastSuccessfulRefresh
        XCTAssertNotNil(date)
        await fixture.coordinator.removeRoot(active)
        XCTAssertTrue(fixture.coordinator.sourceRoots.isEmpty)
        let source = try XCTUnwrap(fixture.coordinator.unavailableSources.first)
        let health = fixture.coordinator.sourceHealth(for: source)
        XCTAssertEqual(health.status, .unavailable)
        XCTAssertEqual(health.issue, .unknown)
        XCTAssertEqual(health.lastSuccessfulRefresh, date)
        await fixture.coordinator.shutdown()
    }

    func testFilesystemClassifierOnlyPromotesExplicitPermissionEvidence() {
        for code in [EACCES, EPERM] {
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let wrapped = NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSUnderlyingErrorKey: underlying]
            )
            XCTAssertEqual(MediaLibrarySourceHealthIssue.filesystemError(wrapped), .permissionDenied)
        }
        for code in [ENOENT, EIO, ENODEV] {
            XCTAssertEqual(MediaLibrarySourceHealthIssue.filesystemError(
                NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            ), .unknown)
        }
    }

    func testLimitAndRetryPreserveLastSuccessAndRemovalPrunesState() {
        let source = MediaSource(url: root.url, kind: .folder)
        let date = Date(timeIntervalSince1970: 30)
        let old = [root.id: MediaLibrarySourceHealth(status: .ready, lastSuccessfulRefresh: date)]
        let scanning = MediaLibrarySourceHealthReducer.scanning(old, sources: [source])
        XCTAssertEqual(scanning[root.id]?.status, .scanning)
        let failed = MediaLibrarySourceHealthReducer.failed(
            scanning, sources: [source], issue: .memoryLimitExceeded
        )
        XCTAssertEqual(failed[root.id]?.issue, .memoryLimitExceeded)
        XCTAssertEqual(failed[root.id]?.lastSuccessfulRefresh, date)
        XCTAssertTrue(MediaLibrarySourceHealthReducer.reconcile(
            failed, active: [], unavailable: []
        ).isEmpty)
    }

    func testPartialScanRetainsFailedActiveSourceAndQueuedMedia() async {
        let other = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/tmp/Source Health Other"), displayName: "Other"
        )
        let first = makeItem(rootURL: root.url, name: "First", path: "First.mp4")
        let second = makeItem(rootURL: other.url, name: "Second", path: "Second.mp4")
        let fixture = makeFixture(
            selectedURLs: [root.url, other.url],
            snapshot: MediaLibrarySnapshot(roots: [root, other], items: [first, second])
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.playLibraryItem(second)
        let priorDate = fixture.coordinator.sourceHealth(for: other).lastSuccessfulRefresh
        fixture.scanner.enqueueSnapshot(MediaLibrarySnapshot(
            roots: [root], items: [first], sourceDiagnostics: [
                other.id: .init(coverage: .unavailable, issue: .permissionDenied)
            ]
        ))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(Set(fixture.coordinator.sourceRoots.map(\.id)), [root.id, other.id])
        XCTAssertEqual(fixture.coordinator.roots, [root])
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: other).status, .unavailable)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: other).issue, .permissionDenied)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: other).lastSuccessfulRefresh, priorDate)
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertNotNil(fixture.coordinator.reauthorizationSource(for: other))
        await fixture.coordinator.shutdown()
    }

    func testUnchangedCompleteRefreshStillPublishesSuccessAndRecoversHealth() async {
        let item = makeItem(rootURL: root.url, name: "Video", path: "Video.mp4")
        let fixture = makeFixture(
            selectedURLs: [root.url], snapshot: .init(roots: [root], items: [item])
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let revision = fixture.coordinator.itemsRevision
        let firstDate = fixture.coordinator.sourceHealth(for: root).lastSuccessfulRefresh
        XCTAssertNotNil(firstDate)
        fixture.coordinator.refresh()
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).status, .scanning)
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.itemsRevision, revision)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).status, .ready)
        XCTAssertGreaterThanOrEqual(
            fixture.coordinator.sourceHealth(for: root).lastSuccessfulRefresh!, firstDate!
        )
        let lastSuccess = fixture.coordinator.sourceHealth(for: root).lastSuccessfulRefresh
        fixture.scanner.enqueueScanError(.memoryLimitExceeded)
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).status, .failed)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).issue, .memoryLimitExceeded)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).lastSuccessfulRefresh, lastSuccess)
        XCTAssertEqual(fixture.coordinator.itemsRevision, revision)
        XCTAssertEqual(fixture.coordinator.sourceRoots.map(\.id), [root.id])
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).status, .ready)
        XCTAssertNil(fixture.coordinator.sourceHealth(for: root).issue)
        await fixture.coordinator.shutdown()
    }

    func testAllUnavailableRootsStayRecoverableAndDoNotReportSuccessfulEmptyLibrary() async {
        let other = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/tmp/Source Health Other"), displayName: "Other"
        )
        let fixture = makeFixture(
            selectedURLs: [root.url, other.url], snapshot: .init(
                roots: [], items: [], sourceDiagnostics: [
                    root.id: .init(coverage: .unavailable, issue: .temporarilyUnavailable),
                    other.id: .init(coverage: .unavailable, issue: .permissionDenied)
                ]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.scanState, .failed(.other))
        XCTAssertEqual(fixture.coordinator.sourceRoots.count, 2)
        XCTAssertEqual(fixture.coordinator.sourceAccessState, .available)
        XCTAssertTrue(fixture.coordinator.canRefresh)
        XCTAssertNil(fixture.coordinator.sourceHealth(for: root).lastSuccessfulRefresh)
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: other).issue, .permissionDenied)
        await fixture.coordinator.shutdown()
    }

    func testRemovingNeverSuccessfulActiveSourceClearsHealthAndLateScanCannotRestoreIt() async {
        let other = MediaLibraryRoot(
            url: URL(fileURLWithPath: "/tmp/Source Health Other"), displayName: "Other"
        )
        let fixture = makeFixture(
            selectedURLs: [root.url, other.url], snapshot: .init(
                roots: [root], items: [], sourceDiagnostics: [
                    other.id: .init(coverage: .unavailable, issue: .unknown)
                ]
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        XCTAssertFalse(fixture.coordinator.roots.contains(other))
        fixture.scanner.blockNextScan()
        fixture.coordinator.refresh()
        while !fixture.scanner.didBeginBlockedScan { await Task.yield() }
        let removal = Task { await fixture.coordinator.removeRoot(other) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.coordinator.sourceRoots.contains(where: { $0.id == other.id }),
              ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(fixture.coordinator.sourceRoots.contains(where: { $0.id == other.id }))
        fixture.scanner.finishBlockedScan()
        await removal.value
        await waitForScan(fixture.coordinator)
        XCTAssertFalse(fixture.coordinator.sourceRoots.contains(where: { $0.id == other.id }))
        XCTAssertNil(fixture.coordinator.sourceHealth[other.id])
        XCTAssertEqual(fixture.coordinator.sourceHealth(for: root).status, .ready)
        await fixture.coordinator.shutdown()
    }
}
