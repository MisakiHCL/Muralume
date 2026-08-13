import XCTest
@testable import Muralume

@MainActor
final class PlaybackEnergyPolicyTests: XCTestCase {
    func testDesktopOnlyPressureKeepsPlayerRunningAndPausesDesktop()
        async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        await loadMedia(in: coordinator)

        coordinator.setSuspended(true, for: .lowBattery)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.progressCadence, .visible)
        XCTAssertFalse(coordinator.isSystemSuspended)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.progressCadence, .inactive)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(coordinator.isSystemSuspended)

        try await coordinator.transitionToPlayer()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.progressCadence, .visible)
        XCTAssertFalse(coordinator.isSystemSuspended)
    }

    func testOverlappingDesktopReasonsMustAllClearBeforeResume()
        async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        await loadMedia(in: coordinator)
        try await coordinator.transitionToDesktop(desktopSurface)

        coordinator.setSuspended(true, for: .desktopOccluded)
        coordinator.setSuspended(true, for: .desktopThermalPressure)
        coordinator.setSuspended(false, for: .desktopOccluded)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(coordinator.isPlaybackRequested)

        coordinator.setSuspended(false, for: .desktopThermalPressure)
        XCTAssertTrue(engine.isPlaying)
    }

    func testCriticalThermalPressureStillBlocksEveryPresentation()
        async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        await loadMedia(in: coordinator)

        coordinator.setSuspended(true, for: .thermalPressure)
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)
        try await coordinator.transitionToPlayer()
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .thermalPressure)
        XCTAssertTrue(engine.isPlaying)
    }

    func testDuplicateSuspensionUpdatesDoNotReapplyPlaybackGate() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await loadMedia(in: coordinator)

        coordinator.setSuspended(true, for: .thermalPressure)
        let pauseCount = engine.pauseCount
        let cadenceChangeCount = engine.progressCadenceChanges.count

        coordinator.setSuspended(true, for: .thermalPressure)
        XCTAssertEqual(engine.pauseCount, pauseCount)
        XCTAssertEqual(
            engine.progressCadenceChanges.count,
            cadenceChangeCount
        )

        coordinator.setSuspended(false, for: .thermalPressure)
        let playCount = engine.playCount
        coordinator.setSuspended(false, for: .thermalPressure)
        XCTAssertEqual(engine.playCount, playCount)
    }

    private func loadMedia(in coordinator: PlaybackCoordinator) async {
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/energy-policy.mp4"),
                displayName: "Energy Policy"
            )
        )
    }
}
