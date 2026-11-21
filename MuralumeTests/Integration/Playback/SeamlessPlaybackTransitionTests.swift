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

    func testSwitchingLoopModesRestoresMatchingEndAction()
        async throws {
        let queuePlayer = AVQueuePlayer()
        let engine = AVFoundationPlaybackEngine(player: queuePlayer)
        defer { engine.stop() }
        let sourceURL = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(
            url: sourceURL,
            displayName: sourceURL.lastPathComponent
        )

        for isLooping in [false, true, false, true, false] {
            engine.setLooping(isLooping)
            _ = try await engine.load(source)
            XCTAssertEqual(
                queuePlayer.actionAtItemEnd,
                isLooping ? .advance : .pause
            )
            if !isLooping {
                XCTAssertEqual(queuePlayer.items().count, 1)
            }
        }
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

        let retired = try await waitUntil { outgoingPlayer.currentItem == nil }
        XCTAssertTrue(retired, "The outgoing player should release its item after the crossfade")
    }

    func testDesktopCrossfadePreparesTheSavedPositionBeforePresentingTheIncomingVideo() async throws {
        let playback = PlaybackCoordinator(engine: AVFoundationPlaybackEngine(player: AVPlayer()))
        let desktop = TestAVPlayerSurface(id: .desktop)
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(url: url, displayName: url.lastPathComponent)
        defer { playback.shutdown() }

        let initial = await playback.load(source)
        XCTAssertEqual(initial, .loaded)
        try await playback.transitionToDesktop(desktop)

        let resumePosition = playback.duration / 2
        XCTAssertGreaterThan(resumePosition, 0)
        let next = await playback.load(source, initialPosition: resumePosition, transition: .crossfade(duration: 0.08))
        XCTAssertEqual(next, .loaded)
        XCTAssertEqual(try XCTUnwrap(desktop.preparedPlayerTime), resumePosition, accuracy: 0.05)
        XCTAssertEqual(desktop.committedTransitionDurations, [0.08])
    }

    func testSupersededDesktopCrossfadeCannotCancelTheNewestPreparedPlayer() async throws {
        let outgoing = AVPlayer()
        let engine = AVFoundationPlaybackEngine(player: outgoing)
        let surface = TestAVPlayerSurface(id: .desktop)
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(url: url, displayName: url.lastPathComponent)
        defer { engine.stop() }

        _ = try await engine.load(source)
        try await engine.attach(to: surface)
        surface.isReadyForDisplay = false
        let first = Task { try await engine.load(source, transition: .crossfade(duration: 0.08)) }
        defer { first.cancel() }
        let firstPrepared = try await waitUntil { surface.preparedTransitionCount == 1 }
        XCTAssertTrue(firstPrepared)

        let latest = Task { try await engine.load(source, transition: .crossfade(duration: 0.08)) }
        defer { latest.cancel() }
        let latestPrepared = try await waitUntil { surface.preparedTransitionCount == 2 }
        XCTAssertTrue(latestPrepared)
        do {
            _ = try await first.value
            XCTFail("The superseded load completed")
        } catch {
            XCTAssertEqual(error as? PlaybackEngineError, .superseded)
        }
        surface.isReadyForDisplay = true
        _ = try await latest.value
        XCTAssertEqual(surface.committedTransitionDurations, [0.08])
        XCTAssertNotEqual(surface.connectedPlayerIdentity, ObjectIdentifier(outgoing))
    }

    func testReturningToPlayerDuringDesktopPrerollFinishesTheSelectedLoad() async throws {
        let outgoing = AVPlayer()
        let playback = PlaybackCoordinator(engine: AVFoundationPlaybackEngine(player: outgoing))
        let desktop = TestAVPlayerSurface(id: .desktop)
        let window = TestAVPlayerSurface(id: .player)
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(url: url, displayName: url.lastPathComponent)
        defer { playback.shutdown() }
        playback.registerPlayerSurface(window)
        let initial = await playback.load(source)
        XCTAssertEqual(initial, .loaded)
        try await playback.transitionToDesktop(desktop)

        desktop.isReadyForDisplay = false
        let next = Task { await playback.load(source, transition: .crossfade(duration: 0.08)) }
        defer { next.cancel() }
        let prerollStarted = try await waitUntil { desktop.preparedTransitionCount == 1 }
        XCTAssertTrue(prerollStarted)
        try await playback.transitionToPlayer()
        let result = await next.value
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(playback.readiness, .ready)
        XCTAssertEqual(playback.presentation, .player)
        XCTAssertNotNil(window.connectedPlayerIdentity)
        XCTAssertNotEqual(window.connectedPlayerIdentity, ObjectIdentifier(outgoing))
        XCTAssertNil(desktop.connectedPlayerIdentity)
        XCTAssertTrue(desktop.committedTransitionDurations.isEmpty)
    }

    func testDesktopCrossfadeDoesNotTargetADisconnectedSurfaceAfterMetadataLoad() async throws {
        let outgoing = AVPlayer()
        let desktop = TestAVPlayerSurface(id: .desktop)
        let window = TestAVPlayerSurface(id: .player)
        var returnToPlayer: (() async throws -> Void)?
        let loader = AVFoundationAssetLoadController(metadataLoader: { asset in
            try await returnToPlayer?()
            return try await AVFoundationAssetMetadata(
                isPlayable: asset.load(.isPlayable), duration: asset.load(.duration),
                videoTracks: asset.loadTracks(withMediaType: .video), audioGroup: nil, subtitleGroup: nil
            )
        })
        let engine = AVFoundationPlaybackEngine(player: outgoing, assetLoadController: loader)
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let source = ResolvedMediaSource(url: url, displayName: url.lastPathComponent)
        defer { engine.stop() }
        _ = try await engine.load(source)
        try await engine.attach(to: desktop)
        returnToPlayer = { [weak engine] in
            try await engine?.attach(to: window)
            engine?.progressHandler = { _ in }
            engine?.setProgressCadence(.visible)
            engine?.setExternalSubtitleTimeHandler { _ in }
        }
        _ = try await engine.load(source, transition: .crossfade(duration: 0.08))
        XCTAssertEqual(desktop.preparedTransitionCount, 0)
        XCTAssertNil(desktop.connectedPlayerIdentity)
        XCTAssertNotNil(window.connectedPlayerIdentity)
        XCTAssertNotEqual(window.connectedPlayerIdentity, ObjectIdentifier(outgoing))
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

    func testDesktopCrossfadeKeepsPreparedVideoLayersOnRetainedDisplays()
        async throws {
        let group = DesktopPlayerLayerSurfaceGroup(id: .desktop)
        let blurred = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let fitted = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .contain
        )
        let added = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .cover
        )
        let outgoing = AVPlayer()
        let incoming = AVPlayer()
        group.replaceDisplaySurfaces([blurred, fitted])
        group.connect(to: outgoing)
        defer { group.connect(to: nil) }

        group.prepareTransition(to: incoming)
        let blurredLayers = videoLayers(for: incoming, in: blurred)
        let fittedLayers = videoLayers(for: incoming, in: fitted)
        XCTAssertEqual(blurredLayers.count, 2)
        XCTAssertEqual(fittedLayers.count, 1)
        group.commitPreparedTransition(duration: 0.04)
        XCTAssertFalse(videoLayers(for: outgoing, in: fitted).isEmpty)
        group.replaceDisplaySurfaces([blurred, fitted, added])

        let outgoingRetired = try await waitUntil {
            self.videoLayers(for: outgoing, in: blurred).isEmpty
                && self.videoLayers(for: outgoing, in: fitted).isEmpty
        }
        XCTAssertTrue(outgoingRetired)
        XCTAssertEqual(videoLayers(for: incoming, in: blurred), blurredLayers)
        XCTAssertEqual(videoLayers(for: incoming, in: fitted), fittedLayers)
        XCTAssertEqual(added.connectedPlayerIdentity, ObjectIdentifier(incoming))

        blurred.setEnergyConstrained(true)
        XCTAssertNil(blurred.backgroundConnectedPlayerIdentity)
        XCTAssertEqual(
            videoLayers(for: incoming, in: blurred),
            blurredLayers.filter { $0.videoGravity == .resizeAspect }
        )

        group.prepareTransition(to: outgoing)
        let returningLayers = videoLayers(for: outgoing, in: fitted)
        XCTAssertEqual(returningLayers.count, 1)
        group.commitPreparedTransition(duration: 0)
        let incomingRetired = try await waitUntil {
            self.videoLayers(for: incoming, in: fitted).isEmpty
        }
        XCTAssertTrue(incomingRetired)
        XCTAssertEqual(videoLayers(for: outgoing, in: fitted), returningLayers)
    }

    func testCancellingNextPreparationDuringDesktopFadeKeepsCommittedVideo()
        async throws {
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .cover
        )
        let first = AVPlayer()
        let second = AVPlayer()
        let cancelled = AVPlayer()
        surface.connect(to: first)
        defer { surface.connect(to: nil) }

        surface.prepareTransition(to: second)
        let committedLayers = videoLayers(for: second, in: surface)
        XCTAssertEqual(committedLayers.count, 1)
        surface.commitPreparedTransition(duration: 0.04)
        surface.prepareTransition(to: cancelled)
        surface.cancelPreparedTransition()

        XCTAssertEqual(surface.connectedPlayerIdentity, ObjectIdentifier(second))
        XCTAssertEqual(videoLayers(for: second, in: surface), committedLayers)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(videoLayers(for: second, in: surface), committedLayers)
        XCTAssertTrue(videoLayers(for: cancelled, in: surface).isEmpty)
        XCTAssertTrue(videoLayers(for: first, in: surface).isEmpty)
    }

    private func videoLayers(
        for player: AVPlayer,
        in surface: DesktopPlayerLayerSurfaceView
    ) -> Set<AVPlayerLayer> {
        func matchingLayers(in layer: CALayer) -> [AVPlayerLayer] {
            if let videoLayer = layer as? AVPlayerLayer {
                return videoLayer.player === player ? [videoLayer] : []
            }
            return (layer.sublayers ?? []).flatMap { matchingLayers(in: $0) }
        }
        guard let root = surface.layer else { return [] }
        return Set(matchingLayers(in: root))
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
