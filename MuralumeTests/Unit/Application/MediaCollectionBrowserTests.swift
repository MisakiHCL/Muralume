import CoreGraphics
import XCTest
@testable import Muralume

@MainActor
final class MediaCollectionBrowserTests: XCTestCase {
    func testSharedGridUsesSquareFourPointTilesAcrossSidebarWidths() {
        for width: CGFloat in [20, 96, 200, 304, 320, 513, 800] {
            let size = MediaBrowserGridMetrics.itemSize(
                availableWidth: width, accessibilitySize: false
            )
            XCTAssertEqual(size.width, size.height)
            XCTAssertGreaterThanOrEqual(size.width, 4)
            XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 4), 0)
            XCTAssertLessThanOrEqual(size.width, width - MuralumeTheme.Size.libraryGridScrollerAllowance)
        }
    }

    func testAccessibilityGridKeepsOneLargeArtworkColumn() {
        for width: CGFloat in [200, 304, 513] {
            let size = MediaBrowserGridMetrics.itemSize(
                availableWidth: width, accessibilitySize: true
            )
            let available = width - MuralumeTheme.Size.libraryGridScrollerAllowance
            XCTAssertEqual(size.width, size.height)
            XCTAssertLessThanOrEqual(size.width, available)
            XCTAssertLessThan(available - size.width, 4)
        }
    }

    func testInitialOrInvalidGeometryStillGivesHostingViewsANonzeroTile() {
        for width: CGFloat in [0, -1, .infinity, .nan] {
            XCTAssertEqual(
                MediaBrowserGridMetrics.itemSize(availableWidth: width, accessibilitySize: false),
                CGSize(width: 4, height: 4)
            )
        }
    }
}
