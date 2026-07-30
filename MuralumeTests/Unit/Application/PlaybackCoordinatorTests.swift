import XCTest
@testable import Muralume

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testMuteSetsVolumeToZeroAndUnmuteRestoresPreviousVolume() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let previousVolume = PlaybackVolume(rawValue: 0.4)

        coordinator.setVolume(previousVolume)
        coordinator.setMuted(true)

        XCTAssertTrue(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, .muted)
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.volume, .muted)

        coordinator.setMuted(false)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, previousVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, previousVolume)
    }

    func testRepeatedMuteAndZeroAdjustmentPreserveRestorableVolume() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let previousVolume = PlaybackVolume(rawValue: 0.4)

        coordinator.setVolume(previousVolume)
        coordinator.setMuted(true)
        coordinator.setMuted(true)
        coordinator.setVolume(.muted)
        coordinator.setMuted(false)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, previousVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, previousVolume)
    }

    func testNonzeroVolumeAdjustmentWhileMutedUnmutesAndBecomesRestorable() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let adjustedVolume = PlaybackVolume(rawValue: 0.25)

        coordinator.setMuted(true)
        coordinator.setVolume(adjustedVolume)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, adjustedVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, adjustedVolume)

        coordinator.setMuted(true)
        coordinator.setMuted(false)

        XCTAssertEqual(coordinator.settings.volume, adjustedVolume)
        XCTAssertEqual(engine.volume, adjustedVolume)
    }

    func testVolumeAdjustmentUsesFixedStepAndClampsAtBounds() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        coordinator.adjustVolume(by: -PlaybackPolicy.volumeStep)

        XCTAssertEqual(
            coordinator.settings.volume.rawValue,
            0.9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            engine.volume.rawValue,
            0.9,
            accuracy: 0.0001
        )

        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)
        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)

        XCTAssertEqual(coordinator.settings.volume, .full)
        XCTAssertEqual(engine.volume, .full)

        for _ in 0..<20 {
            coordinator.adjustVolume(by: -PlaybackPolicy.volumeStep)
        }

        XCTAssertEqual(coordinator.settings.volume, .muted)
        XCTAssertEqual(engine.volume, .muted)
    }

    func testIncreasingVolumeWhileMutedUnmutesAtFirstStep() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.setMuted(true)

        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(
            coordinator.settings.volume.rawValue,
            PlaybackPolicy.volumeStep,
            accuracy: 0.0001
        )
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(
            engine.volume.rawValue,
            PlaybackPolicy.volumeStep,
            accuracy: 0.0001
        )
    }

    func testLoadAfterStopReattachesTheRegisteredPlayerSurface() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)

        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        coordinator.stop()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
        XCTAssertEqual(engine.attachedSurfaceIDs, [.player])
    }

    func testDesktopRoundTripUsesTheSameEngineAndRestoresPlayerSettings() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setVolume(PlaybackVolume(rawValue: 0.4))
        coordinator.setMuted(false)
        coordinator.setRate(PlaybackRate(rawValue: 1.5))

        try await coordinator.transitionToDesktop(desktopSurface)

        XCTAssertEqual(coordinator.presentation, .desktop)
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 1.5))

        coordinator.setRate(PlaybackRate(rawValue: 2))
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 2))

        try await coordinator.transitionToPlayer()

        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, PlaybackVolume(rawValue: 0.4))
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 2))
        XCTAssertTrue(engine.attachedSurfaceIDs.contains(.desktop))
        XCTAssertEqual(engine.attachedSurfaceIDs.last, .player)
    }

    func testRemovingOnlyOneSystemReasonDoesNotResumeDesktopPlayback() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        try await coordinator.transitionToDesktop(desktopSurface)

        coordinator.setSuspended(true, for: .screenLocked)
        coordinator.setSuspended(true, for: .displaySleeping)
        coordinator.setSuspended(false, for: .screenLocked)

        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .displaySleeping)
        XCTAssertTrue(engine.isPlaying)
    }

    func testSuspensionRecordedInPlayerRemainsEffectiveAcrossDesktopRoundTrips() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setSuspended(true, for: .screenLocked)
        XCTAssertTrue(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToPlayer()
        XCTAssertTrue(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .screenLocked)
        XCTAssertTrue(engine.isPlaying)
    }

    func testEngineFailureResetsPlaybackAndNotifiesTheApp() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var reportedFailure: PlaybackFailure?
        coordinator.playbackFailureHandler = { failure in
            reportedFailure = failure
        }

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        engine.emitFailure(.cannotOpen)

        XCTAssertEqual(coordinator.readiness, .failed(.cannotOpen))
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(coordinator.isActuallyPlaying)
        XCTAssertEqual(reportedFailure, .cannotOpen)
    }

    func testDismissingPlayerWindowPausesWithoutClearingProcessState() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(source)
        engine.progressHandler?(42)

        coordinator.dismissPlayerWindow()

        XCTAssertTrue(coordinator.isPlayerWindowDismissed)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)

        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testDismissDuringLoadRevokesAutoplayAfterImmediateReopen() async {
        let engine = TestPlaybackEngine()
        engine.shouldBlockLoads = true
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        coordinator.registerPlayerSurface(playerSurface)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )

        let loadTask = Task {
            await coordinator.load(source)
        }
        while !engine.didBeginBlockedLoad {
            await Task.yield()
        }

        coordinator.dismissPlayerWindow()
        coordinator.restorePlayerWindow()
        engine.finishBlockedLoad()

        let loadResult = await loadTask.value
        XCTAssertEqual(loadResult, .loaded)
        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testShutdownCannotBeRolledBackByACancelledTransition() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        engine.shouldBlockAttachments = true

        let transition = Task {
            try await coordinator.transitionToDesktop(desktopSurface)
        }
        while !engine.didBeginBlockedAttachment {
            await Task.yield()
        }

        coordinator.shutdown()
        transition.cancel()
        _ = try? await transition.value

        XCTAssertEqual(coordinator.presentation, .terminating)
        XCTAssertFalse(engine.isPlaying)
    }
}
