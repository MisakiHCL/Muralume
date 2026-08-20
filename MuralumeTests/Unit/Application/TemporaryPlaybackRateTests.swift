import XCTest
@testable import Muralume

@MainActor
final class TemporaryPlaybackRateTests: XCTestCase {
    func testTemporaryRateOverridesWithoutPersistingAndRestoresLatestRate()
        async {
        let engine = TestPlaybackEngine()
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            preferencesStore: preferencesStore
        )
        await loadReadyMedia(in: coordinator)

        let token = coordinator.beginTemporaryPlaybackRate(
            PlaybackPolicy.temporaryFastForwardRate
        )

        XCTAssertNotNil(token)
        XCTAssertEqual(
            coordinator.temporaryPlaybackRate,
            PlaybackPolicy.temporaryFastForwardRate
        )
        XCTAssertEqual(engine.rate, PlaybackPolicy.temporaryFastForwardRate)
        XCTAssertTrue(preferencesStore.savedPlaybackRates.isEmpty)

        let updatedRate = PlaybackRate(rawValue: 1.5)
        coordinator.setRate(updatedRate)

        XCTAssertEqual(coordinator.settings.rate, updatedRate)
        XCTAssertEqual(engine.rate, PlaybackPolicy.temporaryFastForwardRate)
        XCTAssertEqual(preferencesStore.savedPlaybackRates, [updatedRate])

        coordinator.endTemporaryPlaybackRate(try! XCTUnwrap(token))

        XCTAssertNil(coordinator.temporaryPlaybackRate)
        XCTAssertEqual(engine.rate, updatedRate)
        XCTAssertEqual(preferencesStore.savedPlaybackRates, [updatedRate])
    }

    func testTemporaryRateCannotBeginWhilePaused() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await loadReadyMedia(in: coordinator, autoplay: false)

        let token = coordinator.beginTemporaryPlaybackRate(
            PlaybackPolicy.temporaryFastForwardRate
        )

        XCTAssertNil(token)
        XCTAssertNil(coordinator.temporaryPlaybackRate)
        XCTAssertFalse(engine.isPlaying)
    }

    func testPausingClearsTemporaryRateAndStaleReleaseDoesNotResume() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await loadReadyMedia(in: coordinator)
        let token = try! XCTUnwrap(
            coordinator.beginTemporaryPlaybackRate(
                PlaybackPolicy.temporaryFastForwardRate
            )
        )

        coordinator.setPlaybackIntent(.paused)

        XCTAssertNil(coordinator.temporaryPlaybackRate)
        XCTAssertFalse(engine.isPlaying)

        coordinator.endTemporaryPlaybackRate(token)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(coordinator.isPlaybackRequested)
    }

    func testReplacementLoadClearsTemporaryRate() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await loadReadyMedia(in: coordinator)
        _ = coordinator.beginTemporaryPlaybackRate(
            PlaybackPolicy.temporaryFastForwardRate
        )

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/replacement.mp4"),
                displayName: "Replacement"
            ),
            autoplay: false
        )

        XCTAssertNil(coordinator.temporaryPlaybackRate)
        XCTAssertFalse(engine.isPlaying)
    }

    func testDesktopTransitionClearsTemporaryRate() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await loadReadyMedia(in: coordinator)
        _ = coordinator.beginTemporaryPlaybackRate(
            PlaybackPolicy.temporaryFastForwardRate
        )

        try await coordinator.transitionToDesktop(
            TestPlaybackSurface(id: .desktop)
        )

        XCTAssertNil(coordinator.temporaryPlaybackRate)
        XCTAssertEqual(coordinator.presentation, .desktop)
    }

    private func loadReadyMedia(
        in coordinator: PlaybackCoordinator,
        autoplay: Bool = true
    ) async {
        let result = await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            ),
            autoplay: autoplay,
            attachToPlayerSurface: false
        )
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(coordinator.readiness, .ready)
    }
}
