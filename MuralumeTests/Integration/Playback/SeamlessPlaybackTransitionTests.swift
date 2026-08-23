import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class SeamlessPlaybackTransitionTests: XCTestCase {
    func testLoopingEngineUsesAVPlayerLooperQueue() async throws {
        let queuePlayer = AVQueuePlayer()
        let engine = AVFoundationPlaybackEngine(player: queuePlayer)
        engine.setLooping(true)
        defer { engine.stop() }

        let sourceURL = try TestMediaFixture.h264URL(for: Self.self)
        let duration = try await engine.load(
            ResolvedMediaSource(
                url: sourceURL,
                displayName: sourceURL.lastPathComponent
            )
        )

        XCTAssertEqual(duration, TestMediaFixture.duration, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(queuePlayer.items().count, 2)
        XCTAssertEqual(queuePlayer.actionAtItemEnd, .advance)

        engine.stop()
        XCTAssertTrue(queuePlayer.items().isEmpty)
    }

    func testCrossfadePreparesIncomingPlayerBeforeRetiringOutgoingPlayer()
        async throws {
        let outgoingPlayer = AVPlayer()
        let engine = AVFoundationPlaybackEngine(player: outgoingPlayer)
        let surface = TestAVPlayerSurface(id: .player)
        let sourceURL = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(
            url: sourceURL,
            displayName: sourceURL.lastPathComponent
        )
        defer { engine.stop() }

        _ = try await engine.load(source)
        try await engine.attach(to: surface)
        let outgoingIdentity = surface.connectedPlayerIdentity
        engine.play(at: PlaybackPolicy.defaultRate)

        let duration: TimeInterval = 0.08
        _ = try await engine.load(
            source,
            transition: .crossfade(duration: duration)
        )

        XCTAssertEqual(surface.preparedTransitionCount, 1)
        XCTAssertEqual(surface.committedTransitionDurations, [duration])
        XCTAssertNotEqual(surface.connectedPlayerIdentity, outgoingIdentity)
        XCTAssertNotNil(outgoingPlayer.currentItem)

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(outgoingPlayer.currentItem)
    }

    func testPlayerAndDesktopSurfacesCommitPreparedIncomingPlayer() {
        let outgoingPlayer = AVPlayer()
        let incomingPlayer = AVPlayer()
        let playerSurface = PlayerLayerSurfaceView(
            id: .player,
            videoGravity: .resizeAspect
        )
        let desktopSurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .contain
        )

        playerSurface.connect(to: outgoingPlayer)
        playerSurface.prepareTransition(to: incomingPlayer)
        playerSurface.commitPreparedTransition(duration: 0)

        desktopSurface.connect(to: outgoingPlayer)
        desktopSurface.prepareTransition(to: incomingPlayer)
        desktopSurface.commitPreparedTransition(duration: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(
            playerSurface.connectedPlayerIdentity,
            ObjectIdentifier(incomingPlayer)
        )
        XCTAssertEqual(
            desktopSurface.connectedPlayerIdentity,
            ObjectIdentifier(incomingPlayer)
        )
    }
}
