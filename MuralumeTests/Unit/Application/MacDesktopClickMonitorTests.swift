import AppKit
import XCTest
@testable import Muralume

@MainActor
final class MacDesktopClickMonitorTests: XCTestCase {
    private let start = NSPoint(x: -80, y: 250)
    private let windowID: CGWindowID = 123

    func testOnlyEffectsWithUnpressedMotionSubscribeToMouseMoved() {
        XCTAssertTrue(DesktopInteractionEffect.off.mouseEventMask.isEmpty)
        for effect in [DesktopInteractionEffect.waterRipple, .hoverLens, .shadowLight] {
            XCTAssertTrue(effect.mouseEventMask.contains(.mouseMoved))
        }
        for effect in [DesktopInteractionEffect.colorFocus, .localFreeze] {
            XCTAssertFalse(effect.mouseEventMask.contains(.mouseMoved))
            XCTAssertTrue(effect.mouseEventMask.contains([.leftMouseDown, .leftMouseDragged, .leftMouseUp]))
        }
    }

    func testSmallMovementOnTheSameWindowIsAClickAndCanOnlyFinishOnce() {
        var gesture = DesktopClickGesture()
        gesture.begin(at: start, windowID: windowID, time: 1)
        let end = NSPoint(x: -78, y: 252)
        gesture.drag(to: end)

        XCTAssertEqual(gesture.finish(at: end, windowID: windowID, time: 1.2), windowID)
        XCTAssertNil(gesture.finish(at: end, windowID: windowID, time: 1.3))
    }

    func testDraggingOutAndBackDoesNotProduceAClick() {
        var gesture = DesktopClickGesture()
        gesture.begin(at: start, windowID: windowID, time: 1)
        gesture.drag(to: NSPoint(x: -65, y: 250))
        gesture.drag(to: start)

        XCTAssertNil(gesture.finish(at: start, windowID: windowID, time: 1.3))
    }

    func testDistantReleaseIsRejectedEvenWithoutAnIntermediateDragEvent() {
        var gesture = DesktopClickGesture()
        gesture.begin(at: start, windowID: windowID, time: 1)

        XCTAssertNil(gesture.finish(at: NSPoint(x: 10, y: 250), windowID: windowID, time: 1.1))
    }

    func testLostTargetChangedTargetAndLongPressAreRejected() {
        var gesture = DesktopClickGesture()
        gesture.begin(at: start, windowID: nil, time: 1)
        XCTAssertFalse(gesture.isTracking)
        gesture.begin(at: start, windowID: windowID, time: 2)
        XCTAssertNil(gesture.finish(at: start, windowID: nil, time: 2.1))
        gesture.begin(at: start, windowID: windowID, time: 3)
        XCTAssertNil(gesture.finish(at: start, windowID: windowID + 1, time: 3.1))
        gesture.begin(at: start, windowID: windowID, time: 4)
        XCTAssertNil(gesture.finish(at: start, windowID: windowID, time: 6))
    }

    func testCancelDropsAnUnfinishedPress() {
        var gesture = DesktopClickGesture()
        gesture.begin(at: start, windowID: windowID, time: 1)
        gesture.cancel()

        XCTAssertNil(gesture.finish(at: start, windowID: windowID, time: 1.2))
    }

    func testDesktopMarqueeReturnsScreenRectangleOnceInEveryDragDirection() {
        let ends = [NSPoint(x: -130, y: 304), NSPoint(x: -130, y: 196),
                    NSPoint(x: -30, y: 304), NSPoint(x: -30, y: 196)]
        var gesture = DesktopMarqueeGesture()
        for end in ends {
            gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 3)
            gesture.drag(overFileDragImage: false)
            let result = gesture.finish(at: end, window: windowID, dragChangeCount: 3)
            XCTAssertEqual(result, CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: 50, height: 54))
            XCTAssertNil(gesture.finish(at: end, window: windowID, dragChangeCount: 3))
        }
    }

    func testDesktopMarqueeExcludesFinderDragSessionsIncludingDeskToDeskDrops() {
        let end = NSPoint(x: -30, y: 304)
        var gesture = DesktopMarqueeGesture()
        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 3)
        gesture.drag(overFileDragImage: false)
        XCTAssertNil(gesture.finish(at: end, window: windowID, dragChangeCount: 4))

        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 4)
        gesture.drag(overFileDragImage: true)
        gesture.drag(overFileDragImage: false)
        XCTAssertNil(gesture.finish(at: end, window: windowID, dragChangeCount: 4))
    }

    func testDesktopMarqueeRejectsClickLineOutsideAndCancelledGestures() {
        let end = NSPoint(x: -30, y: 304)
        var gesture = DesktopMarqueeGesture()
        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 0)
        XCTAssertNil(gesture.finish(at: end, window: windowID, dragChangeCount: 0))
        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 0)
        gesture.drag(overFileDragImage: false)
        XCTAssertNil(gesture.finish(at: NSPoint(x: -79, y: 304), window: windowID, dragChangeCount: 0))
        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 0)
        gesture.drag(overFileDragImage: false)
        XCTAssertNil(gesture.finish(at: end, window: windowID + 1, dragChangeCount: 0))
        gesture.begin(at: start, desktopWindow: windowID, dragChangeCount: 0)
        gesture.drag(overFileDragImage: false)
        gesture.cancel()
        XCTAssertNil(gesture.finish(at: end, window: windowID, dragChangeCount: 0))
    }

    func testOnlyWallpaperAndDesktopIconLevelsAreEligible() {
        XCTAssertTrue(MacDesktopClickMonitor.isDesktopLayer(CGWindowLevelForKey(.desktopWindow)))
        XCTAssertTrue(MacDesktopClickMonitor.isDesktopLayer(CGWindowLevelForKey(.desktopIconWindow)))
        for excluded: CGWindowLevelKey in [.normalWindow, .floatingWindow, .dockWindow, .mainMenuWindow] {
            XCTAssertFalse(MacDesktopClickMonitor.isDesktopLayer(CGWindowLevelForKey(excluded)))
        }
    }

    func testPointerSamplesReuseHitClassificationUntilTheWindowChanges() {
        var sampler = DesktopPointerSampler()
        var inspected: [CGWindowID] = []
        let desktop: CGWindowID = 23
        let foreground: CGWindowID = 31
        func classify(_ id: CGWindowID) -> Bool {
            inspected.append(id)
            return desktop == id
        }

        XCTAssertEqual(sampler.desktopHit(at: 1, hitWindow: { foreground }, isDesktopWindow: classify), false)
        XCTAssertEqual(sampler.desktopHit(at: 1.05, hitWindow: { desktop }, isDesktopWindow: classify), true)
        XCTAssertEqual(sampler.desktopHit(at: 1.10, hitWindow: { desktop }, isDesktopWindow: classify), true)
        XCTAssertEqual(sampler.desktopHit(at: 1.15, hitWindow: { foreground }, isDesktopWindow: classify), false)
        XCTAssertEqual(inspected, [foreground, desktop, foreground])
    }

    func testPointerThrottleSkipsHitQueriesAndRechecksStaleClassifications() {
        var sampler = DesktopPointerSampler()
        let window: CGWindowID = 23
        XCTAssertEqual(sampler.desktopHit(at: 1, hitWindow: { window }, isDesktopWindow: { _ in true }), true)
        XCTAssertNil(sampler.desktopHit(at: 1.001, hitWindow: {
            XCTFail("Throttled motion requested a window hit")
            return window
        }, isDesktopWindow: { _ in true }))
        XCTAssertEqual(sampler.desktopHit(at: 1.6, hitWindow: { window }, isDesktopWindow: { _ in false }), false)
        XCTAssertEqual(sampler.desktopHit(at: 1.65, hitWindow: { nil }, isDesktopWindow: { _ in true }), false)
        XCTAssertEqual(sampler.desktopHit(at: 1.70, hitWindow: { window }, isDesktopWindow: { _ in true }), true)
    }

    func testLensDetectsFinalMovementOffDesktopInsideThrottleInterval() {
        var sampler = DesktopPointerSampler()
        XCTAssertEqual(sampler.desktopHit(at: 1, throttle: false, hitWindow: { 21 }, isDesktopWindow: { _ in true }), true)
        XCTAssertEqual(sampler.desktopHit(at: 1.001, throttle: false, hitWindow: { 22 }, isDesktopWindow: { _ in false }), false)
    }
}
