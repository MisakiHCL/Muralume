import AppKit
import Combine
@testable import Muralume

@MainActor
final class TestMainMenuCommandHandler:
    MacMainMenuCommandHandling
{
    private let stateDidChange = PassthroughSubject<Void, Never>()
    private(set) var togglePlaybackCommandCount = 0
    private(set) var enterDesktopCommandCount = 0
    private(set) var configureDesktopCommandCount = 0
    private(set) var searchMediaCommandCount = 0

    var mainMenuCommandState = MacMainMenuCommandState(
        isPlaybackRequested: false,
        isMuted: false,
        canControlPlayback: false,
        canPlayPrevious: false,
        canPlayNext: false,
        canIncreaseVolume: false,
        canDecreaseVolume: false,
        canEnterDesktop: false,
        canUseWindowActions: true,
        canEditLibrary: false
    )

    var mainMenuCommandStateDidChange: AnyPublisher<Void, Never> {
        stateDidChange.eraseToAnyPublisher()
    }

    func openSettings() {}
    func addMedia() {}
    func searchMediaFromMenu() {
        searchMediaCommandCount += 1
    }
    func editLibraryFromMenu() {}
    func togglePlaybackFromMenu() {
        togglePlaybackCommandCount += 1
    }
    func captureScreenshotFromMenu() {}
    func seekBackwardFromMenu() {}
    func seekForwardFromMenu() {}
    func playPreviousFromMenu() {}
    func playNextFromMenu() {}
    func increaseVolumeFromMenu() {}
    func decreaseVolumeFromMenu() {}
    func toggleMuteFromMenu() {}
    func enterDesktopFromMenu() {
        enterDesktopCommandCount += 1
    }
    func configureDesktopFromMenu() {
        configureDesktopCommandCount += 1
    }
    func toggleFullScreen() {}

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        false
    }
}
