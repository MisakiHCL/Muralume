import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class SeamlessPlaybackTransitionTests: XCTestCase {
    private enum ReplayExpectation {
        static let endProbeOffset: TimeInterval = 0.2
        static let minimumReplayProgress: TimeInterval = 0.1
        static let pollAttempts = 100
        static let pollInterval: Duration = .milliseconds(50)
    }

    func testPlayerQueueRetainsEndedItemForRepeatedReplay() async throws {
        let queuePlayer = AVQueuePlayer()
        let engine = AVFoundationPlaybackEngine(player: queuePlayer)
        let playback = PlaybackCoordinator(engine: engine)
        var completionCount = 0
        playback.itemEndedHandler = {
            completionCount += 1
            return .repeatCurrent
        }
        defer { playback.shutdown() }

        let sourceURL = try TestMediaFixture.h264URL(for: Self.self)
        let result = await playback.load(
            ResolvedMediaSource(
                url: sourceURL,
                displayName: sourceURL.lastPathComponent
            )
        )
        XCTAssertEqual(result, .loaded)
        let originalItem = try XCTUnwrap(queuePlayer.currentItem)
        XCTAssertEqual(queuePlayer.actionAtItemEnd, .pause)

        for expectedCompletionCount in 1...2 {
            await engine.seekBeforePlayback(
                to: playback.duration - ReplayExpectation.endProbeOffset
            )
            let didReplay = try await waitUntil {
                completionCount == expectedCompletionCount
                    && queuePlayer.currentTime().seconds
                        > ReplayExpectation.minimumReplayProgress
                    && queuePlayer.currentTime().seconds
                        < playback.duration
                            - ReplayExpectation.endProbeOffset
                    && queuePlayer.rate > 0
            }

            XCTAssertTrue(didReplay)
            XCTAssertTrue(queuePlayer.currentItem === originalItem)
            XCTAssertEqual(queuePlayer.items().count, 1)
            XCTAssertTrue(playback.isPlaybackRequested)
        }
    }

    func testLoadingPlayerItemAfterSeamlessLoopRestoresPauseAtEnd()
        async throws {
        let queuePlayer = AVQueuePlayer()
        let engine = AVFoundationPlaybackEngine(player: queuePlayer)
        defer { engine.stop() }
        let sourceURL = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(
            url: sourceURL,
            displayName: sourceURL.lastPathComponent
        )

        engine.setLooping(true)
        _ = try await engine.load(source)
        XCTAssertEqual(queuePlayer.actionAtItemEnd, .advance)

        engine.setLooping(false)
        _ = try await engine.load(source)

        XCTAssertEqual(queuePlayer.actionAtItemEnd, .pause)
        XCTAssertEqual(queuePlayer.items().count, 1)
    }

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

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<ReplayExpectation.pollAttempts {
            if condition() {
                return true
            }
            try await Task.sleep(for: ReplayExpectation.pollInterval)
        }
        return condition()
    }
}
