import AppKit
import XCTest
@testable import Muralume

@MainActor
final class MuralumeSliderTests: XCTestCase {
    func testTrackGeometryUsesFixedSize() {
        let bounds = NSRect(x: 0, y: 0, width: 240, height: 28)

        let track = MuralumeSliderGeometry.trackRect(in: bounds)

        XCTAssertEqual(track.midY, bounds.midY)
        XCTAssertEqual(track.width, 220)
        XCTAssertEqual(
            track.height,
            MuralumeTheme.Size.sliderTrackHeight
        )
    }

    func testOnlyThumbDiameterChangesDuringInteraction() {
        let knobRect = NSRect(x: 100, y: 4, width: 20, height: 20)

        let idleThumb = MuralumeSliderGeometry.thumbRect(
            in: knobRect,
            isInteracting: false
        )
        let activeThumb = MuralumeSliderGeometry.thumbRect(
            in: knobRect,
            isInteracting: true
        )

        XCTAssertEqual(idleThumb.midX, activeThumb.midX)
        XCTAssertEqual(idleThumb.midY, activeThumb.midY)
        XCTAssertEqual(
            idleThumb.width,
            MuralumeTheme.Size.sliderThumbDiameter
        )
        XCTAssertEqual(
            activeThumb.width,
            MuralumeTheme.Size.sliderActiveThumbDiameter
        )
    }
}
