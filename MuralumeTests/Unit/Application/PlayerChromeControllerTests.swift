import AppKit
import XCTest
@testable import Muralume

@MainActor
final class PlayerChromeControllerTests: XCTestCase {
    func testFullScreenIconDifferentiatesEnterAndExitStates() {
        XCTAssertEqual(
            PlayerFullScreenIcon.systemName(isFullScreen: false),
            PlayerFullScreenIcon.enterSystemName
        )
        XCTAssertEqual(
            PlayerFullScreenIcon.systemName(isFullScreen: true),
            PlayerFullScreenIcon.exitSystemName
        )
        XCTAssertNotEqual(
            PlayerFullScreenIcon.enterSystemName,
            PlayerFullScreenIcon.exitSystemName
        )
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: PlayerFullScreenIcon.enterSystemName,
                accessibilityDescription: nil
            )
        )
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: PlayerFullScreenIcon.exitSystemName,
                accessibilityDescription: nil
            )
        )
    }

    func testLibraryEditorPresentsPlaylistAndDoneReturnsToBrowsing() {
        let controller = PlayerChromeController()
        controller.setPlaylistPresented(false)

        controller.presentLibraryEditor()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertTrue(controller.isLibraryEditing)
        XCTAssertEqual(controller.libraryQueueMode, .editing)

        controller.setLibraryEditing(false)

        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
        XCTAssertEqual(controller.libraryQueueMode, .browsing)
    }

    func testLibraryEditingResetsWhenPanelIsClosedOrReplaced() {
        let controller = PlayerChromeController()

        controller.presentLibraryEditor()
        controller.setPlaylistPresented(false)

        XCTAssertNil(controller.presentedPanel)
        XCTAssertFalse(controller.isLibraryEditing)

        controller.presentLibraryEditor()
        controller.setSettingsPresented(true)

        XCTAssertTrue(controller.isSettingsPresented)
        XCTAssertFalse(controller.isLibraryEditing)

        controller.setSettingsPresented(false)

        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
    }

    func testSelectingPlayQueueExitsLibraryEditingAndRequestsFocus() {
        let controller = PlayerChromeController()
        controller.presentLibraryEditor()
        let initialFocusRequest = controller.playbackQueueFocusRequest

        controller.selectLibrarySidebarSection(.playQueue)

        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
        XCTAssertEqual(controller.librarySidebarSection, .playQueue)
        XCTAssertEqual(
            controller.playbackQueueFocusRequest,
            initialFocusRequest &+ 1
        )
    }

    func testSelectingPlayQueuePreservesHiddenPanelAndRefocusesOnRepeat() {
        let controller = PlayerChromeController()
        controller.setPlaylistPresented(false)

        controller.selectLibrarySidebarSection(.playQueue)
        let firstFocusRequest = controller.playbackQueueFocusRequest
        controller.selectLibrarySidebarSection(.playQueue)

        XCTAssertFalse(controller.isPlaylistPresented)
        XCTAssertEqual(controller.librarySidebarSection, .playQueue)
        XCTAssertEqual(
            controller.playbackQueueFocusRequest,
            firstFocusRequest &+ 1
        )
    }

    func testPresentingLibraryEditorSelectsMediaLibrary() {
        let controller = PlayerChromeController()
        controller.selectLibrarySidebarSection(.playQueue)

        controller.presentLibraryEditor()

        XCTAssertEqual(controller.librarySidebarSection, .mediaLibrary)
        XCTAssertTrue(controller.isLibraryEditing)
    }

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

    func testSettingsReplacesPlaylistAndRestoresItWhenClosed() {
        let controller = PlayerChromeController()

        XCTAssertEqual(controller.presentedPanel, .playlist)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isSettingsPresented)

        controller.toggleSettings()

        XCTAssertEqual(controller.presentedPanel, .settings)
        XCTAssertFalse(controller.isPlaylistPresented)
        XCTAssertTrue(controller.isSettingsPresented)

        controller.toggleSettings()

        XCTAssertEqual(controller.presentedPanel, .playlist)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isSettingsPresented)
    }

    func testDismissPresentedPanelFollowsEscapePriority() {
        let controller = PlayerChromeController()

        controller.setSettingsPresented(true)

        XCTAssertTrue(controller.dismissPresentedPanel())
        XCTAssertEqual(controller.presentedPanel, .playlist)

        XCTAssertTrue(controller.dismissPresentedPanel())
        XCTAssertNil(controller.presentedPanel)
        XCTAssertFalse(controller.dismissPresentedPanel())

        controller.setSettingsPresented(true)

        XCTAssertTrue(controller.dismissPresentedPanel())
        XCTAssertNil(controller.presentedPanel)
    }

    func testSettingsKeepsChromeVisibleAndCancelsAutoHide() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        await waitForPendingSleep(in: sleeper)

        controller.setSettingsPresented(true)
        await sleeper.resumeAll()
        await yieldSeveralTimes()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isSettingsPresented)
        let pendingSleepCount = await sleeper.pendingCount
        XCTAssertEqual(pendingSleepCount, 0)
    }

    func testFullScreenAutoDismissedPlaylistIsRestoredOnExit() async {
        let sleeper = ControlledPlayerChromeSleeper()
        let controller = makeController(sleeper: sleeper)
        controller.updatePlaybackState(.playing)
        controller.presentLibraryEditor()

        controller.updateFullScreen(true)

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
        await waitForPendingSleep(in: sleeper)

        controller.updateFullScreen(false)
        await sleeper.resumeAll()
        await yieldSeveralTimes()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
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

    func testSettingsStaysPresentedInFullScreenAndDefersPlaylistRestore() {
        let controller = PlayerChromeController()
        controller.updatePlaybackState(.playing)
        controller.setSettingsPresented(true)

        controller.updateFullScreen(true)

        XCTAssertEqual(controller.presentedPanel, .settings)
        XCTAssertTrue(controller.isSettingsPresented)
        XCTAssertFalse(controller.isPlaylistPresented)

        controller.setSettingsPresented(false)

        XCTAssertNil(controller.presentedPanel)
        XCTAssertFalse(controller.isSettingsPresented)
        XCTAssertFalse(controller.isPlaylistPresented)

        controller.updateFullScreen(false)

        XCTAssertEqual(controller.presentedPanel, .playlist)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isSettingsPresented)
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
