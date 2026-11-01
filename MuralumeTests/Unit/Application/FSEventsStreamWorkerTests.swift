import Foundation
import XCTest
@testable import Muralume

@MainActor
final class FSEventsStreamWorkerTests: XCTestCase {
    func testLateDeadlineCannotInvalidateSuccessfullyInstalledRequest() async {
        let probe = FSEventsNativeProbe()
        let request = FSEventsInstallationRequest(
            urls: [URL(fileURLWithPath: "/tmp/muralume-completed-installation")]
        ) { probe.recordCallback() }
        request.finish(true)

        XCTAssertFalse(request.expireIfPending())
        XCTAssertTrue(request.isValid)
        request.callbackGate.emit()
        XCTAssertEqual(probe.callbackCount, 1)
        let result = await withCheckedContinuation { request.attach($0) }
        XCTAssertTrue(result)

        request.invalidate() // Explicit stop/cancellation still closes success.
        request.callbackGate.emit()
        XCTAssertEqual(probe.callbackCount, 1)
    }

    func testDeadlineWinningCompletionPreventsLateSuccessAndCallback() async {
        let probe = FSEventsNativeProbe()
        let request = FSEventsInstallationRequest(
            urls: [URL(fileURLWithPath: "/tmp/muralume-expired-installation")]
        ) { probe.recordCallback() }
        XCTAssertTrue(request.expireIfPending())
        request.finish(true)
        let result = await withCheckedContinuation { request.attach($0) }
        XCTAssertFalse(result)
        XCTAssertFalse(request.isValid)
        request.callbackGate.emit()
        XCTAssertEqual(probe.callbackCount, 0)
    }

    func testBlockedCreateTimesOutAndKeepsScopeUntilLateNativeCleanup() async {
        let probe = FSEventsNativeProbe(blockCreate: true)
        let worker = makeWorker(probe, timeout: 20_000_000)
        let result = FSEventsUpdateResult()
        let root = URL(fileURLWithPath: "/tmp/muralume-blocked-create")
        let caller = Task {
            result.value = await worker.update(urls: [root]) { probe.recordCallback() }
        }
        defer { caller.cancel(); worker.stop(); probe.unblockAll() }

        let entered = await waitUntil { probe.createCount == 1 }
        XCTAssertTrue(entered)
        XCTAssertEqual(probe.activeScopeCount, 1)
        let returned = await waitUntil { result.value != nil }
        XCTAssertTrue(returned, "The async caller must not wait for the blocked C call")
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(probe.activeScopeCount, 1)
        probe.emitCallbacks()
        XCTAssertEqual(probe.callbackCount, 0)

        probe.releaseCreate()
        let cleaned = await waitUntil { probe.activeScopeCount == 0 }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(probe.startCount, 0, "A stale creation must never start its stream")
        XCTAssertEqual(probe.destroyCount, 1)
        XCTAssertFalse(probe.didRunNativeOperationOnMainThread)
        XCTAssertTrue(probe.scopeReleaseFollowedDestruction)
    }

    func testCancellationDisablesCallbacksWhileStartAndTeardownRemainBlocked() async {
        let probe = FSEventsNativeProbe(blockStart: true, blockDestroy: true)
        let worker = makeWorker(probe)
        let result = FSEventsUpdateResult()
        let caller = Task {
            result.value = await worker.update(
                urls: [URL(fileURLWithPath: "/tmp/muralume-blocked-start")]
            ) { probe.recordCallback() }
        }
        defer { caller.cancel(); worker.stop(); probe.unblockAll() }

        let started = await waitUntil { probe.startCount == 1 }
        XCTAssertTrue(started)
        caller.cancel()
        worker.stop()
        let returned = await waitUntil { result.value != nil }
        XCTAssertTrue(returned)
        XCTAssertEqual(result.value, false)
        probe.emitCallbacks()
        XCTAssertEqual(probe.callbackCount, 0)
        XCTAssertEqual(probe.activeScopeCount, 1)

        probe.releaseStart()
        let destroying = await waitUntil { probe.destroyEnteredCount == 1 }
        XCTAssertTrue(destroying)
        XCTAssertEqual(probe.activeScopeCount, 1)
        worker.stop() // Also remains non-blocking during native teardown.
        probe.releaseDestroy()
        let cleaned = await waitUntil { probe.activeScopeCount == 0 }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(probe.didRunNativeOperationOnMainThread)
        XCTAssertTrue(probe.scopeReleaseFollowedDestruction)
    }

    func testRootChurnRetainsOnlyLatestPendingWorkBehindBlockedCreate() async {
        let probe = FSEventsNativeProbe(blockCreate: true)
        let worker = makeWorker(probe)
        let first = URL(fileURLWithPath: "/tmp/muralume-first-monitor")
        let initialResult = FSEventsUpdateResult()
        var callers: [Task<Void, Never>] = []
        callers.append(Task {
            initialResult.value = await worker.update(urls: [first]) { probe.recordCallback() }
        })
        defer { callers.forEach { $0.cancel() }; worker.stop(); probe.unblockAll() }
        let entered = await waitUntil { probe.createCount == 1 }
        XCTAssertTrue(entered)
        var previousResult = initialResult
        var latestResult = initialResult
        var lastRoot = first

        for index in 0..<100 {
            let nextResult = FSEventsUpdateResult()
            let nextRoot = URL(fileURLWithPath: "/tmp/muralume-latest-monitor-\(index)")
            callers.append(Task {
                nextResult.value = await worker.update(urls: [nextRoot]) { probe.recordCallback() }
            })
            let superseded = await waitUntil { previousResult.value != nil }
            XCTAssertTrue(superseded)
            XCTAssertEqual(previousResult.value, false)
            previousResult = nextResult
            latestResult = nextResult
            lastRoot = nextRoot
        }
        XCTAssertEqual(probe.createCount, 1)
        XCTAssertEqual(probe.activeScopeCount, 1)
        probe.emitCallbacks()
        XCTAssertEqual(probe.callbackCount, 0)

        probe.releaseCreate()
        let installed = await waitUntil { latestResult.value != nil }
        XCTAssertTrue(installed)
        XCTAssertEqual(latestResult.value, true)
        XCTAssertEqual(probe.createdPaths, [first.path, lastRoot.path])
        XCTAssertEqual(probe.maximumNativeStreamCount, 1)
        XCTAssertEqual(probe.scopeStartCount, 2)
        probe.emitCallbacks()
        XCTAssertEqual(probe.callbackCount, 1, "Only the latest stream may deliver a callback")

        worker.stop()
        let cleaned = await waitUntil { probe.activeScopeCount == 0 }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(probe.didRunNativeOperationOnMainThread)
        XCTAssertTrue(probe.scopeReleaseFollowedDestruction)
    }

    func testMonitorDeinitDoesNotWaitForBlockedTeardown() async {
        let probe = FSEventsNativeProbe(blockDestroy: true)
        var monitor: FSEventsMediaLibraryChangeMonitor? = FSEventsMediaLibraryChangeMonitor(
            streamFactory: probe.factory,
            scopeAccess: probe.scopeAccess
        )
        defer { monitor?.stop(); probe.unblockAll() }
        let installed = await monitor!.update(
            folderURLs: [URL(fileURLWithPath: "/tmp/muralume-monitor-deinit")]
        ) { probe.recordCallback() }
        XCTAssertTrue(installed)
        monitor = nil
        let destroying = await waitUntil { probe.destroyEnteredCount == 1 }
        XCTAssertTrue(destroying)
        probe.emitCallbacks()
        XCTAssertEqual(probe.callbackCount, 0)
        XCTAssertEqual(probe.activeScopeCount, 1)
        probe.releaseDestroy()
        let cleaned = await waitUntil { probe.activeScopeCount == 0 }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(probe.didRunNativeOperationOnMainThread)
    }

    private func makeWorker(
        _ probe: FSEventsNativeProbe, timeout: UInt64 = 5_000_000_000
    ) -> FSEventsStreamWorker {
        FSEventsStreamWorker(
            factory: probe.factory,
            scopeAccess: probe.scopeAccess,
            timeoutNanoseconds: timeout
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}

@MainActor
private final class FSEventsUpdateResult {
    var value: Bool?
}

private final class FSEventsNativeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let createGate = DispatchSemaphore(value: 0)
    private let startGate = DispatchSemaphore(value: 0)
    private let destroyGate = DispatchSemaphore(value: 0)
    private let blocksCreate: Bool
    private let blocksStart: Bool
    private let blocksDestroy: Bool
    private var callbacks: [@Sendable () -> Void] = []
    private var paths: [String] = []
    private var storedStartCount = 0
    private var storedDestroyEnteredCount = 0
    private var storedDestroyCount = 0
    private var storedScopeStartCount = 0
    private var storedActiveScopeCount = 0
    private var storedNativeStreamCount = 0
    private var storedMaximumNativeStreamCount = 0
    private var storedCallbackCount = 0
    private var storedDidRunOnMain = false
    private var storedScopeReleaseFollowedDestruction = true

    init(blockCreate: Bool = false, blockStart: Bool = false, blockDestroy: Bool = false) {
        blocksCreate = blockCreate
        blocksStart = blockStart
        blocksDestroy = blockDestroy
    }

    var factory: FSEventsStreamFactory {
        { [self] urls, callback in
            let count = lock.withLock {
                storedDidRunOnMain = storedDidRunOnMain || Thread.isMainThread
                paths.append(urls[0].path)
                callbacks.append(callback)
                storedNativeStreamCount += 1
                storedMaximumNativeStreamCount = max(storedMaximumNativeStreamCount, storedNativeStreamCount)
                return paths.count
            }
            if blocksCreate && count == 1 { createGate.wait() }
            return FSEventsTestStream(probe: self)
        }
    }

    var scopeAccess: FSEventsSecurityScopeAccess {
        FSEventsSecurityScopeAccess(
            start: { [self] _ in
                lock.withLock {
                    storedDidRunOnMain = storedDidRunOnMain || Thread.isMainThread
                    storedScopeStartCount += 1
                    storedActiveScopeCount += 1
                }
                return true
            },
            stop: { [self] _ in
                lock.withLock {
                    storedDidRunOnMain = storedDidRunOnMain || Thread.isMainThread
                    storedActiveScopeCount -= 1
                    storedScopeReleaseFollowedDestruction =
                        storedScopeReleaseFollowedDestruction && storedNativeStreamCount == 0
                }
            }
        )
    }

    var createCount: Int { lock.withLock { paths.count } }
    var createdPaths: [String] { lock.withLock { paths } }
    var startCount: Int { lock.withLock { storedStartCount } }
    var destroyEnteredCount: Int { lock.withLock { storedDestroyEnteredCount } }
    var destroyCount: Int { lock.withLock { storedDestroyCount } }
    var scopeStartCount: Int { lock.withLock { storedScopeStartCount } }
    var activeScopeCount: Int { lock.withLock { storedActiveScopeCount } }
    var callbackCount: Int { lock.withLock { storedCallbackCount } }
    var maximumNativeStreamCount: Int { lock.withLock { storedMaximumNativeStreamCount } }
    var didRunNativeOperationOnMainThread: Bool { lock.withLock { storedDidRunOnMain } }
    var scopeReleaseFollowedDestruction: Bool { lock.withLock { storedScopeReleaseFollowedDestruction } }

    func start() -> Bool {
        lock.withLock {
            storedDidRunOnMain = storedDidRunOnMain || Thread.isMainThread
            storedStartCount += 1
        }
        if blocksStart { startGate.wait() }
        return true
    }

    func destroy() {
        lock.withLock {
            storedDidRunOnMain = storedDidRunOnMain || Thread.isMainThread
            storedDestroyEnteredCount += 1
        }
        if blocksDestroy { destroyGate.wait() }
        lock.withLock {
            storedNativeStreamCount -= 1
            storedDestroyCount += 1
        }
    }

    func emitCallbacks() {
        let callbacks = lock.withLock { callbacks }
        callbacks.forEach { $0() }
    }

    func recordCallback() { lock.withLock { storedCallbackCount += 1 } }
    func releaseCreate() { createGate.signal() }
    func releaseStart() { startGate.signal() }
    func releaseDestroy() { destroyGate.signal() }
    func unblockAll() { releaseCreate(); releaseStart(); releaseDestroy() }
}

private final class FSEventsTestStream: FSEventsStreamDriving, @unchecked Sendable {
    private let probe: FSEventsNativeProbe
    init(probe: FSEventsNativeProbe) { self.probe = probe }
    func start() -> Bool { probe.start() }
    func invalidate() { probe.destroy() }
}
