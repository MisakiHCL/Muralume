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

    func testTransientMediaSwitchDoesNotRevealHiddenChrome() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        hideChrome(controller, scheduler: scheduler)

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
        XCTAssertFalse(scheduler.hasScheduledAction)
    }

    func testSkippableFailureDoesNotRevealHiddenChrome() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        hideChrome(controller, scheduler: scheduler)

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

    func testPointerActivityIsTheOnlyTransientEventThatRevealsChrome() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        hideChrome(controller, scheduler: scheduler)

        controller.recordPointerActivity()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(scheduler.hasScheduledAction)

        scheduler.fire()
        XCTAssertFalse(controller.isVisible)
    }

    func testPausedPlaybackRevealsThenAutoHidesChrome() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        hideChrome(controller, scheduler: scheduler)

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
        XCTAssertTrue(scheduler.hasScheduledAction)

        scheduler.fire()

        XCTAssertFalse(controller.isVisible)
    }

    func testFailureAndEmptyPlaybackRevealChrome() {
        let failureScheduler = ControlledPlayerChromeAutoHideScheduler()
        let failureController = makeController(scheduler: failureScheduler)
        hideChrome(failureController, scheduler: failureScheduler)

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

        let emptyScheduler = ControlledPlayerChromeAutoHideScheduler()
        let emptyController = makeController(scheduler: emptyScheduler)
        hideChrome(emptyController, scheduler: emptyScheduler)

        emptyController.updatePlaybackState(.empty)

        XCTAssertTrue(emptyController.isVisible)
    }

    func testDismissedWindowSuppressesPauseRevealUntilRestore() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        hideChrome(controller, scheduler: scheduler)

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

    func testOpeningPlaylistCancelsPendingAutoHide() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        XCTAssertTrue(scheduler.hasScheduledAction)

        controller.setPlaylistPresented(true)

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(scheduler.hasScheduledAction)
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

    func testSettingsKeepsChromeVisibleAndCancelsAutoHide() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        XCTAssertTrue(scheduler.hasScheduledAction)

        controller.setSettingsPresented(true)

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isSettingsPresented)
        XCTAssertFalse(scheduler.hasScheduledAction)
    }

    func testFullScreenAutoDismissedPlaylistIsRestoredOnExit() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        controller.updatePlaybackState(.playing)
        controller.presentLibraryEditor()

        controller.updateFullScreen(true)

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
        XCTAssertTrue(scheduler.hasScheduledAction)

        controller.updateFullScreen(false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPlaylistPresented)
        XCTAssertFalse(controller.isLibraryEditing)
        XCTAssertFalse(scheduler.hasScheduledAction)
    }

    func testFullScreenPlaylistOverrideIsNotRestoredOnExit() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
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

    func testPointerActivityResetsOneScheduleWithoutCancellingIt() {
        let scheduler = ControlledPlayerChromeAutoHideScheduler()
        let controller = makeController(scheduler: scheduler)
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        let cancellationCount = scheduler.cancellationCount

        for _ in 0..<100 {
            controller.recordPointerActivity()
        }

        XCTAssertTrue(scheduler.hasScheduledAction)
        XCTAssertEqual(scheduler.cancellationCount, cancellationCount)
        XCTAssertEqual(scheduler.maximumPendingActionCount, 1)

        scheduler.fire()

        XCTAssertFalse(controller.isVisible)
    }

    func testRunLoopSchedulerReusesTimerWhenDeadlineIsReset() {
        let scheduler = RunLoopPlayerChromeAutoHideScheduler()

        for _ in 0..<100 {
            scheduler.schedule(afterNanoseconds: NSEC_PER_SEC) {}
        }

        XCTAssertEqual(scheduler.timerCreationCountForTesting, 1)
        scheduler.cancel()
    }

    private func makeController(
        scheduler: ControlledPlayerChromeAutoHideScheduler
    ) -> PlayerChromeController {
        PlayerChromeController(
            autoHideDelayNanoseconds: 1,
            autoHideScheduler: scheduler
        )
    }

    private func hideChrome(
        _ controller: PlayerChromeController,
        scheduler: ControlledPlayerChromeAutoHideScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        controller.setPlaylistPresented(false)
        controller.updatePlaybackState(.playing)
        guard scheduler.hasScheduledAction else {
            XCTFail("Expected an auto-hide schedule", file: file, line: line)
            return
        }
        scheduler.fire()
        XCTAssertFalse(controller.isVisible, file: file, line: line)
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

@MainActor
private final class ControlledPlayerChromeAutoHideScheduler:
    PlayerChromeAutoHideScheduling {
    private var scheduledAction: (@MainActor () -> Void)?
    private(set) var cancellationCount = 0
    private(set) var maximumPendingActionCount = 0

    var hasScheduledAction: Bool {
        scheduledAction != nil
    }

    func schedule(
        afterNanoseconds _: UInt64,
        action: @escaping @MainActor () -> Void
    ) {
        scheduledAction = action
        maximumPendingActionCount = max(maximumPendingActionCount, 1)
    }

    func cancel() {
        cancellationCount += 1
        scheduledAction = nil
    }

    func fire() {
        let action = scheduledAction
        scheduledAction = nil
        action?()
    }
}
