import XCTest
@testable import Muralume

@MainActor
final class DesktopEnergyPolicyTests: XCTestCase {
    func testOverlappingEnergyConstraintsDoNotRestoreEffectsEarly() {
        let fixture = makeFixture()
        defer { fixture.session.shutdown() }

        fixture.lifecycle.emitEnergyConstraints([.limitedPowerSource])
        fixture.lifecycle.emitEnergyConstraints([
            .limitedPowerSource,
            .thermalPressure
        ])
        fixture.lifecycle.emitEnergyConstraints([.thermalPressure])

        XCTAssertEqual(fixture.host.appliedEnergyConstraints, [true])

        fixture.lifecycle.emitEnergyConstraints([])
        XCTAssertEqual(
            fixture.host.appliedEnergyConstraints,
            [true, false]
        )
    }

    func testDesktopOcclusionPausesAndRestoresOriginalIntent() async {
        let fixture = makeFixture()
        defer { fixture.session.shutdown() }
        let playerSurface = TestPlaybackSurface(id: .player)
        fixture.playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await fixture.playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/occlusion.mp4"),
                displayName: "Occlusion"
            )
        )
        fixture.session.enterDesktop()
        await waitUntil {
            fixture.session.isActive && !fixture.session.isTransitioning
        }

        fixture.host.emitDesktopOcclusion(true)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        fixture.host.emitDesktopOcclusion(false)
        XCTAssertTrue(fixture.engine.isPlaying)
        XCTAssertEqual(fixture.lifecycle.desktopMonitoringStates, [true])

        fixture.session.returnToPlayer()
        await waitUntil {
            !fixture.session.isActive
                && fixture.playback.presentation == .player
        }
        XCTAssertEqual(
            fixture.lifecycle.desktopMonitoringStates,
            [true, false]
        )
        withExtendedLifetime(playerSurface) {}
    }

    private func makeFixture() -> (
        engine: TestPlaybackEngine,
        playback: PlaybackCoordinator,
        host: TestDesktopHost,
        lifecycle: TestSystemLifecycleMonitor,
        session: DesktopSessionCoordinator
    ) {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let host = TestDesktopHost()
        let lifecycle = TestSystemLifecycleMonitor()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: host,
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: lifecycle,
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        return (engine, playback, host, lifecycle, session)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
