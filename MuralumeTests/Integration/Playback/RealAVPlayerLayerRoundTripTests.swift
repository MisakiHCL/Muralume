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
        static let renderingSettleNanoseconds: UInt64 = 300_000_000
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
        let desktopPlayerIdentity = try XCTUnwrap(
            desktopSurface.connectedPlayerIdentity
        )
        XCTAssertEqual(
            desktopSurface.backgroundConnectedPlayerIdentity,
            desktopPlayerIdentity
        )
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
        let desktopPlayerIdentity = try XCTUnwrap(
            desktopSurface.connectedPlayerIdentity
        )
        XCTAssertEqual(
            desktopSurface.backgroundConnectedPlayerIdentity,
            desktopPlayerIdentity
        )
        XCTAssertTrue(desktopSurface.isBackgroundVisible)
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
            originX: TestConfiguration.desktopWindowOriginX
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

    private func close(_ windows: [NSWindow]) {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
    }
}
