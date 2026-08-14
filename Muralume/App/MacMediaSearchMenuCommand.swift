import AppKit

/// Owns the app-wide Command-F shortcut and revalidates its target immediately
/// before dispatch. Text fields intentionally do not suppress this command.
@MainActor
final class MacMediaSearchMenuCommand: NSObject {
    typealias PlayerWindowFocusProvider = @MainActor () -> Bool

    let menuItem = NSMenuItem()

    private weak var commandHandler: (any MacMainMenuCommandHandling)?
    private let playerWindowHasFocus: PlayerWindowFocusProvider

    init(
        application: NSApplication,
        mainWindow: NSWindow,
        commandHandler: any MacMainMenuCommandHandling,
        playerWindowFocusProvider: PlayerWindowFocusProvider? = nil
    ) {
        self.commandHandler = commandHandler
        playerWindowHasFocus = playerWindowFocusProvider ?? {
            [weak application, weak mainWindow] in
            guard let application, let mainWindow else {
                return false
            }
            return application.keyWindow === mainWindow && mainWindow.isVisible
        }
        super.init()

        menuItem.target = self
        menuItem.action = #selector(searchMedia(_:))
        menuItem.keyEquivalent = "f"
        menuItem.keyEquivalentModifierMask = [.command]
    }

    func updateLocalizedTitle(
        using localization: AppLocalizationController
    ) {
        menuItem.title = localization.localized("library.search.menu")
    }

    func refresh(
        state: MacMainMenuCommandState,
        playerWindowHasFocus: Bool? = nil
    ) {
        menuItem.isEnabled = canSearch(
            state: state,
            playerWindowHasFocus: playerWindowHasFocus
        )
    }

    func disable() {
        menuItem.isEnabled = false
    }

    private func canSearch(
        state: MacMainMenuCommandState,
        playerWindowHasFocus focusOverride: Bool? = nil
    ) -> Bool {
        (focusOverride ?? playerWindowHasFocus())
            && state.canUseWindowActions
    }

    @objc
    private func searchMedia(_ sender: Any?) {
        guard let commandHandler,
              canSearch(state: commandHandler.mainMenuCommandState) else {
            disable()
            return
        }
        commandHandler.searchMediaFromMenu()
    }
}

extension AppCoordinator {
    func searchMediaFromMenu() {
        guard mainMenuCommandState.canUseWindowActions else {
            return
        }
        playerChrome.requestMediaSearch()
    }
}
