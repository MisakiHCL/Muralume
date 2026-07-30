import AppKit
import Combine
import SwiftUI

@main
@MainActor
enum MuralumeApplication {
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()

        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        appDelegate.prepareForRun(application)
        application.run()

        withExtendedLifetime(appDelegate) {}
    }
}

@MainActor
final class MacApplicationRuntime {
    let coordinator: AppCoordinator

    private let application: NSApplication
    private let localization: AppLocalizationController
    private let mainWindow: NSWindow
    private let settingsWindowController: MacSettingsWindowController
    private let mainMenuController: MacMainMenuController
    private var cancellables: Set<AnyCancellable> = []
    private var hasLaunched = false

    init(application: NSApplication) {
        self.application = application

        let localization = AppLocalizationController(
            storage: UserDefaultsAppLanguageStore()
        )
        self.localization = localization

        let coordinator = AppCompositionRoot.makeAppCoordinator(
            localization: localization
        )
        self.coordinator = coordinator

        let settingsWindowController = MacSettingsWindowController(
            application: application,
            localization: localization
        )
        self.settingsWindowController = settingsWindowController
        coordinator.openSettingsHandler = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }

        let mainWindow = Self.makeMainWindow(
            title: localization.localized("window.title")
        )
        self.mainWindow = mainWindow
        coordinator.attachMainWindow(mainWindow)

        let rootView = MuralumePlayerRootView(
            coordinator: coordinator,
            localization: localization
        )
        mainWindow.contentViewController = NSHostingController(
            rootView: rootView
        )

        let mainMenuController = MacMainMenuController(
            application: application,
            localization: localization,
            commandHandler: coordinator,
            mainWindow: mainWindow
        )
        self.mainMenuController = mainMenuController
        mainMenuController.install()

        localization.localizationDidChange
            .sink { [weak mainWindow, weak localization] in
                Task { @MainActor in
                    guard let mainWindow, let localization else {
                        return
                    }
                    mainWindow.title = localization.localized("window.title")
                }
            }
            .store(in: &cancellables)
    }

    func launch() {
        guard !hasLaunched else {
            return
        }
        hasLaunched = true

        coordinator.start()
        mainWindow.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }

    func stop() {
        mainMenuController.stop()
        cancellables.removeAll()
    }

    static func makeMainWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppConfiguration.preferredWindowWidth,
                height: AppConfiguration.preferredWindowHeight
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(
            AppConfiguration.mainWindowSceneID
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = true
        window.center()
        return window
    }
}

private struct MuralumePlayerRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var localization: AppLocalizationController

    var body: some View {
        PlayerScreen(
            playback: coordinator.playback,
            desktopSession: coordinator.desktopSession,
            library: coordinator.library,
            mediaThumbnailProvider: coordinator.mediaThumbnailProvider,
            isFullScreen: coordinator.isMainWindowFullScreen,
            actions: PlayerActions(
                addFolders: {
                    coordinator.addFolders()
                },
                enterDesktop: {
                    coordinator.enterDesktop()
                },
                openSettings: {
                    coordinator.openSettings()
                },
                closeWindow: {
                    coordinator.dismissMainWindow()
                },
                minimizeWindow: {
                    coordinator.minimizeMainWindow()
                },
                toggleFullScreen: {
                    coordinator.toggleFullScreen()
                }
            ),
            playerSurface: PlayerSurfaceRepresentable(
                makeSurface: {
                    PlayerLayerSurfaceView(
                        id: .player,
                        videoGravity: .resizeAspect
                    )
                },
                onSurfaceCreated: { surface in
                    coordinator.playback.registerPlayerSurface(surface)
                }
            )
        )
        .environmentObject(localization)
        .environment(\.locale, localization.locale)
        .tint(MuralumeTheme.Colors.controlAccent)
        .preferredColorScheme(.dark)
    }
}

@MainActor
private final class MacSettingsWindowController {
    private weak var application: NSApplication?
    private let localization: AppLocalizationController
    private var window: NSWindow?
    private var localizationCancellable: AnyCancellable?

    init(
        application: NSApplication,
        localization: AppLocalizationController
    ) {
        self.application = application
        self.localization = localization

        localizationCancellable = localization.localizationDidChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.updateLocalizedTitle()
                }
            }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        updateLocalizedTitle()
        window.makeKeyAndOrderFront(nil)
        application?.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let rootView = MuralumeSettingsRootView(
            localization: localization
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppConfiguration.settingsWindowWidth,
                height: AppConfiguration.settingsWindowHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: rootView
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MuralumeTheme.Colors.windowNSColor
        window.center()
        return window
    }

    private func updateLocalizedTitle() {
        window?.title = localization.localized("settings.title")
    }
}

private struct MuralumeSettingsRootView: View {
    @ObservedObject var localization: AppLocalizationController

    var body: some View {
        SettingsView(localization: localization)
            .environmentObject(localization)
            .environment(\.locale, localization.locale)
            .tint(MuralumeTheme.Colors.controlAccent)
            .preferredColorScheme(.dark)
    }
}
