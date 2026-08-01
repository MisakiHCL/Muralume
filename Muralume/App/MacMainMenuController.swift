import AppKit
import Combine

struct MacMainMenuCommandState: Equatable {
    let isPlaybackRequested: Bool
    let isMuted: Bool
    let canControlPlayback: Bool
    let canPlayPrevious: Bool
    let canPlayNext: Bool
    let canIncreaseVolume: Bool
    let canDecreaseVolume: Bool
    let canEnterDesktop: Bool
    let canUseWindowActions: Bool
}

@MainActor
protocol MacMainMenuCommandHandling: AnyObject {
    var mainMenuCommandState: MacMainMenuCommandState { get }
    var mainMenuCommandStateDidChange: AnyPublisher<Void, Never> { get }

    func openSettings()
    func addFolders()
    func togglePlaybackFromMenu()
    func seekBackwardFromMenu()
    func seekForwardFromMenu()
    func playPreviousFromMenu()
    func playNextFromMenu()
    func increaseVolumeFromMenu()
    func decreaseVolumeFromMenu()
    func toggleMuteFromMenu()
    func enterDesktopFromMenu()
    func toggleFullScreen()
    func handleCloseCommand(for window: NSWindow?) -> Bool
}

@MainActor
final class MacMainMenuController: NSObject, NSMenuDelegate {
    private enum Shortcut {
        static let addFolder = "o"
        static let togglePlayback = " "
        static let seekBackward = functionKey(NSLeftArrowFunctionKey)
        static let seekForward = functionKey(NSRightArrowFunctionKey)
        static let previousItem = functionKey(NSLeftArrowFunctionKey)
        static let nextItem = functionKey(NSRightArrowFunctionKey)
        static let volumeUp = functionKey(NSUpArrowFunctionKey)
        static let volumeDown = functionKey(NSDownArrowFunctionKey)
        static let toggleMute = "m"
        static let toggleFullScreen = "f"
        static let settings = ","
        static let closeWindow = "w"
        static let minimizeWindow = "m"
        static let hideApplication = "h"
        static let hideOtherApplications = "h"
        static let quitApplication = "q"

        private static func functionKey(_ value: Int) -> String {
            guard let scalar = UnicodeScalar(value) else {
                return ""
            }
            return String(scalar)
        }
    }

    private enum PlayerCommand {
        case addFolders
        case togglePlayback
        case seekBackward
        case seekForward
        case playPrevious
        case playNext
        case increaseVolume
        case decreaseVolume
        case toggleMute
        case enterDesktop
        case toggleFullScreen
    }

    private weak var application: NSApplication?
    private weak var commandHandler: (any MacMainMenuCommandHandling)?
    private weak var mainWindow: NSWindow?
    private let localization: AppLocalizationController

    private var cancellables: Set<AnyCancellable> = []
    private var isObserving = false

    private let rootMenu = NSMenu()
    private let applicationMenu = NSMenu()
    private let actionsMenu = NSMenu()
    private let windowMenu = NSMenu()
    private let helpMenu = NSMenu()
    private let servicesMenu = NSMenu()
    private let dockMenu = NSMenu()

    private let applicationMenuItem = NSMenuItem()
    private let actionsMenuItem = NSMenuItem()
    private let windowMenuItem = NSMenuItem()
    private let helpMenuItem = NSMenuItem()

    private let aboutItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let servicesItem = NSMenuItem()
    private let hideApplicationItem = NSMenuItem()
    private let hideOtherApplicationsItem = NSMenuItem()
    private let showAllApplicationsItem = NSMenuItem()
    private let quitApplicationItem = NSMenuItem()

    private let addFolderItem = NSMenuItem()
    private let togglePlaybackItem = NSMenuItem()
    private let seekBackwardItem = NSMenuItem()
    private let seekForwardItem = NSMenuItem()
    private let previousItem = NSMenuItem()
    private let nextItem = NSMenuItem()
    private let volumeUpItem = NSMenuItem()
    private let volumeDownItem = NSMenuItem()
    private let toggleMuteItem = NSMenuItem()
    private let enterDesktopItem = NSMenuItem()
    private let toggleFullScreenItem = NSMenuItem()
    private let dockEnterDesktopItem = NSMenuItem()

    private let closeWindowItem = NSMenuItem()
    private let minimizeWindowItem = NSMenuItem()
    private let zoomWindowItem = NSMenuItem()
    private let bringAllToFrontItem = NSMenuItem()
    private let showHelpItem = NSMenuItem()

    init(
        application: NSApplication,
        localization: AppLocalizationController,
        commandHandler: any MacMainMenuCommandHandling,
        mainWindow: NSWindow
    ) {
        self.application = application
        self.localization = localization
        self.commandHandler = commandHandler
        self.mainWindow = mainWindow
        super.init()

        configureMenuStructure()
        configureDockMenu()
        updateLocalizedTitles()
        refresh()
    }

    var canonicalMenu: NSMenu {
        rootMenu
    }

    var applicationDockMenu: NSMenu {
        refresh()
        return dockMenu
    }

    func install() {
        guard let application else {
            return
        }

        application.servicesMenu = servicesMenu
        application.windowsMenu = windowMenu
        application.helpMenu = helpMenu
        application.mainMenu = rootMenu
        startObserving()
        refresh()
    }

    func stop() {
        cancellables.removeAll()
        isObserving = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    func refresh() {
        guard let application, let commandHandler else {
            disablePlayerCommands()
            return
        }

        let hasPlayerFocus = playerHasCommandFocus
        refreshPlayerCommands(
            state: commandHandler.mainMenuCommandState,
            hasPlayerFocus: hasPlayerFocus
        )

        let keyWindow = application.keyWindow
        closeWindowItem.isEnabled = keyWindow != nil
        minimizeWindowItem.isEnabled = canMinimize(keyWindow)
        zoomWindowItem.isEnabled = canZoom(keyWindow)
        bringAllToFrontItem.isEnabled =
            application.windows.contains(where: \.isVisible)
    }

    func refreshPlayerCommands(
        state: MacMainMenuCommandState,
        hasPlayerFocus: Bool
    ) {
        addFolderItem.isEnabled =
            hasPlayerFocus && isEnabled(.addFolders, in: state)
        togglePlaybackItem.isEnabled =
            hasPlayerFocus && isEnabled(.togglePlayback, in: state)
        seekBackwardItem.isEnabled =
            hasPlayerFocus && isEnabled(.seekBackward, in: state)
        seekForwardItem.isEnabled =
            hasPlayerFocus && isEnabled(.seekForward, in: state)
        previousItem.isEnabled =
            hasPlayerFocus && isEnabled(.playPrevious, in: state)
        nextItem.isEnabled =
            hasPlayerFocus && isEnabled(.playNext, in: state)
        volumeUpItem.isEnabled =
            hasPlayerFocus && isEnabled(.increaseVolume, in: state)
        volumeDownItem.isEnabled =
            hasPlayerFocus && isEnabled(.decreaseVolume, in: state)
        toggleMuteItem.isEnabled =
            hasPlayerFocus && isEnabled(.toggleMute, in: state)
        enterDesktopItem.isEnabled =
            hasPlayerFocus && isEnabled(.enterDesktop, in: state)
        dockEnterDesktopItem.isEnabled = state.canEnterDesktop
        toggleFullScreenItem.isEnabled =
            hasPlayerFocus && isEnabled(.toggleFullScreen, in: state)

        togglePlaybackItem.title = localization.localized(
            state.isPlaybackRequested ? "player.pause" : "player.play"
        )
        toggleMuteItem.title = localization.localized(
            state.isMuted ? "player.unmute" : "player.mute"
        )
    }

    private func configureMenuStructure() {
        rootMenu.autoenablesItems = false
        actionsMenu.autoenablesItems = false
        windowMenu.autoenablesItems = false
        actionsMenu.delegate = self
        windowMenu.delegate = self

        attach(applicationMenu, to: applicationMenuItem)
        attach(actionsMenu, to: actionsMenuItem)
        attach(windowMenu, to: windowMenuItem)
        attach(helpMenu, to: helpMenuItem)

        rootMenu.addItem(applicationMenuItem)
        rootMenu.addItem(actionsMenuItem)
        rootMenu.addItem(windowMenuItem)
        rootMenu.addItem(helpMenuItem)

        configureApplicationMenu()
        configureActionsMenu()
        configureWindowMenu()
        configureHelpMenu()
    }

    private func configureDockMenu() {
        dockMenu.autoenablesItems = false
        dockMenu.delegate = self
        configure(
            dockEnterDesktopItem,
            action: #selector(enterDesktopFromDock(_:))
        )
        dockMenu.addItem(dockEnterDesktopItem)
    }

    private func configureApplicationMenu() {
        configure(
            aboutItem,
            action: #selector(showAbout(_:))
        )
        configure(
            settingsItem,
            action: #selector(openSettings(_:)),
            keyEquivalent: Shortcut.settings,
            modifiers: [.command]
        )
        servicesItem.submenu = servicesMenu
        configure(
            hideApplicationItem,
            action: #selector(hideApplication(_:)),
            keyEquivalent: Shortcut.hideApplication,
            modifiers: [.command]
        )
        configure(
            hideOtherApplicationsItem,
            action: #selector(hideOtherApplications(_:)),
            keyEquivalent: Shortcut.hideOtherApplications,
            modifiers: [.command, .option]
        )
        configure(
            showAllApplicationsItem,
            action: #selector(showAllApplications(_:))
        )
        configure(
            quitApplicationItem,
            action: #selector(quitApplication(_:)),
            keyEquivalent: Shortcut.quitApplication,
            modifiers: [.command]
        )

        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(servicesItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(hideApplicationItem)
        applicationMenu.addItem(hideOtherApplicationsItem)
        applicationMenu.addItem(showAllApplicationsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(quitApplicationItem)
    }

    private func configureActionsMenu() {
        configure(
            addFolderItem,
            action: #selector(addFolders(_:)),
            keyEquivalent: Shortcut.addFolder,
            modifiers: [.command]
        )
        configure(
            togglePlaybackItem,
            action: #selector(togglePlayback(_:)),
            keyEquivalent: Shortcut.togglePlayback
        )
        configure(
            seekBackwardItem,
            action: #selector(seekBackward(_:)),
            keyEquivalent: Shortcut.seekBackward
        )
        configure(
            seekForwardItem,
            action: #selector(seekForward(_:)),
            keyEquivalent: Shortcut.seekForward
        )
        configure(
            previousItem,
            action: #selector(playPrevious(_:)),
            keyEquivalent: Shortcut.previousItem,
            modifiers: [.command]
        )
        configure(
            nextItem,
            action: #selector(playNext(_:)),
            keyEquivalent: Shortcut.nextItem,
            modifiers: [.command]
        )
        configure(
            volumeUpItem,
            action: #selector(increaseVolume(_:)),
            keyEquivalent: Shortcut.volumeUp
        )
        configure(
            volumeDownItem,
            action: #selector(decreaseVolume(_:)),
            keyEquivalent: Shortcut.volumeDown
        )
        configure(
            toggleMuteItem,
            action: #selector(toggleMute(_:)),
            keyEquivalent: Shortcut.toggleMute
        )
        configure(
            enterDesktopItem,
            action: #selector(enterDesktop(_:))
        )
        configure(
            toggleFullScreenItem,
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: Shortcut.toggleFullScreen
        )

        actionsMenu.addItem(addFolderItem)
        actionsMenu.addItem(enterDesktopItem)
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(togglePlaybackItem)
        actionsMenu.addItem(seekBackwardItem)
        actionsMenu.addItem(seekForwardItem)
        actionsMenu.addItem(previousItem)
        actionsMenu.addItem(nextItem)
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(volumeUpItem)
        actionsMenu.addItem(volumeDownItem)
        actionsMenu.addItem(toggleMuteItem)
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(toggleFullScreenItem)
    }

    private func configureWindowMenu() {
        configure(
            closeWindowItem,
            action: #selector(closeKeyWindow(_:)),
            keyEquivalent: Shortcut.closeWindow,
            modifiers: [.command]
        )
        configure(
            minimizeWindowItem,
            action: #selector(minimizeKeyWindow(_:)),
            keyEquivalent: Shortcut.minimizeWindow,
            modifiers: [.command]
        )
        configure(
            zoomWindowItem,
            action: #selector(zoomKeyWindow(_:))
        )
        configure(
            bringAllToFrontItem,
            action: #selector(bringAllToFront(_:))
        )

        windowMenu.addItem(closeWindowItem)
        windowMenu.addItem(minimizeWindowItem)
        windowMenu.addItem(zoomWindowItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(bringAllToFrontItem)
    }

    private func configureHelpMenu() {
        configure(
            showHelpItem,
            action: #selector(showHelp(_:))
        )
        helpMenu.addItem(showHelpItem)
    }

    private func configure(
        _ item: NSMenuItem,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) {
        item.target = self
        item.action = action
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = modifiers
    }

    private func attach(_ submenu: NSMenu, to item: NSMenuItem) {
        item.submenu = submenu
    }

    private func startObserving() {
        guard !isObserving, let commandHandler else {
            return
        }
        isObserving = true

        commandHandler.mainMenuCommandStateDidChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        localization.localizationDidChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.updateLocalizedTitles()
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        .forEach { notificationName in
            center.publisher(for: notificationName)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refresh()
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func updateLocalizedTitles() {
        let appName = localization.localized("app.name")
        applicationMenuItem.title = appName
        applicationMenu.title = appName
        actionsMenuItem.title = localization.localized("menu.actions")
        actionsMenu.title = actionsMenuItem.title
        windowMenuItem.title = localization.localized("menu.window")
        windowMenu.title = windowMenuItem.title
        helpMenuItem.title = localization.localized("menu.help")
        helpMenu.title = helpMenuItem.title

        aboutItem.title = localization.localized("menu.about")
        settingsItem.title = localization.localized("menu.settings")
        servicesItem.title = localization.localized("menu.services")
        servicesMenu.title = servicesItem.title
        hideApplicationItem.title = localization.localized(
            "menu.hideApplication"
        )
        hideOtherApplicationsItem.title = localization.localized(
            "menu.hideOtherApplications"
        )
        showAllApplicationsItem.title = localization.localized(
            "menu.showAllApplications"
        )
        quitApplicationItem.title = localization.localized(
            "menu.quitApplication"
        )

        addFolderItem.title = localization.localized("library.add.folder")
        seekBackwardItem.title = localization.localized("player.back")
        seekForwardItem.title = localization.localized("player.forward")
        previousItem.title = localization.localized("player.previousItem")
        nextItem.title = localization.localized("player.nextItem")
        volumeUpItem.title = localization.localized("player.volumeUp")
        volumeDownItem.title = localization.localized("player.volumeDown")
        toggleFullScreenItem.title = localization.localized(
            "player.fullscreen"
        )
        let enterDesktopTitle = localization.localized("player.desktop")
        enterDesktopItem.title = enterDesktopTitle
        dockEnterDesktopItem.title = enterDesktopTitle

        closeWindowItem.title = localization.localized("menu.closeWindow")
        minimizeWindowItem.title = localization.localized(
            "menu.minimizeWindow"
        )
        zoomWindowItem.title = localization.localized("menu.zoomWindow")
        bringAllToFrontItem.title = localization.localized(
            "menu.bringAllToFront"
        )
        showHelpItem.title = localization.localized("menu.showHelp")
    }

    private func disablePlayerCommands() {
        [
            addFolderItem,
            togglePlaybackItem,
            seekBackwardItem,
            seekForwardItem,
            previousItem,
            nextItem,
            volumeUpItem,
            volumeDownItem,
            toggleMuteItem,
            enterDesktopItem,
            dockEnterDesktopItem,
            toggleFullScreenItem
        ].forEach { $0.isEnabled = false }
    }

    private var playerHasCommandFocus: Bool {
        guard let application,
              let mainWindow,
              application.keyWindow === mainWindow,
              mainWindow.isVisible else {
            return false
        }
        if let textView = mainWindow.firstResponder as? NSTextView,
           textView.isEditable {
            return false
        }
        return true
    }

    private func isEnabled(
        _ command: PlayerCommand,
        in state: MacMainMenuCommandState
    ) -> Bool {
        switch command {
        case .addFolders, .toggleFullScreen:
            state.canUseWindowActions
        case .enterDesktop:
            state.canEnterDesktop
        case .togglePlayback, .seekBackward, .seekForward:
            state.canControlPlayback
        case .toggleMute:
            state.canUseWindowActions
        case .playPrevious:
            state.canPlayPrevious
        case .playNext:
            state.canPlayNext
        case .increaseVolume:
            state.canIncreaseVolume
        case .decreaseVolume:
            state.canDecreaseVolume
        }
    }

    private func performPlayerCommand(
        _ command: PlayerCommand,
        action: (any MacMainMenuCommandHandling) -> Void
    ) {
        guard playerHasCommandFocus,
              let commandHandler,
              isEnabled(command, in: commandHandler.mainMenuCommandState) else {
            refresh()
            return
        }
        action(commandHandler)
    }

    private func performDockCommand(
        action: (any MacMainMenuCommandHandling) -> Void
    ) {
        guard let commandHandler,
              commandHandler.mainMenuCommandState.canEnterDesktop else {
            refresh()
            return
        }
        action(commandHandler)
    }

    private func canMinimize(_ window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }
        return window.styleMask.contains(.miniaturizable)
            && !window.styleMask.contains(.fullScreen)
            && !window.isMiniaturized
    }

    private func canZoom(_ window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }
        return window.styleMask.contains(.resizable)
            && !window.styleMask.contains(.fullScreen)
    }

    @objc
    private func showAbout(_ sender: Any?) {
        application?.orderFrontStandardAboutPanel(sender)
    }

    @objc
    private func openSettings(_ sender: Any?) {
        commandHandler?.openSettings()
    }

    @objc
    private func hideApplication(_ sender: Any?) {
        application?.hide(sender)
    }

    @objc
    private func hideOtherApplications(_ sender: Any?) {
        application?.hideOtherApplications(sender)
    }

    @objc
    private func showAllApplications(_ sender: Any?) {
        application?.unhideAllApplications(sender)
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        application?.terminate(sender)
    }

    @objc
    private func addFolders(_ sender: Any?) {
        performPlayerCommand(.addFolders) {
            $0.addFolders()
        }
    }

    @objc
    private func togglePlayback(_ sender: Any?) {
        performPlayerCommand(.togglePlayback) {
            $0.togglePlaybackFromMenu()
        }
    }

    @objc
    private func seekBackward(_ sender: Any?) {
        performPlayerCommand(.seekBackward) {
            $0.seekBackwardFromMenu()
        }
    }

    @objc
    private func seekForward(_ sender: Any?) {
        performPlayerCommand(.seekForward) {
            $0.seekForwardFromMenu()
        }
    }

    @objc
    private func playPrevious(_ sender: Any?) {
        performPlayerCommand(.playPrevious) {
            $0.playPreviousFromMenu()
        }
    }

    @objc
    private func playNext(_ sender: Any?) {
        performPlayerCommand(.playNext) {
            $0.playNextFromMenu()
        }
    }

    @objc
    private func increaseVolume(_ sender: Any?) {
        performPlayerCommand(.increaseVolume) {
            $0.increaseVolumeFromMenu()
        }
    }

    @objc
    private func decreaseVolume(_ sender: Any?) {
        performPlayerCommand(.decreaseVolume) {
            $0.decreaseVolumeFromMenu()
        }
    }

    @objc
    private func toggleMute(_ sender: Any?) {
        performPlayerCommand(.toggleMute) {
            $0.toggleMuteFromMenu()
        }
    }

    @objc
    private func enterDesktop(_ sender: Any?) {
        performPlayerCommand(.enterDesktop) {
            $0.enterDesktopFromMenu()
        }
    }

    @objc
    private func enterDesktopFromDock(_ sender: Any?) {
        performDockCommand {
            $0.enterDesktopFromMenu()
        }
    }

    @objc
    private func toggleFullScreen(_ sender: Any?) {
        performPlayerCommand(.toggleFullScreen) {
            $0.toggleFullScreen()
        }
    }

    @objc
    private func closeKeyWindow(_ sender: Any?) {
        guard let window = application?.keyWindow else {
            return
        }
        if commandHandler?.handleCloseCommand(for: window) == true {
            return
        }
        window.performClose(sender)
    }

    @objc
    private func minimizeKeyWindow(_ sender: Any?) {
        guard let window = application?.keyWindow,
              canMinimize(window) else {
            refresh()
            return
        }
        window.performMiniaturize(sender)
    }

    @objc
    private func zoomKeyWindow(_ sender: Any?) {
        guard let window = application?.keyWindow,
              canZoom(window) else {
            refresh()
            return
        }
        window.performZoom(sender)
    }

    @objc
    private func bringAllToFront(_ sender: Any?) {
        guard let application else {
            return
        }
        let visibleWindows = application.windows.filter(\.isVisible)
        for window in visibleWindows.reversed() {
            window.orderFront(sender)
        }
        if !visibleWindows.isEmpty {
            application.activate(ignoringOtherApps: true)
        }
    }

    @objc
    private func showHelp(_ sender: Any?) {
        application?.showHelp(sender)
    }
}
