import XCTest
@testable import Muralume

final class PlaybackGateTests: XCTestCase {
    func testAllSuspensionReasonsMustClearBeforePlaybackCanResume() {
        var gate = PlaybackGate()
        gate.setIntent(.playing)
        gate.setSuspended(true, for: .screenLocked)
        gate.setSuspended(true, for: .displaySleeping)

        XCTAssertFalse(gate.shouldPlay)

        gate.setSuspended(false, for: .screenLocked)
        XCTAssertFalse(gate.shouldPlay)

        gate.setSuspended(false, for: .displaySleeping)
        XCTAssertTrue(gate.shouldPlay)
    }

    func testUserPauseSurvivesSystemResume() {
        var gate = PlaybackGate()
        gate.setIntent(.playing)
        gate.setSuspended(true, for: .systemSleeping)
        gate.setIntent(.paused)
        gate.setSuspended(false, for: .systemSleeping)

        XCTAssertFalse(gate.shouldPlay)
        XCTAssertEqual(gate.intent, .paused)
    }

    func testTerminationIsIrreversible() {
        var gate = PlaybackGate()
        gate.setIntent(.playing)
        gate.terminate()
        gate.setIntent(.playing)
        gate.setSuspended(false, for: .screenLocked)

        XCTAssertFalse(gate.shouldPlay)
        XCTAssertTrue(gate.isTerminating)
    }
}
