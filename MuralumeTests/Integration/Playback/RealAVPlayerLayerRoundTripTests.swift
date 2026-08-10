import AVFoundation
import AppKit
import XCTest
@testable import Muralume

@MainActor
final class RealAVPlayerLayerRoundTripTests: XCTestCase {
    private enum TestConfiguration {
        static let windowSize = NSSize(width: 320, height: 180)
        static let largeDesktopWindowSize = NSSize(width: 1_280, height: 720)
        static let squareDesktopWindowSize = NSSize(width: 560, height: 560)
        static let windowOriginY: CGFloat = 120
        static let playerWindowOriginX: CGFloat = 80
        static let desktopWindowOriginX: CGFloat = 440
        static let secondDesktopWindowOriginX: CGFloat = 800
        static let thirdDesktopWindowOriginX: CGFloat = 1_160
        static let renderingSettleNanoseconds: UInt64 = 300_000_000
        static let hotPlugReadyTimeoutNanoseconds: UInt64 = 5_000_000_000
        static let hotPlugPollIntervalNanoseconds: UInt64 = 50_000_000
        static let geometryAccuracy: CGFloat = 2
        static let landscapeFixtureName = "landscape-20s-h264"
        static let portraitFixtureName = "portrait-20s-h264"
    }

    private struct RenderedVideoGeometry {
        let containerRect: CGRect
        let videoRect: CGRect
    }

    func testEngineWithoutHandlersCanRoundTripBetweenRealPlayerLayers() async throws {
        let engine = AVFoundationPlaybackEngine()
        let playerSurface = PlayerLayerSurfaceView(
            id: .player,
            videoGravity: .resizeAspect
        )
        let desktopSurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let windows = [
            makeWindow(
                for: playerSurface,
                originX: TestConfiguration.playerWindowOriginX
            ),
            makeWindow(
                for: desktopSurface,
                originX: TestConfiguration.desktopWindowOriginX,
                size: TestConfiguration.largeDesktopWindowSize
            )
        ]
        defer {
            engine.stop()
            close(windows)
        }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        try await engine.attach(to: playerSurface)
        engine.play(at: PlaybackPolicy.defaultRate)
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )

        try await engine.attach(to: desktopSurface)
        XCTAssertNotNil(desktopSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(desktopSurface.isBackgroundVisible)
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )
        try await engine.attach(to: playerSurface)

        XCTAssertNil(desktopSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertTrue(playerSurface.isReadyForDisplay)
    }

    func testCoordinatorReattachesTheRealPlayerLayerWhenLoadingAfterStop() async throws {
        let engine = AVFoundationPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = PlayerLayerSurfaceView(
            id: .player,
            videoGravity: .resizeAspect
        )
        let window = makeWindow(
            for: playerSurface,
            originX: TestConfiguration.playerWindowOriginX
        )
        defer {
            coordinator.shutdown()
            close([window])
        }

        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        coordinator.stop()
        XCTAssertNil(playerSurface.connectedPlayerIdentity)

        await coordinator.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )

        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertNotNil(playerSurface.connectedPlayerIdentity)
        XCTAssertTrue(playerSurface.isReadyForDisplay)
        XCTAssertFalse(playerSurface.displayedVideoRect.isEmpty)
    }

    func testCoordinatorCanRoundTripBetweenRealPlayerLayers() async throws {
        let engine = AVFoundationPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = PlayerLayerSurfaceView(
            id: .player,
            videoGravity: .resizeAspect
        )
        let desktopSurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let windows = [
            makeWindow(
                for: playerSurface,
                originX: TestConfiguration.playerWindowOriginX
            ),
            makeWindow(
                for: desktopSurface,
                originX: TestConfiguration.desktopWindowOriginX,
                size: TestConfiguration.largeDesktopWindowSize
            )
        ]
        defer {
            coordinator.shutdown()
            close(windows)
        }

        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        await coordinator.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertNotNil(playerSurface.connectedPlayerIdentity)
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertEqual(coordinator.presentation, .desktop)
        XCTAssertNil(playerSurface.connectedPlayerIdentity)
        XCTAssertNotNil(desktopSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(desktopSurface.isBackgroundVisible)
        XCTAssertEqual(desktopSurface.foregroundVideoGravity, .resizeAspect)
        XCTAssertEqual(desktopSurface.backgroundVideoGravity, .resizeAspectFill)
        XCTAssertTrue(desktopSurface.isReadyForDisplay)

        let backgroundRenderSize = desktopSurface.backgroundRenderSize
        XCTAssertGreaterThan(desktopSurface.bounds.width, 512)
        XCTAssertGreaterThan(backgroundRenderSize.width, 0)
        XCTAssertGreaterThan(backgroundRenderSize.height, 0)
        XCTAssertLessThanOrEqual(
            max(backgroundRenderSize.width, backgroundRenderSize.height),
            512
        )
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )

        try await coordinator.transitionToPlayer()
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertNotNil(playerSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertTrue(playerSurface.isReadyForDisplay)
        XCTAssertFalse(playerSurface.displayedVideoRect.isEmpty)
    }

    func testDesktopContentModeChangesWithoutReattachingThePlayer() async throws {
        XCTAssertEqual(DesktopVideoContentMode.defaultValue, .blurredBackground)
        XCTAssertEqual(
            DesktopVideoContentMode.allCases,
            [.blurredBackground, .cover, .contain]
        )

        let engine = AVFoundationPlaybackEngine()
        let desktopSurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let window = makeWindow(
            for: desktopSurface,
            originX: TestConfiguration.desktopWindowOriginX,
            size: TestConfiguration.squareDesktopWindowSize
        )
        defer {
            engine.stop()
            close([window])
        }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        try await engine.attach(to: desktopSurface)
        let connectedPlayerIdentity = try XCTUnwrap(
            desktopSurface.connectedPlayerIdentity
        )

        XCTAssertEqual(
            desktopSurface.backgroundConnectedPlayerIdentity,
            connectedPlayerIdentity
        )
        XCTAssertTrue(desktopSurface.isBackgroundVisible)
        XCTAssertEqual(desktopSurface.foregroundVideoGravity, .resizeAspect)
        XCTAssertEqual(desktopSurface.backgroundVideoGravity, .resizeAspectFill)

        desktopSurface.setContentMode(.cover)

        XCTAssertEqual(
            desktopSurface.connectedPlayerIdentity,
            connectedPlayerIdentity
        )
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(desktopSurface.isBackgroundVisible)
        XCTAssertEqual(desktopSurface.foregroundVideoGravity, .resizeAspectFill)

        desktopSurface.setContentMode(.contain)

        XCTAssertEqual(
            desktopSurface.connectedPlayerIdentity,
            connectedPlayerIdentity
        )
        XCTAssertNil(desktopSurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(desktopSurface.isBackgroundVisible)
        XCTAssertEqual(desktopSurface.foregroundVideoGravity, .resizeAspect)

        desktopSurface.setContentMode(.blurredBackground)

        XCTAssertEqual(
            desktopSurface.connectedPlayerIdentity,
            connectedPlayerIdentity
        )
        XCTAssertEqual(
            desktopSurface.backgroundConnectedPlayerIdentity,
            connectedPlayerIdentity
        )
        XCTAssertTrue(desktopSurface.isBackgroundVisible)
        XCTAssertEqual(desktopSurface.foregroundVideoGravity, .resizeAspect)
        XCTAssertEqual(desktopSurface.backgroundVideoGravity, .resizeAspectFill)
    }

    func testCompositeDesktopSurfaceKeepsOnePlayerAcrossHotPlugAndRemoval()
        async throws {
        let engine = AVFoundationPlaybackEngine()
        let desktopSurface = DesktopPlayerLayerSurfaceGroup(id: .desktop)
        let firstDisplaySurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let secondDisplaySurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        var windows = [
            makeWindow(
                for: firstDisplaySurface,
                originX: TestConfiguration.desktopWindowOriginX
            ),
            makeWindow(
                for: secondDisplaySurface,
                originX: TestConfiguration.secondDesktopWindowOriginX,
                size: TestConfiguration.squareDesktopWindowSize
            )
        ]
        defer {
            engine.stop()
            close(windows)
        }

        desktopSurface.replaceDisplaySurfaces([
            firstDisplaySurface,
            secondDisplaySurface
        ])
        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        try await engine.attach(to: desktopSurface)
        engine.pause()

        let playerIdentity = try XCTUnwrap(
            firstDisplaySurface.connectedPlayerIdentity
        )
        XCTAssertTrue(desktopSurface.isReadyForDisplay)
        XCTAssertTrue(firstDisplaySurface.isReadyForDisplay)
        XCTAssertTrue(secondDisplaySurface.isReadyForDisplay)
        XCTAssertNil(firstDisplaySurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(firstDisplaySurface.isBackgroundVisible)
        XCTAssertEqual(
            secondDisplaySurface.connectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertEqual(
            secondDisplaySurface.backgroundConnectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertTrue(secondDisplaySurface.isBackgroundVisible)

        let thirdDisplaySurface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        windows.append(
            makeWindow(
                for: thirdDisplaySurface,
                originX: TestConfiguration.thirdDesktopWindowOriginX
            )
        )
        desktopSurface.replaceDisplaySurfaces([
            firstDisplaySurface,
            secondDisplaySurface,
            thirdDisplaySurface
        ])

        try await waitUntilReady(
            thirdDisplaySurface,
            timeoutNanoseconds: TestConfiguration.hotPlugReadyTimeoutNanoseconds
        )
        XCTAssertTrue(desktopSurface.isReadyForDisplay)
        XCTAssertEqual(
            thirdDisplaySurface.connectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertNil(thirdDisplaySurface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(thirdDisplaySurface.isBackgroundVisible)

        desktopSurface.replaceDisplaySurfaces([
            secondDisplaySurface,
            thirdDisplaySurface
        ])

        XCTAssertNil(firstDisplaySurface.connectedPlayerIdentity)
        XCTAssertNil(firstDisplaySurface.backgroundConnectedPlayerIdentity)
        XCTAssertEqual(
            secondDisplaySurface.connectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertEqual(
            secondDisplaySurface.backgroundConnectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertEqual(
            thirdDisplaySurface.connectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertNil(thirdDisplaySurface.backgroundConnectedPlayerIdentity)
        XCTAssertTrue(desktopSurface.isReadyForDisplay)
    }

    func testEnergyConstraintDisablesOnlyDecorativeBlurLayer() async throws {
        let engine = AVFoundationPlaybackEngine()
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let window = makeWindow(
            for: surface,
            originX: TestConfiguration.desktopWindowOriginX,
            size: TestConfiguration.squareDesktopWindowSize
        )
        defer {
            engine.stop()
            close([window])
        }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        try await engine.attach(to: surface)
        let playerIdentity = try XCTUnwrap(surface.connectedPlayerIdentity)
        XCTAssertEqual(
            surface.backgroundConnectedPlayerIdentity,
            playerIdentity
        )

        surface.setEnergyConstrained(true)

        XCTAssertEqual(surface.connectedPlayerIdentity, playerIdentity)
        XCTAssertNil(surface.backgroundConnectedPlayerIdentity)
        XCTAssertFalse(surface.isBackgroundVisible)
        XCTAssertEqual(surface.foregroundVideoGravity, .resizeAspect)
        XCTAssertTrue(surface.isReadyForDisplay)

        surface.setEnergyConstrained(false)

        XCTAssertEqual(surface.connectedPlayerIdentity, playerIdentity)
        XCTAssertEqual(
            surface.backgroundConnectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertTrue(surface.isBackgroundVisible)
    }

    func testPlayerObservationIsRemovedOnDisconnectAndDeinit() {
        let player = AVPlayer()
        weak var releasedSurface: DesktopPlayerLayerSurfaceView?

        autoreleasepool {
            var surface: DesktopPlayerLayerSurfaceView? =
                DesktopPlayerLayerSurfaceView(
                    id: .desktop,
                    contentMode: .blurredBackground
                )
            releasedSurface = surface

            surface?.connect(to: player)
            XCTAssertTrue(surface?.isObservingPlayerItemChanges == true)

            surface?.connect(to: nil)
            XCTAssertFalse(surface?.isObservingPlayerItemChanges == true)
            XCTAssertFalse(
                surface?.isObservingPresentationSizeChanges == true
            )
            surface = nil
        }

        XCTAssertNil(releasedSurface)
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(
            fileURLWithPath: "/tmp/nonexistent.mp4"
        )))
    }

    func testBlurPolicyTracksCurrentItemReplacementWhileConnected()
        async throws {
        let player = AVPlayer()
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let window = makeWindow(
            for: surface,
            originX: TestConfiguration.desktopWindowOriginX
        )
        let bundle = Bundle(for: Self.self)
        let landscapeURL = try XCTUnwrap(
            bundle.url(
                forResource: TestConfiguration.landscapeFixtureName,
                withExtension: "mp4"
            )
        )
        let portraitURL = try XCTUnwrap(
            bundle.url(
                forResource: TestConfiguration.portraitFixtureName,
                withExtension: "mp4"
            )
        )
        defer {
            surface.connect(to: nil)
            player.replaceCurrentItem(with: nil)
            close([window])
        }

        surface.connect(to: player)
        player.replaceCurrentItem(with: AVPlayerItem(url: landscapeURL))
        try await waitForCondition("landscape blur removal") {
            guard let size = player.currentItem?.presentationSize else {
                return false
            }
            return size.width > size.height
                && !surface.isBackgroundVisible
                && surface.backgroundConnectedPlayerIdentity == nil
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: portraitURL))
        try await waitForCondition("portrait blur activation") {
            guard let size = player.currentItem?.presentationSize else {
                return false
            }
            return size.height > size.width
                && surface.isBackgroundVisible
                && surface.backgroundConnectedPlayerIdentity
                    == surface.connectedPlayerIdentity
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: landscapeURL))
        try await waitForCondition("replacement blur removal") {
            guard let size = player.currentItem?.presentationSize else {
                return false
            }
            return size.width > size.height
                && !surface.isBackgroundVisible
                && surface.backgroundConnectedPlayerIdentity == nil
        }
    }

    func testBlurBackgroundPolicyKeepsOnlyVisibleBars() {
        let wideVideo = CGSize(width: 1_920, height: 1_080)
        let wideDisplay = CGSize(width: 2_560, height: 1_440)
        let squareDisplay = CGSize(width: 1_440, height: 1_440)

        XCTAssertFalse(
            DesktopBlurBackgroundPolicy.shouldRender(
                videoSize: wideVideo,
                containerSize: wideDisplay,
                isEnergyConstrained: false
            )
        )
        XCTAssertTrue(
            DesktopBlurBackgroundPolicy.shouldRender(
                videoSize: wideVideo,
                containerSize: squareDisplay,
                isEnergyConstrained: false
            )
        )
        XCTAssertFalse(
            DesktopBlurBackgroundPolicy.shouldRender(
                videoSize: wideVideo,
                containerSize: squareDisplay,
                isEnergyConstrained: true
            )
        )
    }

    func testBlurredBackgroundRevealsExpectedBarsForLandscapeAndPortraitVideo()
        async throws {
        let landscape = try await renderedGeometry(
            fixtureName: TestConfiguration.landscapeFixtureName
        )

        XCTAssertEqual(
            landscape.videoRect.width,
            landscape.containerRect.width,
            accuracy: TestConfiguration.geometryAccuracy
        )
        XCTAssertLessThan(
            landscape.videoRect.height,
            landscape.containerRect.height
        )
        XCTAssertGreaterThan(
            landscape.videoRect.minY,
            landscape.containerRect.minY + TestConfiguration.geometryAccuracy
        )
        XCTAssertLessThan(
            landscape.videoRect.maxY,
            landscape.containerRect.maxY - TestConfiguration.geometryAccuracy
        )

        let portrait = try await renderedGeometry(
            fixtureName: TestConfiguration.portraitFixtureName
        )

        XCTAssertEqual(
            portrait.videoRect.height,
            portrait.containerRect.height,
            accuracy: TestConfiguration.geometryAccuracy
        )
        XCTAssertLessThan(
            portrait.videoRect.width,
            portrait.containerRect.width
        )
        XCTAssertGreaterThan(
            portrait.videoRect.minX,
            portrait.containerRect.minX + TestConfiguration.geometryAccuracy
        )
        XCTAssertLessThan(
            portrait.videoRect.maxX,
            portrait.containerRect.maxX - TestConfiguration.geometryAccuracy
        )
    }

    private func renderedGeometry(
        fixtureName: String
    ) async throws -> RenderedVideoGeometry {
        let engine = AVFoundationPlaybackEngine()
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: .blurredBackground
        )
        let window = makeWindow(
            for: surface,
            originX: TestConfiguration.desktopWindowOriginX,
            size: TestConfiguration.squareDesktopWindowSize
        )
        defer {
            engine.stop()
            close([window])
        }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try XCTUnwrap(
                    Bundle(for: Self.self).url(
                        forResource: fixtureName,
                        withExtension: "mp4"
                    )
                ),
                displayName: fixtureName
            )
        )
        try await engine.attach(to: surface)
        surface.layoutSubtreeIfNeeded()

        XCTAssertTrue(surface.isBackgroundVisible)
        XCTAssertTrue(surface.isReadyForDisplay)
        XCTAssertEqual(
            surface.backgroundConnectedPlayerIdentity,
            surface.connectedPlayerIdentity
        )

        return RenderedVideoGeometry(
            containerRect: surface.bounds,
            videoRect: surface.foregroundDisplayedVideoRect
        )
    }

    private func makeWindow(
        for surface: NSView,
        originX: CGFloat,
        size: NSSize = TestConfiguration.windowSize
    ) -> NSWindow {
        let frame = NSRect(
            x: originX,
            y: TestConfiguration.windowOriginY,
            width: size.width,
            height: size.height
        )
        surface.frame = NSRect(origin: .zero, size: frame.size)
        surface.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        surface.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntilReady(
        _ surface: any PlaybackRenderSurface,
        timeoutNanoseconds: UInt64
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0

        while !surface.isReadyForDisplay {
            guard elapsedNanoseconds < timeoutNanoseconds else {
                XCTFail("Timed out waiting for the hot-plugged display surface")
                return
            }
            try await Task.sleep(
                nanoseconds: TestConfiguration.hotPlugPollIntervalNanoseconds
            )
            elapsedNanoseconds += TestConfiguration.hotPlugPollIntervalNanoseconds
        }
    }

    private func waitForCondition(
        _ description: String,
        condition: () -> Bool
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0
        while !condition() {
            guard elapsedNanoseconds
                    < TestConfiguration.hotPlugReadyTimeoutNanoseconds else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(
                nanoseconds: TestConfiguration.hotPlugPollIntervalNanoseconds
            )
            elapsedNanoseconds +=
                TestConfiguration.hotPlugPollIntervalNanoseconds
        }
    }

    private func close(_ windows: [NSWindow]) {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
    }
}
