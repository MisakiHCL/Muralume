import AppKit
import Combine
import SwiftUI

@MainActor
final class MuralumeMainWindow: NSWindow {
    var cancelOperationHandler: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        guard cancelOperationHandler?() != true else {
            return
        }
        super.cancelOperation(sender)
    }
}

@main
@MainActor
enum MuralumeApplication {
    static func main() {
        let application = NSApplication.shared
        let isHostedUnitTest = MacHostedUnitTestDetector().detect()
        let appDelegate = AppDelegate(
            allowsRuntimeCreation: !isHostedUnitTest
        )

        // Start without a Dock icon until AppKit's launch AppleEvent tells us
        // whether this is an interactive launch or a login-item restore.
        // Accessory apps can become regular apps reliably after launch.
        application.setActivationPolicy(.accessory)
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
    private let preferencesStore: any AppPreferencesStoring
    private let localization: AppLocalizationController
    private let mainWindow: MuralumeMainWindow
    private let mainMenuController: MacMainMenuController
    private var cancellables: Set<AnyCancellable> = []
    private var hasLaunched = false

    init(application: NSApplication) {
        self.application = application

        let preferencesStore = UserDefaultsAppPreferencesStore()
        let initialPreferences = preferencesStore.load()
        self.preferencesStore = preferencesStore

        let localization = AppLocalizationController(
            initialLanguage: initialPreferences.language,
            preferencesStore: preferencesStore
        )
        self.localization = localization

        let coordinator = AppCompositionRoot.makeAppCoordinator(
            localization: localization,
            initialPreferences: initialPreferences,
            preferencesStore: preferencesStore
        )
        self.coordinator = coordinator

        let mainWindow = Self.makeMainWindow(
            title: localization.localized("window.title")
        )
        mainWindow.cancelOperationHandler = { [weak coordinator] in
            coordinator?.dismissPresentedPanel() ?? false
        }
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

    var applicationDockMenu: NSMenu {
        mainMenuController.applicationDockMenu
    }

    func launch(source: ApplicationLaunchSource) {
        guard !hasLaunched else {
            return
        }
        hasLaunched = true

        coordinator.start(source: source)
    }

    func stop() {
        mainWindow.cancelOperationHandler = nil
        mainMenuController.stop()
        cancellables.removeAll()
    }

    static func makeMainWindow(title: String) -> MuralumeMainWindow {
        let window = MuralumeMainWindow(
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
            dynamicDesktopStartup: coordinator.dynamicDesktopStartup,
            mediaThumbnailProvider: coordinator.mediaThumbnailProvider,
            isFullScreen: coordinator.isMainWindowFullScreen,
            chromeController: coordinator.playerChrome,
            actions: PlayerActions(
                addVideos: {
                    coordinator.addVideos()
                },
                addFolders: {
                    coordinator.addFolders()
                },
                importDroppedURLs: { urls in
                    coordinator.importDroppedURLs(urls)
                },
                enterDesktop: {
                    coordinator.enterDesktop()
                },
                toggleSettings: {
                    coordinator.toggleSettings()
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
