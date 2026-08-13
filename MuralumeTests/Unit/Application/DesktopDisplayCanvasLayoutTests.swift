import CoreGraphics
import XCTest
@testable import Muralume

final class DesktopDisplayCanvasLayoutTests: XCTestCase {
    func testPositionsScaleAndCenterDisplayArrangementToFitCanvas() {
        let displays = [
            makeDisplay(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            makeDisplay(
                id: "right",
                frame: CGRect(x: 100, y: 0, width: 100, height: 100)
            )
        ]

        let positions = DesktopDisplayCanvasLayout.positions(
            for: displays,
            in: CGSize(width: 240, height: 160),
            padding: 20
        )

        XCTAssertEqual(positions.count, 2)
        assertRect(
            positions[0].frame,
            equals: CGRect(x: 20, y: 30, width: 100, height: 100)
        )
        assertRect(
            positions[1].frame,
            equals: CGRect(x: 120, y: 30, width: 100, height: 100)
        )
    }

    func testPositionsUseAspectFitScaleForUltrawideDisplay() {
        let display = makeDisplay(
            id: "ultrawide",
            frame: CGRect(x: 0, y: 0, width: 3_840, height: 1_080)
        )

        let positions = DesktopDisplayCanvasLayout.positions(
            for: [display],
            in: CGSize(width: 200, height: 200),
            padding: 20
        )

        XCTAssertEqual(positions.count, 1)
        assertRect(
            positions[0].frame,
            equals: CGRect(x: 20, y: 77.5, width: 160, height: 45)
        )
    }

    func testPositionsFlipAppKitVerticalAxisForSwiftUICanvas() {
        let lower = makeDisplay(
            id: "lower",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let upper = makeDisplay(
            id: "upper",
            frame: CGRect(x: 0, y: 100, width: 100, height: 100)
        )

        let positions = DesktopDisplayCanvasLayout.positions(
            for: [lower, upper],
            in: CGSize(width: 140, height: 240),
            padding: 20
        )

        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0].id, lower.id)
        XCTAssertEqual(positions[1].id, upper.id)
        XCTAssertEqual(positions[0].frame.minY, 120, accuracy: 0.000_1)
        XCTAssertEqual(positions[1].frame.minY, 20, accuracy: 0.000_1)
    }

    func testPositionsPreserveInputOrderForDisplayNumbersAndSpatialOffsets() {
        let right = makeDisplay(
            id: "right",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let left = makeDisplay(
            id: "left",
            frame: CGRect(x: -100, y: 0, width: 100, height: 100)
        )

        let positions = DesktopDisplayCanvasLayout.positions(
            for: [right, left],
            in: CGSize(width: 240, height: 140),
            padding: 20
        )

        XCTAssertEqual(positions.map(\.id), [right.id, left.id])
        XCTAssertEqual(positions.map(\.number), [1, 2])
        XCTAssertGreaterThan(
            positions[0].frame.minX,
            positions[1].frame.minX
        )
    }

    func testPositionsReturnEmptyWhenCanvasCannotContainPadding() {
        let display = makeDisplay(
            id: "main",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertTrue(
            DesktopDisplayCanvasLayout.positions(
                for: [display],
                in: CGSize(width: 40, height: 40),
                padding: 20
            ).isEmpty
        )
        XCTAssertTrue(
            DesktopDisplayCanvasLayout.positions(
                for: [],
                in: CGSize(width: 200, height: 200),
                padding: 20
            ).isEmpty
        )
    }

    private func makeDisplay(
        id: String,
        frame: CGRect
    ) -> DesktopDisplayDescriptor {
        DesktopDisplayDescriptor(
            id: DesktopDisplayID(rawValue: id),
            runtimeID: DesktopRuntimeDisplayID(
                rawValue: UInt32(id.utf8.count)
            ),
            localizedName: id,
            frame: frame,
            isMain: id == "main",
            isBuiltIn: id == "main"
        )
    }

    private func assertRect(
        _ actual: CGRect,
        equals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.minX,
            expected.minX,
            accuracy: 0.000_1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.minY,
            expected.minY,
            accuracy: 0.000_1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.width,
            expected.width,
            accuracy: 0.000_1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.height,
            expected.height,
            accuracy: 0.000_1,
            file: file,
            line: line
        )
    }
}
