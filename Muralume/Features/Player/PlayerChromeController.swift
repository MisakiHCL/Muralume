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

enum LibrarySidebarSection: String, CaseIterable, Hashable {
    case mediaLibrary
    case playQueue
}

@MainActor
protocol PlayerChromeAutoHideScheduling: AnyObject, Sendable {
    func schedule(
        afterNanoseconds delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    )
    func cancel()
}

@MainActor
final class RunLoopPlayerChromeAutoHideScheduler:
    NSObject,
    PlayerChromeAutoHideScheduling {
    private var timer: Timer?
    private var scheduledAction: (@MainActor () -> Void)?

#if DEBUG
    private(set) var timerCreationCountForTesting = 0
#endif

    func schedule(
        afterNanoseconds delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) {
        scheduledAction = action
        let interval = TimeInterval(delayNanoseconds)
            / TimeInterval(NSEC_PER_SEC)
        if let timer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
            return
        }

        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: false
        )
        self.timer = timer
#if DEBUG
        timerCreationCountForTesting += 1
#endif
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        scheduledAction = nil
    }

    @objc
    private func timerDidFire() {
        timer = nil
        let action = scheduledAction
        scheduledAction = nil
        action?()
    }
}

@MainActor
final class PlayerChromeController: ObservableObject {
    @Published private(set) var isVisible = true
    @Published private(set) var presentedPanel: PlayerSidePanel? = .playlist
    @Published private(set) var isDesktopLayoutPresented = false
    @Published private(set) var libraryQueueMode: LibraryQueueMode = .browsing
    let librarySidebarController: LibrarySidebarController

    var librarySidebarSection: LibrarySidebarSection {
        librarySidebarController.destination == .playQueue
            ? .playQueue
            : .mediaLibrary
    }

    var playbackQueueFocusRequest: UInt64 {
        librarySidebarController.playbackQueueFocusRequest
    }

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
    private let autoHideScheduler: any PlayerChromeAutoHideScheduling

    private var playbackState = PlayerChromePlaybackState.empty
    private var isFullScreen = false
    private var restoresPlaylistAfterFullScreen = false
    private var restoresPlaylistAfterSettings = false

    init(
        autoHideDelayNanoseconds: UInt64 = MuralumeTheme.Motion
            .playerChromeAutoHideNanoseconds,
        autoHideScheduler: any PlayerChromeAutoHideScheduling =
            RunLoopPlayerChromeAutoHideScheduler(),
        librarySidebarController: LibrarySidebarController =
            LibrarySidebarController()
    ) {
        self.autoHideDelayNanoseconds = autoHideDelayNanoseconds
        self.autoHideScheduler = autoHideScheduler
        self.librarySidebarController = librarySidebarController
    }

    isolated deinit {
        autoHideScheduler.cancel()
    }

    func recordPointerActivity() {
        setVisible(true)
        refreshAutoHideSchedule()
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
        refreshAutoHideSchedule()
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
        librarySidebarController.selectDestination(.mediaLibrary)
        refreshAutoHideSchedule()
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
        if isEditing {
            librarySidebarController.selectDestination(.mediaLibrary)
        }
        setVisible(true)
        refreshAutoHideSchedule()
    }

    func selectLibrarySidebarSection(_ section: LibrarySidebarSection) {
        if section == .playQueue {
            libraryQueueMode = .browsing
        }
        librarySidebarController.selectDestination(
            section == .playQueue ? .playQueue : .mediaLibrary
        )
        if isPlaylistPresented {
            setVisible(true)
            refreshAutoHideSchedule()
        }
    }

    func selectLibrarySidebarDestination(
        _ destination: LibrarySidebarDestination
    ) {
        if destination != .mediaLibrary {
            libraryQueueMode = .browsing
        }
        librarySidebarController.selectDestination(destination)
        setPlaylistPresented(true)
    }

    /// Restores persisted navigation without revealing or replacing the
    /// currently presented panel.
    func restoreLibrarySidebarDestination(
        _ destination: LibrarySidebarDestination
    ) {
        libraryQueueMode = .browsing
        librarySidebarController.selectDestination(destination)
    }

    func requestMediaSearch() {
        libraryQueueMode = .browsing
        setPlaylistPresented(true)
        librarySidebarController.requestSearch()
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
            refreshAutoHideSchedule()
            return
        }

        guard isSettingsPresented else {
            return
        }

        presentedPanel = nil
        restorePlaylistAfterSettingsIfNeeded()
        refreshAutoHideSchedule()
    }

    func toggleSettings() {
        setSettingsPresented(!isSettingsPresented)
    }

    func presentDesktopLayout() {
        guard !isDesktopLayoutPresented else {
            return
        }

        isDesktopLayoutPresented = true
        setVisible(true)
        refreshAutoHideSchedule()
    }

    @discardableResult
    func cancelDesktopLayout() -> Bool {
        guard isDesktopLayoutPresented else {
            return false
        }

        isDesktopLayoutPresented = false
        refreshAutoHideSchedule()
        return true
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
        refreshAutoHideSchedule()
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

        refreshAutoHideSchedule()
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

    private func refreshAutoHideSchedule() {
        guard isVisible, shouldAutoHide else {
            autoHideScheduler.cancel()
            return
        }

        autoHideScheduler.schedule(
            afterNanoseconds: autoHideDelayNanoseconds
        ) { [weak self] in
            self?.completeAutoHide()
        }
    }

    private func completeAutoHide() {
        guard shouldAutoHide else {
            return
        }
        setVisible(false)
    }

    private func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else {
            return
        }
        self.isVisible = isVisible
    }

    private var shouldAutoHide: Bool {
        playbackState.canAutoHideChrome
            && presentedPanel == nil
            && !isDesktopLayoutPresented
    }
}

private extension PlayerChromePlaybackState {
    var canAutoHideChrome: Bool {
        !isPlayerWindowDismissed
            && readiness == .ready
            && hasPlayableMedia
            && (isActuallyPlaying || !isPlaybackRequested)
    }

    var canAutoDismissPlaylist: Bool {
        canAutoHideChrome
            && isActuallyPlaying
            && isPlaybackRequested
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
