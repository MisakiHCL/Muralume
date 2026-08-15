import XCTest
@testable import Muralume

@MainActor
final class DesktopEnergyPolicyTests: XCTestCase {
    func testSmartPausePolicyMapsOnlyEnabledEnergyReasons() {
        let preferences = SmartPausePreferences(
            isEnabled: true,
            pauseWhenDesktopHidden: true,
            pauseInLowPowerMode: true,
            pauseOnLimitedPowerSource: false,
            pauseUnderSustainedSystemLoad: true
        )

        XCTAssertEqual(
            SmartPausePolicy.globalSuspensionReasons(
                constraints: [
                    .lowPowerMode,
                    .limitedPowerSource,
                    .sustainedSystemLoad,
                    .thermalPressure
                ],
                preferences: preferences
            ),
            [.desktopLowPowerMode, .desktopSustainedSystemLoad]
        )
        XCTAssertTrue(
            SmartPausePolicy.globalSuspensionReasons(
                constraints: [.lowPowerMode],
                preferences: SmartPausePreferences(
                    isEnabled: false,
                    pauseWhenDesktopHidden: true,
                    pauseInLowPowerMode: true,
                    pauseOnLimitedPowerSource: true,
                    pauseUnderSustainedSystemLoad: true
                )
            ).isEmpty
        )
    }

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

    func testManualPauseDuringSmartPausePreventsAutomaticResume() async {
        let fixture = makeFixture()
        defer { fixture.session.shutdown() }
        fixture.playback.registerPlayerSurface(
            TestPlaybackSurface(id: .player)
        )
        await fixture.playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/manual-pause.mp4"),
                displayName: "Manual Pause"
            )
        )
        fixture.session.enterDesktop()
        await waitUntil { fixture.session.isActive }

        fixture.host.emitDesktopOcclusion(true)
        fixture.playback.setPlaybackIntent(.paused)
        fixture.host.emitDesktopOcclusion(false)

        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
    }

    func testDisablingSmartPauseKeepsMandatoryLowBatteryProtection() async {
        let fixture = makeFixture()
        defer { fixture.session.shutdown() }
        fixture.playback.registerPlayerSurface(
            TestPlaybackSurface(id: .player)
        )
        await fixture.playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/low-power.mp4"),
                displayName: "Low Power"
            )
        )
        fixture.session.enterDesktop()
        await waitUntil { fixture.session.isActive }

        fixture.lifecycle.emitEnergyConstraints([.lowPowerMode])
        fixture.lifecycle.emit(.lowBattery, suspended: true)
        XCTAssertFalse(fixture.engine.isPlaying)

        fixture.session.updateSmartPausePreferences(
            SmartPausePreferences(
                isEnabled: false,
                pauseWhenDesktopHidden: true,
                pauseInLowPowerMode: true,
                pauseOnLimitedPowerSource: false,
                pauseUnderSustainedSystemLoad: false
            )
        )
        XCTAssertFalse(fixture.engine.isPlaying)

        fixture.lifecycle.emit(.lowBattery, suspended: false)
        XCTAssertTrue(fixture.engine.isPlaying)
    }

    func testStatusDistinguishesSmartPauseFromManualPause() async {
        let fixture = makeFixture()
        defer { fixture.session.shutdown() }
        let playerSurface = TestPlaybackSurface(id: .player)
        fixture.playback.registerPlayerSurface(playerSurface)
        await fixture.playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/status.mp4"),
                displayName: "Status"
            )
        )
        fixture.session.enterDesktop()
        await waitUntil { fixture.session.isActive }

        fixture.lifecycle.emitEnergyConstraints([.lowPowerMode])
        XCTAssertEqual(
            fixture.status.stateProvider?().smartPauseStatus,
            DesktopSmartPauseStatus(
                primaryReason: .lowPowerMode,
                pausedDisplayCount: 1,
                enabledDisplayCount: 1
            )
        )

        fixture.playback.setPlaybackIntent(.paused)
        XCTAssertNil(fixture.status.stateProvider?().smartPauseStatus)
        withExtendedLifetime(playerSurface) {}
    }

    private func makeFixture() -> (
        engine: TestPlaybackEngine,
        playback: PlaybackCoordinator,
        host: TestDesktopHost,
        lifecycle: TestSystemLifecycleMonitor,
        status: TestDesktopStatusPresenter,
        session: DesktopSessionCoordinator
    ) {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let host = TestDesktopHost()
        let lifecycle = TestSystemLifecycleMonitor()
        let status = TestDesktopStatusPresenter()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: host,
            statusMenu: status,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: lifecycle,
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        return (engine, playback, host, lifecycle, status, session)
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
