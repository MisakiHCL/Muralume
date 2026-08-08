import Combine
import Foundation

struct PlayerChromePlaybackState: Equatable {
    let readiness: PlaybackReadiness
    let isActuallyPlaying: Bool
    let isPlaybackRequested: Bool
    let hasPlayableMedia: Bool
    let isPlayerWindowDismissed: Bool

    static let empty = PlayerChromePlaybackState(
        readiness: .empty,
        isActuallyPlaying: false,
        isPlaybackRequested: false,
        hasPlayableMedia: false,
        isPlayerWindowDismissed: false
    )
}

enum PlayerSidePanel: Equatable {
    case playlist
    case settings
}

enum LibraryQueueMode: Equatable {
    case browsing
    case editing
}

@MainActor
final class PlayerChromeController: ObservableObject {
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    @Published private(set) var isVisible = true
    @Published private(set) var presentedPanel: PlayerSidePanel? = .playlist
    @Published private(set) var libraryQueueMode: LibraryQueueMode = .browsing

    var isPlaylistPresented: Bool {
        presentedPanel == .playlist
    }

    var isSettingsPresented: Bool {
        presentedPanel == .settings
    }

    var isLibraryEditing: Bool {
        libraryQueueMode == .editing
    }

    private let autoHideDelayNanoseconds: UInt64
    private let sleep: Sleep

    private var playbackState = PlayerChromePlaybackState.empty
    private var isFullScreen = false
    private var restoresPlaylistAfterFullScreen = false
    private var restoresPlaylistAfterSettings = false
    private var autoHideTask: Task<Void, Never>?

    init(
        autoHideDelayNanoseconds: UInt64 = MuralumeTheme.Motion
            .playerChromeAutoHideNanoseconds,
        sleep: @escaping Sleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.autoHideDelayNanoseconds = autoHideDelayNanoseconds
        self.sleep = sleep
    }

    deinit {
        autoHideTask?.cancel()
    }

    func recordPointerActivity() {
        setVisible(true)
        refreshAutoHideTask()
    }

    func setPlaylistPresented(_ isPresented: Bool) {
        guard isPresented || isPlaylistPresented else {
            return
        }

        let wasPlaylistPresented = isPlaylistPresented
        restoresPlaylistAfterFullScreen = false
        restoresPlaylistAfterSettings = false
        setVisible(true)
        presentedPanel = isPresented ? .playlist : nil
        if !isPresented || !wasPlaylistPresented {
            libraryQueueMode = .browsing
        }
        refreshAutoHideTask()
    }

    func togglePlaylist() {
        setPlaylistPresented(!isPlaylistPresented)
    }

    func presentLibraryEditor() {
        restoresPlaylistAfterFullScreen = false
        restoresPlaylistAfterSettings = false
        setVisible(true)
        presentedPanel = .playlist
        libraryQueueMode = .editing
        refreshAutoHideTask()
    }

    func setLibraryEditing(_ isEditing: Bool) {
        guard isPlaylistPresented else {
            return
        }
        let mode: LibraryQueueMode = isEditing ? .editing : .browsing
        guard libraryQueueMode != mode else {
            return
        }
        libraryQueueMode = mode
        setVisible(true)
        refreshAutoHideTask()
    }

    func setSettingsPresented(_ isPresented: Bool) {
        if isPresented {
            guard !isSettingsPresented else {
                return
            }
            restoresPlaylistAfterSettings = isPlaylistPresented
            setVisible(true)
            libraryQueueMode = .browsing
            presentedPanel = .settings
            refreshAutoHideTask()
            return
        }

        guard isSettingsPresented else {
            return
        }

        presentedPanel = nil
        restorePlaylistAfterSettingsIfNeeded()
        refreshAutoHideTask()
    }

    func toggleSettings() {
        setSettingsPresented(!isSettingsPresented)
    }

    @discardableResult
    func dismissPresentedPanel() -> Bool {
        switch presentedPanel {
        case .settings:
            setSettingsPresented(false)
        case .playlist:
            setPlaylistPresented(false)
        case nil:
            return false
        }
        return true
    }

    func updatePlaybackState(_ state: PlayerChromePlaybackState) {
        guard playbackState != state else {
            return
        }

        playbackState = state
        if state.shouldRevealChrome {
            setVisible(true)
        }
        applyFullScreenPlaylistPolicy()
        refreshAutoHideTask()
    }

    func updateFullScreen(_ isFullScreen: Bool) {
        guard self.isFullScreen != isFullScreen else {
            return
        }

        self.isFullScreen = isFullScreen
        setVisible(true)

        if isFullScreen {
            applyFullScreenPlaylistPolicy()
        } else {
            if restoresPlaylistAfterFullScreen,
               presentedPanel == nil {
                presentedPanel = .playlist
                restoresPlaylistAfterFullScreen = false
            }
        }

        refreshAutoHideTask()
    }

    private func applyFullScreenPlaylistPolicy() {
        guard isFullScreen,
              playbackState.canAutoDismissPlaylist,
              isPlaylistPresented else {
            return
        }

        restoresPlaylistAfterFullScreen = true
        libraryQueueMode = .browsing
        presentedPanel = nil
    }

    private func restorePlaylistAfterSettingsIfNeeded() {
        let shouldRestorePlaylist =
            restoresPlaylistAfterSettings
            || (!isFullScreen && restoresPlaylistAfterFullScreen)
        restoresPlaylistAfterSettings = false

        guard shouldRestorePlaylist else {
            return
        }

        presentedPanel = .playlist
        if !isFullScreen {
            restoresPlaylistAfterFullScreen = false
        }
        applyFullScreenPlaylistPolicy()
    }

    private func refreshAutoHideTask() {
        cancelAutoHideTask()
        guard isVisible, shouldAutoHide else {
            return
        }

        let delay = autoHideDelayNanoseconds
        let sleep = sleep
        autoHideTask = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }

            guard !Task.isCancelled, let self else {
                return
            }
            completeAutoHide()
        }
    }

    private func completeAutoHide() {
        autoHideTask = nil
        guard shouldAutoHide else {
            return
        }
        setVisible(false)
    }

    private func cancelAutoHideTask() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else {
            return
        }
        self.isVisible = isVisible
    }

    private var shouldAutoHide: Bool {
        playbackState.canAutoHideChrome && presentedPanel == nil
    }
}

private extension PlayerChromePlaybackState {
    var canAutoHideChrome: Bool {
        !isPlayerWindowDismissed
            && readiness == .ready
            && isActuallyPlaying
            && isPlaybackRequested
            && hasPlayableMedia
    }

    var canAutoDismissPlaylist: Bool {
        canAutoHideChrome
    }

    var shouldRevealChrome: Bool {
        guard !isPlayerWindowDismissed else {
            return false
        }

        if !isPlaybackRequested {
            return true
        }

        switch readiness {
        case .empty, .failed:
            return !hasPlayableMedia
        case .ready:
            return false
        case .loading:
            return false
        }
    }
}
