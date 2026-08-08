import AppKit
import Combine
import XCTest
@testable import Muralume

@MainActor
final class AppDelegateTests: XCTestCase {
    func testLastWindowClosingDoesNotTerminateApplication() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp)
        )
    }

    func testReopenAlwaysRoutesToCoordinatorAndSuppressesDefaultHandling() {
        let delegate = AppDelegate()
        let coordinator = TestAppLifecycleCoordinator()
        delegate.coordinator = coordinator

        let handledWithNoVisibleWindows =
            delegate.applicationShouldHandleReopen(
                NSApp,
                hasVisibleWindows: false
            )
        let handledWithVisibleAuxiliaryWindow =
            delegate.applicationShouldHandleReopen(
                NSApp,
                hasVisibleWindows: true
            )

        XCTAssertFalse(handledWithNoVisibleWindows)
        XCTAssertFalse(handledWithVisibleAuxiliaryWindow)
        XCTAssertEqual(coordinator.reopenMainWindowCount, 2)
    }

    func testReopenWithoutCoordinatorFallsBackToDefaultHandling() {
        let delegate = AppDelegate()

        let handled = delegate.applicationShouldHandleReopen(
            NSApp,
            hasVisibleWindows: true
        )

        XCTAssertTrue(handled)
    }

    func testActivationRoutesVisibleWindowStateToCoordinator() {
        let delegate = AppDelegate()
        let coordinator = TestAppLifecycleCoordinator()
        delegate.coordinator = coordinator

        delegate.restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: true
        )
        delegate.restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: false
        )

        XCTAssertEqual(coordinator.activationVisibilityStates, [true, false])
    }

    func testLaunchSourceDetectorRecognizesLoginItemAppleEvent() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(
                enumCode: keyAELaunchedAsLogInItem
            ),
            forKeyword: keyAEPropData
        )

        XCTAssertEqual(
            MacApplicationLaunchSourceDetector().detect(event: event),
            .loginItem
        )
    }

    func testLaunchSourceDetectorKeepsInteractiveLaunchesInteractive() {
        let openEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        XCTAssertEqual(
            MacApplicationLaunchSourceDetector().detect(event: nil),
            .interactive
        )
        XCTAssertEqual(
            MacApplicationLaunchSourceDetector().detect(event: openEvent),
            .interactive
        )
    }

    func testLaunchSourceDetectorIgnoresFalseLoginItemParameter() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: false),
            forKeyword: keyAELaunchedAsLogInItem
        )

        XCTAssertEqual(
            MacApplicationLaunchSourceDetector().detect(event: event),
            .interactive
        )
    }

    func testLaunchSourceDetectorRequiresCoreEventClass() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAEInternetSuite),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(
                enumCode: keyAELaunchedAsLogInItem
            ),
            forKeyword: keyAEPropData
        )

        XCTAssertEqual(
            MacApplicationLaunchSourceDetector().detect(event: event),
            .interactive
        )
    }

    func testHostedUnitTestDetectorMatchesOnlyUnitTestBundle() {
        let detector = MacHostedUnitTestDetector()

        XCTAssertTrue(
            detector.detect(
                loadedBundleIdentifiers: [
                    "com.apple.dt.XCTest",
                    "com.muralume.MuralumeTests"
                ],
                environment: [:]
            )
        )
        XCTAssertFalse(
            detector.detect(
                loadedBundleIdentifiers: [
                    "com.apple.dt.XCTest",
                    "com.muralume.MuralumeUITests"
                ],
                environment: [:]
            )
        )
    }

    func testHostedUnitTestDetectorUsesExactXCTestBundlePathFallback() {
        let detector = MacHostedUnitTestDetector()
        let sessionEnvironment = [
            "XCTestBundlePath": "Contents/PlugIns/MuralumeTests.xctest",
            "XCTestSessionIdentifier": UUID().uuidString
        ]

        XCTAssertTrue(
            detector.detect(
                loadedBundleIdentifiers: [],
                environment: sessionEnvironment
            )
        )
        XCTAssertFalse(
            detector.detect(
                loadedBundleIdentifiers: [],
                environment: [
                    "XCTestBundlePath":
                        "Contents/PlugIns/MuralumeUITests.xctest",
                    "XCTestSessionIdentifier": UUID().uuidString
                ]
            )
        )
        XCTAssertFalse(
            detector.detect(
                loadedBundleIdentifiers: [],
                environment: [
                    "XCTestBundlePath":
                        "Contents/PlugIns/MuralumeTests.xctest"
                ]
            )
        )
    }

    func testHostedUnitTestDelegateDoesNotCreateRuntime() {
        let delegate = AppDelegate(allowsRuntimeCreation: false)

        delegate.prepareForRun(NSApp)

        XCTAssertNil(delegate.coordinator)
    }

    func testHostedUnitTestProcessDoesNotCreateMainWindow() {
        XCTAssertTrue(MacHostedUnitTestDetector().detect())
        XCTAssertFalse(
            NSApp.windows.contains {
                $0.identifier?.rawValue == AppConfiguration.mainWindowSceneID
            }
        )
    }

    func testMainMenuControllerBuildsOnlyCanonicalTopLevelMenus() {
        let commandHandler = TestMainMenuCommandHandler()
        let window = NSWindow()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: window
        )

        XCTAssertEqual(
            controller.canonicalMenu.items.map(\.title),
            ["Muralume", "Actions", "Window", "Help"]
        )
        XCTAssertFalse(
            controller.canonicalMenu.items.contains {
                ["File", "Edit", "Format", "View"].contains($0.title)
            }
        )
    }

    func testRuntimeMainWindowIsExcludedFromAutomaticWindowMenu() {
        let window = MacApplicationRuntime.makeMainWindow(
            title: "Muralume"
        )

        XCTAssertTrue(window.isExcludedFromWindowsMenu)
    }

    func testRuntimeMainWindowRoutesCancelOperationToPanelHandler() {
        let window = MacApplicationRuntime.makeMainWindow(
            title: "Muralume"
        )
        var invocationCount = 0
        window.cancelOperationHandler = {
            invocationCount += 1
            return true
        }

        window.cancelOperation(nil)

        XCTAssertEqual(invocationCount, 1)
    }

    func testCanonicalApplicationMenuKeepsStandardMacActions() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let applicationMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first?.submenu
        )

        XCTAssertEqual(
            applicationMenu.items
                .filter { !$0.isSeparatorItem }
                .map(\.title),
            [
                "About Muralume",
                "Settings…",
                "Services",
                "Hide Muralume",
                "Hide Others",
                "Show All",
                "Quit Muralume"
            ]
        )
        XCTAssertNotNil(
            applicationMenu.items.first {
                $0.title == "Services"
            }?.submenu
        )
        XCTAssertEqual(
            applicationMenu.items.first {
                $0.title == "Settings…"
            }?.keyEquivalent,
            ","
        )
        XCTAssertEqual(
            applicationMenu.items.first {
                $0.title == "Quit Muralume"
            }?.keyEquivalent,
            "q"
        )
    }

    func testPlayerMenuUsesOneShortcutOwnerAndDynamicState() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )

        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Add Media…"
            }?.keyEquivalent,
            "o"
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Add Media…"
            }?.keyEquivalentModifierMask,
            [.command]
        )
        XCTAssertNil(
            actionsMenu.items.first { $0.title == "Add Video…" }
        )
        XCTAssertNil(
            actionsMenu.items.first { $0.title == "Add Folder…" }
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Play"
            }?.keyEquivalent,
            " "
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Toggle Full Screen"
            }?.keyEquivalent,
            "f"
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Set as Dynamic Desktop"
            }?.keyEquivalent,
            "d"
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Set as Dynamic Desktop"
            }?.keyEquivalentModifierMask,
            [.command]
        )
        XCTAssertEqual(
            actionsMenu.items.prefix(5).map {
                $0.isSeparatorItem ? "separator" : $0.title
            },
            [
                "Set as Dynamic Desktop",
                "separator",
                "Add Media…",
                "Edit",
                "separator"
            ]
        )
        XCTAssertEqual(
            actionsMenu.items.first { $0.title == "Edit" }?.keyEquivalent,
            ""
        )

        let activeState = MacMainMenuCommandState(
            isPlaybackRequested: true,
            isMuted: true,
            canControlPlayback: true,
            canPlayPrevious: true,
            canPlayNext: true,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canEnterDesktop: true,
            canUseWindowActions: true,
            canEditLibrary: true
        )
        controller.refreshPlayerCommands(
            state: activeState,
            hasPlayerFocus: true
        )

        XCTAssertTrue(
            actionsMenu.items
                .filter { !$0.isSeparatorItem }
                .allSatisfy(\.isEnabled)
        )
        XCTAssertNotNil(
            actionsMenu.items.first { $0.title == "Pause" }
        )
        XCTAssertNotNil(
            actionsMenu.items.first { $0.title == "Unmute" }
        )

        controller.refreshPlayerCommands(
            state: activeState,
            hasPlayerFocus: false
        )
        XCTAssertTrue(
            actionsMenu.items
                .filter { !$0.isSeparatorItem }
                .allSatisfy { !$0.isEnabled }
        )
    }

    func testPlayerMenuKeepsGlobalAudioCommandsEnabledWithoutMedia() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )
        let emptyMediaState = MacMainMenuCommandState(
            isPlaybackRequested: false,
            isMuted: false,
            canControlPlayback: false,
            canPlayPrevious: false,
            canPlayNext: false,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canEnterDesktop: false,
            canUseWindowActions: true,
            canEditLibrary: false
        )

        controller.refreshPlayerCommands(
            state: emptyMediaState,
            hasPlayerFocus: true
        )

        for title in [
            "Add Media…",
            "Volume Up",
            "Volume Down",
            "Mute",
            "Toggle Full Screen"
        ] {
            XCTAssertEqual(
                actionsMenu.items.first { $0.title == title }?.isEnabled,
                true,
                "\(title) should remain available without media"
            )
        }
        for title in [
            "Play",
            "Back 10 seconds",
            "Forward 10 seconds",
            "Previous Video",
            "Next Video",
            "Set as Dynamic Desktop",
            "Edit"
        ] {
            XCTAssertEqual(
                actionsMenu.items.first { $0.title == title }?.isEnabled,
                false,
                "\(title) should require playable media"
            )
        }
    }

    func testPlayerMenuActionRevalidatesWindowFocusBeforeDispatch() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )
        let staleEnabledState = MacMainMenuCommandState(
            isPlaybackRequested: true,
            isMuted: false,
            canControlPlayback: true,
            canPlayPrevious: true,
            canPlayNext: true,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canEnterDesktop: true,
            canUseWindowActions: true,
            canEditLibrary: true
        )
        controller.refreshPlayerCommands(
            state: staleEnabledState,
            hasPlayerFocus: true
        )
        let pauseItem = try XCTUnwrap(
            actionsMenu.items.first { $0.title == "Pause" }
        )
        let action = try XCTUnwrap(pauseItem.action)

        XCTAssertTrue(pauseItem.isEnabled)
        XCTAssertTrue(
            NSApp.sendAction(
                action,
                to: pauseItem.target,
                from: pauseItem
            )
        )
        XCTAssertEqual(commandHandler.togglePlaybackCommandCount, 0)
        XCTAssertFalse(pauseItem.isEnabled)
    }

    func testDockMenuDispatchesDesktopCommandAfterPlayerWindowSoftClose() throws {
        let commandHandler = TestMainMenuCommandHandler()
        commandHandler.mainMenuCommandState = MacMainMenuCommandState(
            isPlaybackRequested: false,
            isMuted: false,
            canControlPlayback: false,
            canPlayPrevious: false,
            canPlayNext: false,
            canIncreaseVolume: false,
            canDecreaseVolume: false,
            canEnterDesktop: true,
            canUseWindowActions: false,
            canEditLibrary: false
        )
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let dockItem = try XCTUnwrap(
            controller.applicationDockMenu.items.first
        )
        let action = try XCTUnwrap(dockItem.action)

        XCTAssertEqual(controller.applicationDockMenu.items.count, 1)
        XCTAssertEqual(dockItem.title, "Set as Dynamic Desktop")
        XCTAssertEqual(dockItem.keyEquivalent, "")
        XCTAssertTrue(dockItem.isEnabled)
        XCTAssertTrue(
            NSApp.sendAction(action, to: dockItem.target, from: dockItem)
        )
        XCTAssertEqual(commandHandler.enterDesktopCommandCount, 1)
    }

    func testDockMenuRevalidatesDesktopAvailabilityBeforeDispatch() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let availableState = MacMainMenuCommandState(
            isPlaybackRequested: true,
            isMuted: false,
            canControlPlayback: true,
            canPlayPrevious: true,
            canPlayNext: true,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canEnterDesktop: true,
            canUseWindowActions: true,
            canEditLibrary: true
        )
        commandHandler.mainMenuCommandState = availableState
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let dockItem = try XCTUnwrap(
            controller.applicationDockMenu.items.first
        )
        let action = try XCTUnwrap(dockItem.action)
        XCTAssertTrue(dockItem.isEnabled)

        commandHandler.mainMenuCommandState = MacMainMenuCommandState(
            isPlaybackRequested: availableState.isPlaybackRequested,
            isMuted: availableState.isMuted,
            canControlPlayback: availableState.canControlPlayback,
            canPlayPrevious: availableState.canPlayPrevious,
            canPlayNext: availableState.canPlayNext,
            canIncreaseVolume: availableState.canIncreaseVolume,
            canDecreaseVolume: availableState.canDecreaseVolume,
            canEnterDesktop: false,
            canUseWindowActions: availableState.canUseWindowActions,
            canEditLibrary: availableState.canEditLibrary
        )

        XCTAssertTrue(
            NSApp.sendAction(action, to: dockItem.target, from: dockItem)
        )
        XCTAssertEqual(commandHandler.enterDesktopCommandCount, 0)
        XCTAssertFalse(dockItem.isEnabled)
    }

    private func makeMainMenuController(
        commandHandler: TestMainMenuCommandHandler,
        mainWindow: NSWindow
    ) -> MacMainMenuController {
        MacMainMenuController(
            application: NSApp,
            localization: AppLocalizationController(
                initialLanguage: .english
            ),
            commandHandler: commandHandler,
            mainWindow: mainWindow
        )
    }
}

@MainActor
private final class TestAppLifecycleCoordinator:
    AppLifecycleCoordinating
{
    private(set) var reopenMainWindowCount = 0
    private(set) var activationVisibilityStates: [Bool] = []

    func reopenMainWindow() {
        reopenMainWindowCount += 1
    }

    func handleApplicationActivation(hasVisibleWindows: Bool) {
        activationVisibilityStates.append(hasVisibleWindows)
    }

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        false
    }

    func shutdown() async {}
}

@MainActor
private final class TestMainMenuCommandHandler:
    MacMainMenuCommandHandling
{
    private let stateDidChange = PassthroughSubject<Void, Never>()
    private(set) var togglePlaybackCommandCount = 0
    private(set) var enterDesktopCommandCount = 0

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
    func editLibraryFromMenu() {}
    func togglePlaybackFromMenu() {
        togglePlaybackCommandCount += 1
    }
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
    func toggleFullScreen() {}

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        false
    }
}
