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
            TestPolicy.reconciliationNanoseconds
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

    func sendChange(handlerIndex: Int? = nil) {
        let index = handlerIndex ?? handlers.index(before: handlers.endIndex)
        handlers[index]()
    }
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
