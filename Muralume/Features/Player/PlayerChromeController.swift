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

@MainActor
final class PlayerChromeController: ObservableObject {
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    @Published private(set) var isVisible = true
    @Published private(set) var isPlaylistPresented = true

    private let autoHideDelayNanoseconds: UInt64
    private let sleep: Sleep

    private var playbackState = PlayerChromePlaybackState.empty
    private var isFullScreen = false
    private var restoresPlaylistAfterFullScreen = false
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
        restoresPlaylistAfterFullScreen = false
        setVisible(true)
        isPlaylistPresented = isPresented
        refreshAutoHideTask()
    }

    func togglePlaylist() {
        setPlaylistPresented(!isPlaylistPresented)
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
               !isPlaylistPresented {
                isPlaylistPresented = true
            }
            restoresPlaylistAfterFullScreen = false
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
        isPlaylistPresented = false
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
        playbackState.canAutoHideChrome && !isPlaylistPresented
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
