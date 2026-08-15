import XCTest
@testable import Muralume

@MainActor
final class DesktopPlaybackOrchestratorTests: XCTestCase {
    func testStartsOneMutedEngineForEachEnabledConnectedAssignment() async {
        var engines: [TestPlaybackEngine] = []
        let orchestrator = DesktopPlaybackOrchestrator {
            let engine = TestPlaybackEngine()
            engines.append(engine)
            return engine
        }
        let first = displayID("first")
        let disabled = displayID("disabled")
        let disconnected = displayID("disconnected")
        let firstItem = itemID("first.mp4")
        let disconnectedItem = itemID("disconnected.mp4")

        try? await orchestrator.start(
            assignments: [
                assignment(first, itemID: firstItem),
                assignment(disabled, itemID: itemID("disabled.mp4"), isEnabled: false),
                assignment(disconnected, itemID: disconnectedItem)
            ],
            surfaces: [first: TestPlaybackSurface(id: .desktop)]
        ) { itemID in
            self.source(for: itemID)
        }
        await waitUntil {
            orchestrator.displayStates[first] == .playing
        }

        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(orchestrator.activeDisplayIDs, [first])
        XCTAssertTrue(engines[0].isMuted)
        XCTAssertEqual(engines[0].volume, .muted)
        XCTAssertTrue(engines[0].isPlaying)
        XCTAssertEqual(engines[0].attachedSurfaceID, .desktop)
        XCTAssertEqual(engines[0].progressCadence, .inactive)
        XCTAssertNil(orchestrator.displayStates[disabled])
        XCTAssertNil(orchestrator.displayStates[disconnected])
    }

    func testGlobalControlsAndOverlappingSuspensionsApplyToEveryNode() async {
        var engines: [TestPlaybackEngine] = []
        let orchestrator = DesktopPlaybackOrchestrator {
            let engine = TestPlaybackEngine()
            engines.append(engine)
            return engine
        }
        let display = displayID("display")
        try? await orchestrator.start(
            assignments: [assignment(display, itemID: itemID("loop.mp4"))],
            surfaces: [display: TestPlaybackSurface(id: .desktop)]
        ) { self.source(for: $0) }
        await waitUntil { engines.first?.isPlaying == true }
        let engine = engines[0]

        orchestrator.pauseAll()
        XCTAssertFalse(engine.isPlaying)

        orchestrator.resumeAll()
        orchestrator.setRate(PlaybackRate(rawValue: 1.5))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 1.5))

        orchestrator.setSuspended(true, for: .desktopOccluded)
        orchestrator.setSuspended(true, for: .thermalPressure)
        orchestrator.setSuspended(false, for: .desktopOccluded)
        XCTAssertFalse(engine.isPlaying)

        orchestrator.setSuspended(false, for: .thermalPressure)
        XCTAssertTrue(engine.isPlaying)

        orchestrator.setSuspended(true, for: .playerWindowMiniaturized)
        XCTAssertTrue(engine.isPlaying)
    }

    func testDisplaySuspensionOnlyPausesMatchingNodeAndComposesGlobally()
        async {
        var engines: [TestPlaybackEngine] = []
        let orchestrator = DesktopPlaybackOrchestrator {
            let engine = TestPlaybackEngine()
            engines.append(engine)
            return engine
        }
        let first = displayID("first")
        let second = displayID("second")
        try? await orchestrator.start(
            assignments: [
                assignment(first, itemID: itemID("first.mp4")),
                assignment(second, itemID: itemID("second.mp4"))
            ],
            surfaces: [
                first: TestPlaybackSurface(id: .desktop),
                second: TestPlaybackSurface(id: .desktop)
            ]
        ) { self.source(for: $0) }
        await waitUntil { engines.count == 2 && engines.allSatisfy(\.isPlaying) }

        orchestrator.setSuspended(
            true,
            for: .desktopOccluded,
            displayID: first
        )
        XCTAssertFalse(engines[0].isPlaying)
        XCTAssertTrue(engines[1].isPlaying)

        orchestrator.setSuspended(true, for: .desktopLowPowerMode)
        orchestrator.setSuspended(
            false,
            for: .desktopOccluded,
            displayID: first
        )
        XCTAssertTrue(engines.allSatisfy { !$0.isPlaying })

        orchestrator.setSuspended(false, for: .desktopLowPowerMode)
        XCTAssertTrue(engines.allSatisfy(\.isPlaying))
    }

    func testOneDisplayFailureDoesNotStopAnotherDisplay() async {
        let firstEngine = TestPlaybackEngine()
        let secondEngine = TestPlaybackEngine()
        let first = displayID("a")
        let second = displayID("b")
        let firstItem = itemID("broken.mp4")
        let secondItem = itemID("working.mp4")
        firstEngine.loadErrorsByURL[source(for: firstItem).url] = .cannotOpen
        var availableEngines = [firstEngine, secondEngine]
        let orchestrator = DesktopPlaybackOrchestrator {
            availableEngines.removeFirst()
        }

        try? await orchestrator.start(
            assignments: [
                assignment(first, itemID: firstItem),
                assignment(second, itemID: secondItem)
            ],
            surfaces: [
                first: TestPlaybackSurface(id: .desktop),
                second: TestPlaybackSurface(id: .desktop)
            ]
        ) { self.source(for: $0) }
        await waitUntil {
            orchestrator.displayStates[first] == .failed(.cannotOpen)
                && orchestrator.displayStates[second] == .playing
        }

        XCTAssertEqual(
            orchestrator.displayFailures,
            [first: .cannotOpen]
        )
        XCTAssertFalse(firstEngine.isPlaying)
        XCTAssertTrue(secondEngine.isPlaying)
        XCTAssertEqual(orchestrator.activeDisplayIDs, [first, second])
    }

    func testLateFailuresExposePartialAndTerminalAvailability() async throws {
        let firstEngine = TestPlaybackEngine()
        let secondEngine = TestPlaybackEngine()
        var availableEngines = [firstEngine, secondEngine]
        let first = displayID("first")
        let second = displayID("second")
        let orchestrator = DesktopPlaybackOrchestrator {
            availableEngines.removeFirst()
        }

        try await orchestrator.start(
            assignments: [
                assignment(first, itemID: itemID("first.mp4")),
                assignment(second, itemID: itemID("second.mp4"))
            ],
            surfaces: [
                first: TestPlaybackSurface(id: .desktop),
                second: TestPlaybackSurface(id: .desktop)
            ]
        ) { self.source(for: $0) }
        await waitUntil {
            orchestrator.displayStates[first] == .playing
                && orchestrator.displayStates[second] == .playing
        }

        firstEngine.emitFailure(.unsupported)

        XCTAssertEqual(orchestrator.failedDisplayCount, 1)
        XCTAssertNil(orchestrator.terminalFailure)
        XCTAssertEqual(orchestrator.displayFailures[first], .unsupported)

        secondEngine.emitFailure(.cannotOpen)

        XCTAssertEqual(orchestrator.failedDisplayCount, 2)
        XCTAssertEqual(orchestrator.terminalFailure, .cannotOpen)
        await orchestrator.stopAndDrain()
    }

    func testHotPlugStopsRemovedNodeAndRecreatesItOnReconnect() async {
        var engines: [TestPlaybackEngine] = []
        let orchestrator = DesktopPlaybackOrchestrator {
            let engine = TestPlaybackEngine()
            engines.append(engine)
            return engine
        }
        let display = displayID("hotplug")
        let assignment = assignment(display, itemID: itemID("hotplug.mp4"))
        try? await orchestrator.start(
            assignments: [assignment],
            surfaces: [display: TestPlaybackSurface(id: .desktop)]
        ) { self.source(for: $0) }
        await waitUntil { engines.first?.isPlaying == true }
        let firstStopCount = engines[0].stopCount

        orchestrator.removeSurface(for: display)

        XCTAssertTrue(orchestrator.activeDisplayIDs.isEmpty)
        XCTAssertFalse(engines[0].isPlaying)
        XCTAssertGreaterThan(engines[0].stopCount, firstStopCount)

        let reconnectedSurface = TestPlaybackSurface(id: .desktop)
        reconnectedSurface.isReadyForDisplay = false
        orchestrator.addSurface(reconnectedSurface, for: display)
        await waitUntil {
            engines.count == 2
                && engines[1].attachmentReadinessPolicies == [.deferred]
        }

        XCTAssertEqual(orchestrator.displayStates[display], .loading)
        XCTAssertFalse(engines[1].isPlaying)

        reconnectedSurface.isReadyForDisplay = true
        try? await Task.sleep(
            nanoseconds: PlaybackPolicy.surfacePollIntervalNanoseconds * 2
        )
        await waitUntil { engines[1].isPlaying }

        XCTAssertEqual(orchestrator.activeDisplayIDs, [display])
        XCTAssertEqual(orchestrator.displayStates[display], .playing)
        XCTAssertEqual(
            engines[1].attachmentReadinessPolicies,
            [.deferred]
        )
    }

    func testItemCompletionLoopsAndShutdownMakesCallbacksInert() async {
        let engine = TestPlaybackEngine()
        let display = displayID("loop")
        let orchestrator = DesktopPlaybackOrchestrator { engine }
        try? await orchestrator.start(
            assignments: [assignment(display, itemID: itemID("loop.mp4"))],
            surfaces: [display: TestPlaybackSurface(id: .desktop)]
        ) { self.source(for: $0) }
        await waitUntil { engine.isPlaying }

        engine.emitItemEnded()

        XCTAssertEqual(engine.soughtTimes.last, 0)
        XCTAssertTrue(engine.isPlaying)

        orchestrator.shutdown()
        await orchestrator.stopAndDrain()
        engine.emitFailure(.cannotOpen)

        XCTAssertTrue(orchestrator.activeDisplayIDs.isEmpty)
        XCTAssertTrue(orchestrator.displayStates.isEmpty)
        XCTAssertTrue(orchestrator.displayFailures.isEmpty)
        XCTAssertFalse(engine.isPlaying)
    }

    func testStartWaitsForFirstReadyDisplayAndRequiresInitialFrame() async
        throws {
        let blockedEngine = TestPlaybackEngine()
        blockedEngine.shouldBlockLoads = true
        let readyEngine = TestPlaybackEngine()
        var availableEngines = [blockedEngine, readyEngine]
        let first = displayID("a-blocked")
        let second = displayID("b-ready")
        let orchestrator = DesktopPlaybackOrchestrator(
            initialReadinessTimeout: nil
        ) {
            availableEngines.removeFirst()
        }

        try await orchestrator.start(
            assignments: [
                assignment(first, itemID: itemID("blocked.mp4")),
                assignment(second, itemID: itemID("ready.mp4"))
            ],
            surfaces: [
                first: TestPlaybackSurface(id: .desktop),
                second: TestPlaybackSurface(id: .desktop)
            ]
        ) { self.source(for: $0) }

        XCTAssertEqual(orchestrator.displayStates[second], .playing)
        XCTAssertEqual(
            readyEngine.attachmentReadinessPolicies,
            [.required]
        )
        await orchestrator.stopAndDrain()
    }

    func testStartThrowsWhenEveryCandidateFails() async {
        let firstEngine = TestPlaybackEngine()
        let secondEngine = TestPlaybackEngine()
        firstEngine.loadErrorsByURL[
            source(for: itemID("unsupported.mp4")).url
        ] = .unsupported
        secondEngine.loadErrorsByURL[
            source(for: itemID("broken.mp4")).url
        ] = .cannotOpen
        var availableEngines = [firstEngine, secondEngine]
        let orchestrator = DesktopPlaybackOrchestrator {
            availableEngines.removeFirst()
        }

        do {
            try await orchestrator.start(
                assignments: [
                    assignment(
                        displayID("first"),
                        itemID: itemID("unsupported.mp4")
                    ),
                    assignment(
                        displayID("second"),
                        itemID: itemID("broken.mp4")
                    )
                ],
                surfaces: [
                    displayID("first"):
                        TestPlaybackSurface(id: .desktop),
                    displayID("second"):
                        TestPlaybackSurface(id: .desktop)
                ]
            ) { self.source(for: $0) }
            XCTFail("Expected all failed displays to reject desktop entry")
        } catch let error as PlaybackEngineError {
            XCTAssertEqual(error, .cannotOpen)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await orchestrator.stopAndDrain()
    }

    func testSelectiveStopAndDrainWaitsForCancelledLoad() async throws {
        let blockedEngine = TestPlaybackEngine()
        blockedEngine.shouldBlockLoads = true
        let readyEngine = TestPlaybackEngine()
        var availableEngines = [blockedEngine, readyEngine]
        let blockedItem = itemID("blocked.mp4")
        let readyItem = itemID("ready.mp4")
        let blockedDisplay = displayID("a-blocked")
        let readyDisplay = displayID("b-ready")
        let orchestrator = DesktopPlaybackOrchestrator(
            initialReadinessTimeout: nil
        ) {
            availableEngines.removeFirst()
        }
        try await orchestrator.start(
            assignments: [
                assignment(blockedDisplay, itemID: blockedItem),
                assignment(readyDisplay, itemID: readyItem)
            ],
            surfaces: [
                blockedDisplay: TestPlaybackSurface(id: .desktop),
                readyDisplay: TestPlaybackSurface(id: .desktop)
            ]
        ) { self.source(for: $0) }

        XCTAssertTrue(orchestrator.activeMediaItemIDs.contains(blockedItem))
        await orchestrator.stopAndDrain(itemIDs: [blockedItem])

        XCTAssertFalse(orchestrator.activeMediaItemIDs.contains(blockedItem))
        XCTAssertTrue(orchestrator.activeMediaItemIDs.contains(readyItem))
        XCTAssertEqual(orchestrator.activeDisplayIDs, [readyDisplay])
        XCTAssertTrue(readyEngine.isPlaying)
        await orchestrator.stopAndDrain()
    }

    private func displayID(_ value: String) -> DesktopDisplayID {
        DesktopDisplayID(rawValue: value)
    }

    private func itemID(_ fileName: String) -> LibraryMediaItem.ID {
        LibraryMediaItem.ID(
            rootPath: "/tmp/desktop-playback",
            relativePath: fileName
        )
    }

    private func assignment(
        _ displayID: DesktopDisplayID,
        itemID: LibraryMediaItem.ID,
        isEnabled: Bool = true
    ) -> DesktopDisplayAssignment {
        DesktopDisplayAssignment(
            displayID: displayID,
            isEnabled: isEnabled,
            contentMode: .contain,
            mediaItemID: itemID
        )
    }

    private func source(
        for itemID: LibraryMediaItem.ID
    ) -> ResolvedMediaSource {
        ResolvedMediaSource(
            url: URL(fileURLWithPath: itemID.standardizedMediaPath),
            displayName: itemID.relativePath
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
