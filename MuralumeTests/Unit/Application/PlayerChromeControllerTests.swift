import XCTest
@testable import Muralume

@MainActor
final class PlayerChromeControllerTests: XCTestCase {
    func testTransientMediaSwitchDoesNotRevealHiddenChrome() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        await hideChrome(controller, sleeper: sleeper)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .loading,
                isActuallyPlaying: true,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )
        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .loading,
                isActuallyPlaying: false,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )
        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .ready,
                isActuallyPlaying: false,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )
        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(.playing)
        XCTAssertFalse(controller.isVisible)
        let pendingSleepCount = await sleeper.pendingCount
        XCTAssertEqual(pendingSleepCount, 0)
    }

    func testSkippableFailureDoesNotRevealHiddenChrome() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        await hideChrome(controller, sleeper: sleeper)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .failed(.cannotOpen),
                isActuallyPlaying: false,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )
        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .loading,
                isActuallyPlaying: false,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )
        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(.playing)
        XCTAssertFalse(controller.isVisible)
    }

    func testPointerActivityIsTheOnlyTransientEventThatRevealsChrome() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        await hideChrome(controller, sleeper: sleeper)

        controller.recordPointerActivity()

        XCTAssertTrue(controller.isVisible)
        await waitForPendingSleep(in: sleeper)

        await sleeper.resumeNext()
        await waitUntil {
            !controller.isVisible
        }
    }

    func testPausedPlaybackRevealsChrome() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        await hideChrome(controller, sleeper: sleeper)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .ready,
                isActuallyPlaying: false,
                isPlaybackRequested: false,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )

        XCTAssertTrue(controller.isVisible)
        let pendingSleepCount = await sleeper.pendingCount
        XCTAssertEqual(pendingSleepCount, 0)
    }

    func testFailureAndEmptyPlaybackRevealChrome() async {
        let failureSleeper = ControlledPlayerChromeSleeper()
        let failureController = makeController(sleeper: failureSleeper)
        await hideChrome(failureController, sleeper: failureSleeper)

        failureController.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .failed(.cannotOpen),
                isActuallyPlaying: false,
                isPlaybackRequested: true,
                hasPlayableMedia: false,
                isPlayerWindowDismissed: false
            )
        )

        XCTAssertTrue(failureController.isVisible)

        let emptySleeper = ControlledPlayerChromeSleeper()
        let emptyController = makeController(sleeper: emptySleeper)
        await hideChrome(emptyController, sleeper: emptySleeper)

        emptyController.updatePlaybackState(.empty)

        XCTAssertTrue(emptyController.isVisible)
    }

    func testDismissedWindowSuppressesPauseRevealUntilRestore() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        await hideChrome(controller, sleeper: sleeper)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .ready,
                isActuallyPlaying: true,
                isPlaybackRequested: true,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: true
            )
        )
        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .ready,
                isActuallyPlaying: false,
                isPlaybackRequested: false,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: true
            )
        )

        XCTAssertFalse(controller.isVisible)

        controller.updatePlaybackState(
            PlayerChromePlaybackState(
                readiness: .ready,
                isActuallyPlaying: false,
                isPlaybackRequested: false,
                hasPlayableMedia: true,
                isPlayerWindowDismissed: false
            )
        )

        XCTAssertTrue(controller.isVisible)
    }

    func testOpeningPlaylistCancelsPendingAutoHide() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        await waitForPendingSleep(in: sleeper)

        controller.setPlaylistPresented(true)
        await sleeper.resumeAll()
        await yieldSeveralTimes()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
    }

    func testFullScreenAutoDismissedPlaylistIsRestoredOnExit() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        controller.updatePlaybackState(.playing)

        controller.updateFullScreen(true)

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isPlaylistPresented)
        await waitForPendingSleep(in: sleeper)

        controller.updateFullScreen(false)
        await sleeper.resumeAll()
        await yieldSeveralTimes()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
    }

    func testFullScreenPlaylistOverrideIsNotRestoredOnExit() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        controller.updatePlaybackState(.playing)
        controller.updateFullScreen(true)
        XCTAssertFalse(controller.isPlaylistPresented)

        controller.setPlaylistPresented(true)
        controller.setPlaylistPresented(false)
        controller.updateFullScreen(false)

        XCTAssertFalse(controller.isPlaylistPresented)
    }

    private func makeController(
        sleeper: ControlledPlayerChromeSleeper
    ) -> PlayerChromeController {
        PlayerChromeController(
            autoHideDelayNanoseconds: 1,
            sleep: { _ in
                try await sleeper.sleep()
            }
        )
    }

    private func hideChrome(
        _ controller: PlayerChromeController,
        sleeper: ControlledPlayerChromeSleeper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        await waitForPendingSleep(in: sleeper, file: file, line: line)
        await sleeper.resumeNext()
        await waitUntil(file: file, line: line) {
            !controller.isVisible
        }
    }

    private func waitForPendingSleep(
        in sleeper: ControlledPlayerChromeSleeper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await sleeper.pendingCount > 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected an auto-hide sleep task", file: file, line: line)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func yieldSeveralTimes() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private extension PlayerChromePlaybackState {
    static let playing = PlayerChromePlaybackState(
        readiness: .ready,
        isActuallyPlaying: true,
        isPlaybackRequested: true,
        hasPlayableMedia: true,
        isPlayerWindowDismissed: false
    )
}

private actor ControlledPlayerChromeSleeper {
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        pendingContinuations.count
    }

    func sleep() async throws {
        await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        guard !pendingContinuations.isEmpty else {
            return
        }
        pendingContinuations.removeFirst().resume()
    }

    func resumeAll() {
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
