import AppKit
import SwiftUI

@main
@MainActor
struct MuralumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var localization: AppLocalizationController

    init() {
        let localization = AppLocalizationController(
            storage: UserDefaultsAppLanguageStore()
        )
        let coordinator = AppCompositionRoot.makeAppCoordinator(
            localization: localization
        )
        _localization = StateObject(wrappedValue: localization)
        _coordinator = StateObject(wrappedValue: coordinator)
        appDelegate.coordinator = coordinator
    }

    var body: some Scene {
        Window("app.name", id: AppConfiguration.mainWindowSceneID) {
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
                .task {
                    coordinator.start()
                }
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .tint(MuralumeTheme.Colors.controlAccent)
                .preferredColorScheme(.dark)
                .muralumeHidesSystemWindowToolbar()
                .background {
                    WindowReader { window in
                        coordinator.attachMainWindow(window)
                    }
                }
        }
        .defaultSize(
            width: AppConfiguration.preferredWindowWidth,
            height: AppConfiguration.preferredWindowHeight
        )
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commandsReplaced {
            CommandMenu(localization.localized("menu.actions")) {
                Button(localization.localized("library.add.folder")) {
                    coordinator.addFolders()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(localization.localized("player.fullscreen")) {
                    coordinator.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }

        Settings {
            SettingsView(localization: localization)
                .environment(\.locale, localization.locale)
                .tint(MuralumeTheme.Colors.controlAccent)
                .preferredColorScheme(.dark)
                .background {
                    WindowReader { window in
                        window.appearance = NSAppearance(named: .darkAqua)
                        window.backgroundColor =
                            MuralumeTheme.Colors.windowNSColor
                    }
                }
        }
    }
}
