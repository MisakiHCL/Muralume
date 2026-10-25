import CoreServices
import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryAutomaticRefreshControllerTests: XCTestCase {
    private enum TestPolicy {
        static let debounceNanoseconds: UInt64 = 5_000_000
        static let scanFailureRetryNanoseconds: UInt64 = 12_000_000
        static let installationRetryNanoseconds: UInt64 = 5_000_000
        static let installationRecoveryNanoseconds: UInt64 = 30_000_000
        static let reconciliationNanoseconds: UInt64 = 1_000_000_000
        static let fastReconciliationNanoseconds: UInt64 = 20_000_000
        static let maximumInstallationRetryCount = 2
        static let pollNanoseconds: UInt64 = 1_000_000
        static let pollAttempts = 100
    }

    func testFolderRootNormalizerStandardizesDeduplicatesAndSorts() {
        let root = URL(fileURLWithPath: "/tmp/muralume-monitor")
        let nestedSpelling = root
            .appendingPathComponent("child")
            .appendingPathComponent("..")
        let secondRoot = URL(fileURLWithPath: "/tmp/another-root")
        let webURL = URL(string: "https://example.com/folder")!

        XCTAssertEqual(
            MediaLibraryFolderRootNormalizer.normalized([
                root,
                nestedSpelling,
                webURL,
                secondRoot,
                root
            ]),
            [secondRoot.standardizedFileURL, root.standardizedFileURL]
        )
    }

    func testStartUpdateAndStopAreIdempotent() {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        let controller = makeController(monitor: monitor, target: target)
        let root = URL(fileURLWithPath: "/tmp/media")

        controller.start(folderURLs: [root, root])
        controller.start(folderURLs: [root.standardizedFileURL])
        controller.update(folderURLs: [root])

        XCTAssertEqual(monitor.updateCalls, [[root.standardizedFileURL]])

        controller.stop()
        controller.stop()
        controller.update(folderURLs: [root])

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertEqual(monitor.updateCalls.count, 1)
    }

    func testLowFrequencyReconciliationRefreshesWhenMonitorIsSilent() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(
            monitor: monitor,
            target: target,
            reconciliationNanoseconds:
                TestPolicy.fastReconciliationNanoseconds
        )

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/silent-monitor")]
        )

        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
        XCTAssertTrue(target.isScanning)
        try? await Task.sleep(
            nanoseconds: TestPolicy.fastReconciliationNanoseconds * 3
        )
        XCTAssertEqual(
            target.refreshRequestCount,
            1,
            "The reconciliation watchdog must not overlap an active scan"
        )
    }

    func testStopCancelsLowFrequencyReconciliation() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        let controller = makeController(
            monitor: monitor,
            target: target,
            reconciliationNanoseconds:
                TestPolicy.fastReconciliationNanoseconds
        )

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/stopped-watchdog")]
        )
        controller.stop()
        try? await Task.sleep(
            nanoseconds: TestPolicy.fastReconciliationNanoseconds * 2
        )

        XCTAssertEqual(target.refreshRequestCount, 0)
    }

    func testReliableInternalRootKeepsBoundedSilentWatcherFallback() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.cadence = .extended
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor,
            target: target,
            reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/internal-media")])

        let extendedInterval = TestPolicy.reconciliationNanoseconds
            * MediaLibraryAutomaticRefreshPolicy.extendedReconciliationIntervalMultiplier
        await waitUntil { delay.intervals.last == extendedInterval }
        XCTAssertEqual(target.refreshRequestCount, 0)

        delay.release()
        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertTrue(target.isScanning)
        controller.stop()
    }

    func testEventsRemainPromptDuringExtendedReconciliation() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.cadence = .extended
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/event-media")])
        await waitUntil {
            delay.intervals.last == TestPolicy.reconciliationNanoseconds
                * MediaLibraryAutomaticRefreshPolicy.extendedReconciliationIntervalMultiplier
        }

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertTrue(target.isScanning)
        controller.stop()
    }

    func testLateStandardClassificationPreservesOriginalWatchdog() async {
        let monitor = AutomaticRefreshMonitorSpy()
        var classification: CheckedContinuation<MediaLibraryReconciliationCadence, Never>?
        monitor.resolveCadence = {
            await withCheckedContinuation { classification = $0 }
        }
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let delay = ReconciliationDelayRecorder()
        let uptime = ReconciliationTestUptime()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait,
            reconciliationUptime: { uptime.value }
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/slow-unknown-volume")])
        await waitUntil { classification != nil && delay.intervals.count == 1 }

        uptime.value = TestPolicy.reconciliationNanoseconds / 2
        classification?.resume(returning: .standard)
        await waitUntil { monitor.cadenceCompletionCount == 1 }
        await Task.yield()
        XCTAssertEqual(delay.intervals, [TestPolicy.reconciliationNanoseconds])

        delay.release()
        await waitUntil { target.refreshRequestCount == 1 }
        controller.stop()
    }

    func testLateExtendedClassificationUsesOriginalMonotonicAnchor() async {
        let monitor = AutomaticRefreshMonitorSpy()
        var classification: CheckedContinuation<MediaLibraryReconciliationCadence, Never>?
        monitor.resolveCadence = {
            await withCheckedContinuation { classification = $0 }
        }
        let target = AutomaticRefreshTargetSpy()
        let delay = ReconciliationDelayRecorder()
        let uptime = ReconciliationTestUptime()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait,
            reconciliationUptime: { uptime.value }
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/slow-internal-volume")])
        await waitUntil { classification != nil && delay.intervals.count == 1 }

        uptime.value = TestPolicy.reconciliationNanoseconds / 2
        classification?.resume(returning: .extended)
        await waitUntil { delay.intervals.count == 2 }
        let maximumInterval = TestPolicy.reconciliationNanoseconds
            * MediaLibraryAutomaticRefreshPolicy.extendedReconciliationIntervalMultiplier
        XCTAssertEqual(delay.intervals.last, maximumInterval - uptime.value)
        controller.stop()
    }

    func testSlowClassificationCannotBlockConservativeWatchdogDeadline() async {
        let monitor = AutomaticRefreshMonitorSpy()
        var classification: CheckedContinuation<MediaLibraryReconciliationCadence, Never>?
        monitor.resolveCadence = {
            await withCheckedContinuation { classification = $0 }
        }
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/blocked-volume")])
        await waitUntil { classification != nil && delay.intervals.count == 1 }
        XCTAssertEqual(delay.intervals, [TestPolicy.reconciliationNanoseconds])

        delay.release()
        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertTrue(target.isScanning)
        controller.stop()
        classification?.resume(returning: .extended)
    }

    func testFailedScanRestoresConservativeReconciliation() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.cadence = .extended
        let target = AutomaticRefreshTargetSpy()
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/failed-internal-media")])
        await waitUntil {
            delay.intervals.last == TestPolicy.reconciliationNanoseconds
                * MediaLibraryAutomaticRefreshPolicy.extendedReconciliationIntervalMultiplier
        }

        target.isScanning = true
        controller.scanStateDidChange()
        target.lastScanSucceeded = false
        target.isScanning = false
        controller.scanStateDidChange()

        await waitUntil { delay.intervals.last == TestPolicy.reconciliationNanoseconds }
        controller.stop()
    }

    func testMonitorInstallationGapKeepsConservativeReconciliation() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.cadence = .extended
        monitor.defaultUpdateResult = false
        let target = AutomaticRefreshTargetSpy()
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/unmonitored-internal-media")])

        await waitUntil { monitor.cadenceRequestCount == 1 && !delay.intervals.isEmpty }
        XCTAssertTrue(delay.intervals.allSatisfy {
            $0 == TestPolicy.reconciliationNanoseconds
        })
        controller.stop()
    }

    func testStaleVolumeClassificationCannotExtendReplacementRoots() async {
        let monitor = AutomaticRefreshMonitorSpy()
        var classifications: [CheckedContinuation<MediaLibraryReconciliationCadence, Never>] = []
        monitor.resolveCadence = {
            await withCheckedContinuation { classifications.append($0) }
        }
        let target = AutomaticRefreshTargetSpy()
        let delay = ReconciliationDelayRecorder()
        let controller = makeController(
            monitor: monitor, target: target, reconciliationDelayer: delay.wait
        )
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/old-internal-media")])
        await waitUntil { classifications.count == 1 }
        controller.update(folderURLs: [URL(fileURLWithPath: "/tmp/new-network-media")])
        await waitUntil { classifications.count == 2 }

        classifications[0].resume(returning: .extended)
        classifications[1].resume(returning: .standard)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(delay.intervals.allSatisfy {
            $0 == TestPolicy.reconciliationNanoseconds
        })
        controller.stop()
    }

    func testOnlyKnownReliableInternalVolumesExtendReconciliation() {
        func volume(
            local: Bool? = true,
            internalVolume: Bool? = true,
            removable: Bool? = false,
            ejectable: Bool? = false,
            ubiquitous: Bool? = false,
            fileSystem: String? = "apfs"
        ) -> MediaLibraryReconciliationVolume {
            .init(
                isLocal: local, isInternal: internalVolume,
                isRemovable: removable, isEjectable: ejectable,
                isUbiquitous: ubiquitous, fileSystemType: fileSystem
            )
        }
        XCTAssertTrue(volume().allowsExtendedReconciliation)
        XCTAssertTrue(volume(fileSystem: "hfs").allowsExtendedReconciliation)
        XCTAssertTrue(volume(ubiquitous: nil).allowsExtendedReconciliation)
        let unreliableVolumes = [
            volume(local: false), volume(internalVolume: false),
            volume(removable: true), volume(ejectable: true),
            volume(ubiquitous: true), volume(fileSystem: "osxfuse"),
            volume(local: nil), volume(internalVolume: nil),
            volume(removable: nil), volume(ejectable: nil),
            volume(fileSystem: nil)
        ]
        XCTAssertTrue(unreliableVolumes.allSatisfy { !$0.allowsExtendedReconciliation })
    }

    func testVolumeInspectionRunsOffMainThreadAndRejectsMixedRoots() async {
        let reliableVolume = MediaLibraryReconciliationVolume(
            isLocal: true, isInternal: true, isRemovable: false,
            isEjectable: false, isUbiquitous: false, fileSystemType: "apfs"
        )
        let monitor = FSEventsMediaLibraryChangeMonitor { url in
            XCTAssertFalse(Thread.isMainThread)
            return url.lastPathComponent == "internal" ? reliableVolume : nil
        }
        let internalRoot = URL(fileURLWithPath: "/tmp/internal")
        let unknownRoot = URL(fileURLWithPath: "/tmp/unknown")
        let internalCadence = await monitor.reconciliationCadence(for: [internalRoot])
        let mixedCadence = await monitor.reconciliationCadence(
            for: [internalRoot, unknownRoot]
        )
        XCTAssertEqual(internalCadence, .extended)
        XCTAssertEqual(mixedCadence, .standard)
    }

    func testCoalescesBurstIntoOneRefreshRequest() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        monitor.sendChange()
        monitor.sendChange()

        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testContinuousEventsCannotKeepPostponingFirstRefresh() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        for _ in 0..<20 {
            monitor.sendChange()
            try? await Task.sleep(
                nanoseconds: TestPolicy.pollNanoseconds
            )
        }

        XCTAssertEqual(
            target.refreshRequestCount,
            1,
            "A continuous event stream must not starve the first refresh"
        )
        XCTAssertTrue(target.isScanning)
    }

    func testEventDuringScanSchedulesOneFollowUpAfterCompletion() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        controller.scanStateDidChange()

        monitor.sendChange()
        monitor.sendChange()
        await Task.yield()
        target.isScanning = false
        controller.scanStateDidChange()

        await waitUntil { target.refreshRequestCount == 2 }
        XCTAssertEqual(target.refreshRequestCount, 2)
    }

    func testEventDuringAlreadyRunningScanIsRefreshedAfterCompletion() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.isScanning = true
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await Task.yield()
        target.isScanning = false
        controller.scanStateDidChange()

        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testScanWithoutLaterEventDoesNotTriggerFollowUp() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        controller.scanStateDidChange()
        target.isScanning = false
        controller.scanStateDidChange()

        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds * 3
        )
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testFailedScanKeepsDirtyRevisionAndRetriesAfterDelay() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        controller.scanStateDidChange()

        target.lastScanSucceeded = false
        target.isScanning = false
        controller.scanStateDidChange()

        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds
        )
        XCTAssertEqual(target.refreshRequestCount, 1)

        await waitUntil { target.refreshRequestCount == 2 }
        controller.scanStateDidChange()
        target.lastScanSucceeded = true
        target.isScanning = false
        controller.scanStateDidChange()

        try? await Task.sleep(
            nanoseconds: TestPolicy.scanFailureRetryNanoseconds * 2
        )
        XCTAssertEqual(target.refreshRequestCount, 2)
    }

    func testStopCancelsFailedScanRetry() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        target.lastScanSucceeded = false
        target.isScanning = false
        controller.scanStateDidChange()
        controller.stop()

        try? await Task.sleep(
            nanoseconds: TestPolicy.scanFailureRetryNanoseconds * 2
        )
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testFolderUpdateCancelsFailedScanRetry() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        let firstRoot = URL(fileURLWithPath: "/tmp/failed-scan-root")
        let secondRoot = URL(fileURLWithPath: "/tmp/replacement-root")

        controller.start(folderURLs: [firstRoot])
        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }

        target.lastScanSucceeded = false
        target.isScanning = false
        controller.scanStateDidChange()
        controller.update(folderURLs: [secondRoot])

        try? await Task.sleep(
            nanoseconds: TestPolicy.scanFailureRetryNanoseconds * 2
        )
        XCTAssertEqual(target.refreshRequestCount, 1)

        monitor.sendChange(handlerIndex: 1)
        await waitUntil { target.refreshRequestCount == 2 }
        XCTAssertEqual(target.refreshRequestCount, 2)
    }

    func testOldGenerationEventIsIgnoredAfterFolderUpdate() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/first")])
        controller.update(folderURLs: [URL(fileURLWithPath: "/tmp/second")])

        monitor.sendChange(handlerIndex: 0)
        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds * 3
        )
        XCTAssertEqual(target.refreshRequestCount, 0)

        monitor.sendChange(handlerIndex: 1)
        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testStopInvalidatesQueuedAndFutureEvents() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        controller.stop()
        monitor.sendChange()

        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds * 3
        )
        XCTAssertEqual(target.refreshRequestCount, 0)
    }

    func testMonitorInstallationRetriesUntilItSucceeds() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.updateResults = [false, false, true]
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        let root = URL(fileURLWithPath: "/tmp/retry-media")

        controller.start(folderURLs: [root])

        await waitUntil { monitor.updateCalls.count == 3 }
        XCTAssertEqual(
            monitor.updateCalls,
            Array(repeating: [root.standardizedFileURL], count: 3)
        )

        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testMonitorInstallationRetryCountIsBounded() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.defaultUpdateResult = false
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/unavailable-media")]
        )

        let expectedAttemptCount =
            TestPolicy.maximumInstallationRetryCount + 1
        await waitUntil { monitor.updateCalls.count == expectedAttemptCount }
        await waitUntil { target.refreshRequestCount == 1 }
        try? await Task.sleep(
            nanoseconds: TestPolicy.installationRetryNanoseconds * 2
        )
        XCTAssertEqual(monitor.updateCalls.count, expectedAttemptCount)
        XCTAssertEqual(target.refreshRequestCount, 1)
        controller.stop()
    }

    func testMonitorInstallationContinuesLowFrequencyRecovery() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.updateResults = [false, false, false, true]
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/recovery-media")]
        )

        await waitUntil { monitor.updateCalls.count == 3 }
        await waitUntil { target.refreshRequestCount == 1 }
        target.lastScanSucceeded = true
        target.isScanning = false
        controller.scanStateDidChange()

        await waitUntil { monitor.updateCalls.count == 4 }
        await waitUntil { target.refreshRequestCount == 2 }
        XCTAssertEqual(monitor.updateCalls.count, 4)
        XCTAssertEqual(target.refreshRequestCount, 2)

        try? await Task.sleep(
            nanoseconds: TestPolicy.installationRecoveryNanoseconds * 2
        )
        XCTAssertEqual(monitor.updateCalls.count, 4)
        XCTAssertEqual(target.refreshRequestCount, 2)
        controller.stop()
    }

    func testStopCancelsLowFrequencyMonitorRecovery() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.defaultUpdateResult = false
        let target = AutomaticRefreshTargetSpy()
        let controller = makeController(monitor: monitor, target: target)

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/stopped-recovery-root")]
        )

        let expectedAttemptCount =
            TestPolicy.maximumInstallationRetryCount + 1
        await waitUntil { monitor.updateCalls.count == expectedAttemptCount }
        controller.stop()

        try? await Task.sleep(
            nanoseconds: TestPolicy.installationRecoveryNanoseconds * 2
        )
        XCTAssertEqual(monitor.updateCalls.count, expectedAttemptCount)
        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertEqual(target.refreshRequestCount, 0)
    }

    func testFolderUpdateCancelsOldGenerationInstallationRetry() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.updateResults = [false, true]
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)
        let firstRoot = URL(fileURLWithPath: "/tmp/first-retry-root")
        let secondRoot = URL(fileURLWithPath: "/tmp/second-retry-root")

        controller.start(folderURLs: [firstRoot])
        controller.update(folderURLs: [secondRoot])

        try? await Task.sleep(
            nanoseconds: TestPolicy.installationRetryNanoseconds * 3
        )
        XCTAssertEqual(
            monitor.updateCalls,
            [[firstRoot.standardizedFileURL], [secondRoot.standardizedFileURL]]
        )

        monitor.sendChange(handlerIndex: 0)
        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds * 3
        )
        XCTAssertEqual(target.refreshRequestCount, 0)

        monitor.sendChange(handlerIndex: 1)
        await waitUntil { target.refreshRequestCount == 1 }
        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testStopCancelsMonitorInstallationRetry() async {
        let monitor = AutomaticRefreshMonitorSpy()
        monitor.defaultUpdateResult = false
        let target = AutomaticRefreshTargetSpy()
        target.startsScanningWhenRefreshIsAccepted = true
        let controller = makeController(monitor: monitor, target: target)

        controller.start(
            folderURLs: [URL(fileURLWithPath: "/tmp/stopped-retry-root")]
        )
        controller.stop()

        try? await Task.sleep(
            nanoseconds: TestPolicy.installationRetryNanoseconds * 3
        )
        XCTAssertEqual(monitor.updateCalls.count, 1)
        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertEqual(target.refreshRequestCount, 0)
    }

    func testRejectedRequestDoesNotSpin() async {
        let monitor = AutomaticRefreshMonitorSpy()
        let target = AutomaticRefreshTargetSpy()
        target.acceptsRefreshRequests = false
        let controller = makeController(monitor: monitor, target: target)
        controller.start(folderURLs: [URL(fileURLWithPath: "/tmp/media")])

        monitor.sendChange()
        await waitUntil { target.refreshRequestCount == 1 }
        try? await Task.sleep(
            nanoseconds: TestPolicy.debounceNanoseconds * 3
        )

        XCTAssertEqual(target.refreshRequestCount, 1)
    }

    func testFSEventsPolicyUsesCoarseRecursiveRootFlags() {
        XCTAssertEqual(FSEventsMediaLibraryChangePolicy.latency, 1)
        XCTAssertEqual(
            FSEventsMediaLibraryChangePolicy.sinceWhen,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        )
        XCTAssertNotEqual(
            FSEventsMediaLibraryChangePolicy.creationFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot),
            0
        )
        XCTAssertNotEqual(
            FSEventsMediaLibraryChangePolicy.creationFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes),
            0
        )
        XCTAssertEqual(
            FSEventsMediaLibraryChangePolicy.creationFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            0
        )
    }

    private func makeController(
        monitor: AutomaticRefreshMonitorSpy,
        target: AutomaticRefreshTargetSpy,
        reconciliationNanoseconds: UInt64 =
            TestPolicy.reconciliationNanoseconds,
        reconciliationDelayer: @escaping
            MediaLibraryAutomaticRefreshController.ReconciliationDelayer = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
        reconciliationUptime: @escaping
            MediaLibraryAutomaticRefreshController.ReconciliationUptime = { 0 }
    ) -> MediaLibraryAutomaticRefreshController {
        MediaLibraryAutomaticRefreshController(
            monitor: monitor,
            target: target,
            debounceNanoseconds: TestPolicy.debounceNanoseconds,
            scanFailureRetryNanoseconds:
                TestPolicy.scanFailureRetryNanoseconds,
            installationRetryNanoseconds:
                TestPolicy.installationRetryNanoseconds,
            installationRecoveryNanoseconds:
                TestPolicy.installationRecoveryNanoseconds,
            reconciliationNanoseconds: reconciliationNanoseconds,
            reconciliationDelayer: reconciliationDelayer,
            reconciliationUptime: reconciliationUptime,
            maximumInstallationRetryCount:
                TestPolicy.maximumInstallationRetryCount
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<TestPolicy.pollAttempts {
            if condition() {
                return
            }
            try? await Task.sleep(
                nanoseconds: TestPolicy.pollNanoseconds
            )
        }
        XCTFail("Timed out waiting for automatic refresh state")
    }
}

@MainActor
private final class AutomaticRefreshMonitorSpy:
    MediaLibraryChangeMonitoring {
    private(set) var updateCalls: [[URL]] = []
    private(set) var stopCallCount = 0
    var updateResults: [Bool] = []
    var defaultUpdateResult = true
    var cadence: MediaLibraryReconciliationCadence = .standard
    var resolveCadence: (() async -> MediaLibraryReconciliationCadence)?
    private(set) var cadenceRequestCount = 0
    private(set) var cadenceCompletionCount = 0
    private var handlers: [@Sendable () -> Void] = []

    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) -> Bool {
        updateCalls.append(folderURLs)
        handlers.append(onChange)
        guard !updateResults.isEmpty else {
            return defaultUpdateResult
        }
        return updateResults.removeFirst()
    }

    func stop() {
        stopCallCount += 1
    }

    func reconciliationCadence(
        for folderURLs: [URL]
    ) async -> MediaLibraryReconciliationCadence {
        cadenceRequestCount += 1
        defer { cadenceCompletionCount += 1 }
        if let resolveCadence { return await resolveCadence() }
        return cadence
    }

    func sendChange(handlerIndex: Int? = nil) {
        let index = handlerIndex ?? handlers.index(before: handlers.endIndex)
        handlers[index]()
    }
}

@MainActor
private final class ReconciliationDelayRecorder {
    private(set) var intervals: [UInt64] = []
    private var availableReleases = 0

    func wait(_ nanoseconds: UInt64) async throws {
        intervals.append(nanoseconds)
        while availableReleases == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try Task.checkCancellation()
        availableReleases -= 1
    }

    func release() { availableReleases += 1 }
}

@MainActor
private final class AutomaticRefreshTargetSpy:
    MediaLibraryAutomaticRefreshTarget {
    var isScanning = false
    var lastScanSucceeded = true
    var acceptsRefreshRequests = true
    var startsScanningWhenRefreshIsAccepted = false
    private(set) var refreshRequestCount = 0

    var automaticRefreshIsScanning: Bool {
        isScanning
    }

    var automaticRefreshLastScanSucceeded: Bool {
        lastScanSucceeded
    }

    func requestAutomaticRefresh() -> Bool {
        refreshRequestCount += 1
        if acceptsRefreshRequests && startsScanningWhenRefreshIsAccepted {
            isScanning = true
        }
        return acceptsRefreshRequests
    }
}

@MainActor
private final class ReconciliationTestUptime {
    var value: UInt64 = 0
}
