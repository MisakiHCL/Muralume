import AVFoundation
import AppKit
import XCTest
@testable import Muralume

@MainActor
final class RealAVPlayerLayerRoundTripTests: XCTestCase {
    private enum TestConfiguration {
        static let windowSize = NSSize(width: 320, height: 180)
        static let windowOriginY: CGFloat = 120
        static let playerWindowOriginX: CGFloat = 80
        static let desktopWindowOriginX: CGFloat = 440
        static let renderingSettleNanoseconds: UInt64 = 300_000_000
    }

    func testEngineWithoutHandlersCanRoundTripBetweenRealPlayerLayers() async throws {
        let engine = AVFoundationPlaybackEngine()
        let playerSurface = PlayerLayerSurfaceView(
            id: .player,
            videoGravity: .resizeAspect
        )
        let desktopSurface = PlayerLayerSurfaceView(
            id: .desktop,
            videoGravity: .resizeAspectFill
        )
        let windows = [
            makeWindow(
                for: playerSurface,
                originX: TestConfiguration.playerWindowOriginX
            ),
            makeWindow(
                for: desktopSurface,
                originX: TestConfiguration.desktopWindowOriginX
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
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )
        try await engine.attach(to: playerSurface)

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
        let desktopSurface = PlayerLayerSurfaceView(
            id: .desktop,
            videoGravity: .resizeAspectFill
        )
        let windows = [
            makeWindow(
                for: playerSurface,
                originX: TestConfiguration.playerWindowOriginX
            ),
            makeWindow(
                for: desktopSurface,
                originX: TestConfiguration.desktopWindowOriginX
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
        try await Task.sleep(
            nanoseconds: TestConfiguration.renderingSettleNanoseconds
        )

        try await coordinator.transitionToPlayer()
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertNotNil(playerSurface.connectedPlayerIdentity)
        XCTAssertNil(desktopSurface.connectedPlayerIdentity)
        XCTAssertTrue(playerSurface.isReadyForDisplay)
        XCTAssertFalse(playerSurface.displayedVideoRect.isEmpty)
    }

    func testDesktopContentModeChangesWithoutReattachingThePlayer() async throws {
        let engine = AVFoundationPlaybackEngine()
        let desktopSurface = PlayerLayerSurfaceView(
            id: .desktop,
            videoGravity: DesktopVideoContentMode.cover.videoGravity
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

        XCTAssertEqual(desktopSurface.videoGravity, .resizeAspectFill)

        desktopSurface.setVideoGravity(
            DesktopVideoContentMode.contain.videoGravity
        )

        XCTAssertEqual(desktopSurface.videoGravity, .resizeAspect)
        XCTAssertEqual(
            desktopSurface.connectedPlayerIdentity,
            connectedPlayerIdentity
        )
    }

    private func makeWindow(
        for surface: PlayerLayerSurfaceView,
        originX: CGFloat
    ) -> NSWindow {
        let frame = NSRect(
            x: originX,
            y: TestConfiguration.windowOriginY,
            width: TestConfiguration.windowSize.width,
            height: TestConfiguration.windowSize.height
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
        return window
    }

    private func close(_ windows: [NSWindow]) {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
    }
}
