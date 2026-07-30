import XCTest

final class MuralumeLaunchTests: XCTestCase {
    private enum LayoutExpectation {
        static let maximumSidebarHeaderTopInset: CGFloat = 80
        static let maximumSidebarHeaderTrailingInset: CGFloat = 64
        static let minimumLabeledHeaderActionWidth: CGFloat = 44
        static let maximumToolbarInset: CGFloat = 64
        static let maximumTransportCenterOffset: CGFloat = 4
        static let maximumControlRowEdgeOffset: CGFloat = 2
        static let playerControlRowSpacing: CGFloat = 12
        static let maximumControlRowSpacingOffset: CGFloat = 2
        static let maximumTopBarHeightDifference: CGFloat = 1
        static let maximumTopBarLeadingInsetDifference: CGFloat = 2
        static let maximumWindowControlVerticalOffset: CGFloat = 2
        static let minimumBrandControlGap: CGFloat = 8
        static let maximumBrandControlGap: CGFloat = 16
        static let maximumWindowEdgeOffset: CGFloat = 2
        static let fullScreenTransitionTimeout: TimeInterval = 5
    }

    private enum LifecycleExpectation {
        static let windowTransitionTimeout: TimeInterval = 5
        static let processTerminationObservationTimeout: TimeInterval = 1
        static let finderBundleIdentifier = "com.apple.finder"
    }

    @MainActor
    func testApplicationLaunchesWithAWindow() {
        let application = launchEmptyLibrary()

        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 5))
        let sidebar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.library-sidebar")
            .firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        let addFolderButton = application.buttons[
            "muralume.add-folder"
        ].firstMatch
        XCTAssertTrue(
            addFolderButton.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(addFolderButton.label, "Add Folder")
        XCTAssertGreaterThanOrEqual(
            addFolderButton.frame.width,
            LayoutExpectation.minimumLabeledHeaderActionWidth
        )
        XCTAssertEqual(
            application.buttons.matching(
                identifier: "muralume.add-folder"
            ).count,
            1
        )
        XCTAssertTrue(
            sidebar.frame.contains(
                CGPoint(
                    x: addFolderButton.frame.midX,
                    y: addFolderButton.frame.midY
                )
            )
        )
        XCTAssertLessThanOrEqual(
            addFolderButton.frame.minY - sidebar.frame.minY,
            LayoutExpectation.maximumSidebarHeaderTopInset
        )
        XCTAssertLessThanOrEqual(
            sidebar.frame.maxX - addFolderButton.frame.maxX,
            LayoutExpectation.maximumSidebarHeaderTrailingInset
        )

        let settingsButton = application.buttons[
            "muralume.open-settings"
        ].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        assertTopTrailing(
            settingsButton,
            in: application.windows.firstMatch
        )
        XCTAssertTrue(application.staticTexts["Playlist"].exists)
        XCTAssertTrue(application.sliders["Playback Position"].exists)
        assertApplicationMenuStructure(application)

        let playbackOrderButton = application.buttons[
            "muralume.playback-order"
        ]
        XCTAssertTrue(playbackOrderButton.waitForExistence(timeout: 5))
        XCTAssertEqual(playbackOrderButton.label, "In Order")
        XCTAssertFalse(playbackOrderButton.isSelected)
        playbackOrderButton.click()
        XCTAssertEqual(playbackOrderButton.label, "Shuffle")
        XCTAssertTrue(playbackOrderButton.isSelected)

        let videoViewport = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.video-viewport")
            .firstMatch
        let transportControls = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-transport-controls")
            .firstMatch
        XCTAssertTrue(videoViewport.waitForExistence(timeout: 5))
        XCTAssertTrue(transportControls.waitForExistence(timeout: 5))
        XCTAssertEqual(
            videoViewport.frame.minY,
            application.windows.firstMatch.frame.minY,
            accuracy: LayoutExpectation.maximumWindowEdgeOffset
        )
        XCTAssertEqual(
            transportControls.frame.midX,
            videoViewport.frame.midX,
            accuracy: LayoutExpectation.maximumTransportCenterOffset
        )

        let playbackTimeline = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.playback-timeline")
            .firstMatch
        let playerControlBar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-control-bar")
            .firstMatch
        XCTAssertTrue(playbackTimeline.waitForExistence(timeout: 5))
        XCTAssertTrue(playerControlBar.waitForExistence(timeout: 5))
        XCTAssertEqual(
            playbackTimeline.frame.minX,
            playerControlBar.frame.minX,
            accuracy: LayoutExpectation.maximumControlRowEdgeOffset
        )
        XCTAssertEqual(
            playbackTimeline.frame.maxX,
            playerControlBar.frame.maxX,
            accuracy: LayoutExpectation.maximumControlRowEdgeOffset
        )
        XCTAssertEqual(
            playerControlBar.frame.minY - playbackTimeline.frame.maxY,
            LayoutExpectation.playerControlRowSpacing,
            accuracy: LayoutExpectation.maximumControlRowSpacingOffset
        )

        let playlistToggle = application.buttons[
            "muralume.playlist-toggle"
        ]
        XCTAssertTrue(playlistToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(playlistToggle.isSelected)
        XCTAssertEqual(playlistToggle.label, "Hide Playlist")
        playlistToggle.click()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 2))
        XCTAssertEqual(playlistToggle.label, "Show Playlist")
        playlistToggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        XCTAssertEqual(
            application.buttons.matching(
                identifier: "muralume.add-folder"
            ).count,
            1
        )

        let playerControls = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-controls")
            .firstMatch
        XCTAssertEqual(
            playerControls
                .descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "label == %@",
                        "Desktop Fit"
                    )
                )
                .count,
            0
        )
    }

    @MainActor
    func testFullScreenReusesPlayerTopBar() {
        let application = launchEmptyLibrary()
        let window = application.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let playerTopBar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-top-bar")
            .firstMatch
        let windowedSettingsButton = application.buttons[
            "muralume.open-settings"
        ].firstMatch
        let windowedBrandMark = playerTopBar
            .descendants(matching: .any)
            .matching(identifier: "muralume.brand-mark")
            .firstMatch
        let closeWindowButton = application.buttons[
            "muralume.window-close"
        ].firstMatch
        let minimizeWindowButton = application.buttons[
            "muralume.window-minimize"
        ].firstMatch
        let fullScreenWindowButton = application.buttons[
            "muralume.window-fullscreen"
        ].firstMatch
        XCTAssertTrue(playerTopBar.waitForExistence(timeout: 5))
        XCTAssertTrue(windowedSettingsButton.waitForExistence(timeout: 5))
        XCTAssertTrue(windowedBrandMark.waitForExistence(timeout: 5))
        XCTAssertTrue(closeWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(minimizeWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(fullScreenWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closeWindowButton.isEnabled)
        XCTAssertTrue(minimizeWindowButton.isEnabled)
        XCTAssertTrue(fullScreenWindowButton.isEnabled)
        assertTopTrailing(windowedSettingsButton, in: window)
        assertWindowControlsAlignWithBrand(
            closeButton: closeWindowButton,
            fullScreenButton: fullScreenWindowButton,
            brand: windowedBrandMark
        )
        let windowedTopBarHeight = playerTopBar.frame.height
        let windowedBrandLeadingInset =
            windowedBrandMark.frame.minX - window.frame.minX

        let windowedFrame = window.frame
        application.typeKey("f", modifierFlags: [])
        let fullScreenTransition = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "frame != %@",
                NSValue(rect: windowedFrame)
            ),
            object: window
        )
        let transitionResult = XCTWaiter.wait(
            for: [fullScreenTransition],
            timeout: LayoutExpectation.fullScreenTransitionTimeout
        )
        XCTAssertEqual(transitionResult, .completed)

        XCTAssertTrue(playerTopBar.waitForExistence(timeout: 5))
        let fullScreenSettingsButton = playerTopBar
            .descendants(matching: .button)
            .matching(identifier: "muralume.open-settings")
            .firstMatch
        let fullScreenBrandMark = playerTopBar
            .descendants(matching: .any)
            .matching(identifier: "muralume.brand-mark")
            .firstMatch
        XCTAssertTrue(
            fullScreenSettingsButton.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(fullScreenBrandMark.waitForExistence(timeout: 5))
        XCTAssertTrue(closeWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(minimizeWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(fullScreenWindowButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closeWindowButton.isEnabled)
        XCTAssertFalse(minimizeWindowButton.isEnabled)
        XCTAssertTrue(fullScreenWindowButton.isEnabled)
        let windowMenu = application.menuBars.menuBarItems["Window"]
        windowMenu.click()
        XCTAssertFalse(application.menuItems["Minimize"].isEnabled)
        XCTAssertFalse(application.menuItems["Zoom"].isEnabled)
        application.typeKey(.escape, modifierFlags: [])
        assertTopTrailing(
            fullScreenSettingsButton,
            in: window
        )
        assertWindowControlsAlignWithBrand(
            closeButton: closeWindowButton,
            fullScreenButton: fullScreenWindowButton,
            brand: fullScreenBrandMark
        )
        XCTAssertEqual(
            playerTopBar.frame.height,
            windowedTopBarHeight,
            accuracy: LayoutExpectation.maximumTopBarHeightDifference
        )
        XCTAssertEqual(
            fullScreenBrandMark.frame.minX - window.frame.minX,
            windowedBrandLeadingInset,
            accuracy: LayoutExpectation
                .maximumTopBarLeadingInsetDifference
        )
    }

    @MainActor
    func testSoftClosePreservesStateAndRestoresSingleMainWindow() {
        let application = launchEmptyLibrary()
        let mainWindow = application.windows.firstMatch
        let didLaunchMainWindow = mainWindow.waitForExistence(
            timeout: LifecycleExpectation.windowTransitionTimeout
        )
        XCTAssertTrue(didLaunchMainWindow)
        guard didLaunchMainWindow else {
            return
        }
        XCTAssertEqual(application.windows.count, 1)
        let initialWindowFrame = mainWindow.frame
        let launchedApplicationState = application.state
        XCTAssertNotEqual(launchedApplicationState, .notRunning)

        let playbackOrderButton = application.buttons[
            "muralume.playback-order"
        ]
        XCTAssertTrue(
            playbackOrderButton.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        playbackOrderButton.click()
        XCTAssertEqual(playbackOrderButton.label, "Shuffle")
        XCTAssertTrue(playbackOrderButton.isSelected)

        let playlistToggle = application.buttons[
            "muralume.playlist-toggle"
        ]
        XCTAssertTrue(
            playlistToggle.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        playlistToggle.click()
        XCTAssertEqual(playlistToggle.label, "Show Playlist")
        XCTAssertFalse(playlistToggle.isSelected)

        application.typeKey("w", modifierFlags: .command)

        let didHideMainWindow = mainWindow.waitForNonExistence(
            timeout: LifecycleExpectation.windowTransitionTimeout
        )
        XCTAssertTrue(didHideMainWindow)
        guard didHideMainWindow else {
            return
        }
        XCTAssertEqual(application.windows.count, 0)
        XCTAssertFalse(
            application.wait(
                for: .notRunning,
                timeout: LifecycleExpectation
                    .processTerminationObservationTimeout
            )
        )
        assertCanonicalTopLevelMenu(application)
        let hiddenWindowMenu =
            application.menuBars.menuBarItems["Window"]
        hiddenWindowMenu.click()
        XCTAssertFalse(
            application.menuItems["Bring All to Front"].isEnabled
        )
        application.typeKey(.escape, modifierFlags: [])
        let hiddenWindowActionsMenu =
            application.menuBars.menuBarItems["Actions"]
        hiddenWindowActionsMenu.click()
        XCTAssertFalse(
            application.menuItems["Add Folder"].isEnabled
        )
        XCTAssertFalse(
            application.menuItems["Toggle Full Screen"].isEnabled
        )
        application.typeKey(.escape, modifierFlags: [])

        let finder = XCUIApplication(
            bundleIdentifier: LifecycleExpectation.finderBundleIdentifier
        )
        finder.activate()
        XCTAssertTrue(
            application.wait(
                for: .runningBackground,
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )

        application.activate()

        XCTAssertTrue(
            application.wait(
                for: .runningForeground,
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        let didRestoreMainWindow = mainWindow.waitForExistence(
            timeout: LifecycleExpectation.windowTransitionTimeout
        )
        XCTAssertTrue(didRestoreMainWindow)
        guard didRestoreMainWindow else {
            return
        }
        XCTAssertEqual(application.windows.count, 1)
        XCTAssertEqual(mainWindow.frame, initialWindowFrame)
        XCTAssertEqual(playbackOrderButton.label, "Shuffle")
        XCTAssertTrue(playbackOrderButton.isSelected)
        XCTAssertEqual(playlistToggle.label, "Show Playlist")
        XCTAssertFalse(playlistToggle.isSelected)

        let closeWindowButton = application.buttons[
            "muralume.window-close"
        ].firstMatch
        XCTAssertTrue(
            closeWindowButton.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        closeWindowButton.click()

        XCTAssertTrue(
            mainWindow.waitForNonExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertFalse(
            application.wait(
                for: .notRunning,
                timeout: LifecycleExpectation
                    .processTerminationObservationTimeout
            )
        )
        finder.activate()
        XCTAssertTrue(
            application.wait(
                for: .runningBackground,
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        application.activate()
        XCTAssertTrue(
            application.wait(
                for: .runningForeground,
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(
            mainWindow.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertEqual(application.windows.count, 1)
        XCTAssertEqual(playbackOrderButton.label, "Shuffle")
        XCTAssertFalse(playlistToggle.isSelected)
    }

    @MainActor
    func testCommandWClosesSettingsWithoutDismissingMainWindow() {
        let application = launchEmptyLibrary()
        let mainWindow = application.windows.firstMatch
        XCTAssertTrue(
            mainWindow.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        let mainWindowFrame = mainWindow.frame
        let settingsButton = application.buttons[
            "muralume.open-settings"
        ].firstMatch
        XCTAssertTrue(
            settingsButton.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )

        settingsButton.click()
        let settingsView = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.settings-view")
            .firstMatch
        XCTAssertTrue(
            settingsView.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )

        let actionsMenu = application.menuBars.menuBarItems["Actions"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 5))
        actionsMenu.click()
        let fullScreenItem = application.menuItems["Toggle Full Screen"]
        XCTAssertTrue(fullScreenItem.exists)
        XCTAssertFalse(fullScreenItem.isEnabled)
        application.typeKey(.escape, modifierFlags: [])

        application.typeKey("f", modifierFlags: [])
        let unexpectedFullScreenTransition = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "frame != %@",
                NSValue(rect: mainWindowFrame)
            ),
            object: mainWindow
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [unexpectedFullScreenTransition],
                timeout: LifecycleExpectation
                    .processTerminationObservationTimeout
            ),
            .timedOut
        )

        application.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            settingsView.waitForNonExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(mainWindow.exists)
        XCTAssertEqual(application.windows.count, 1)
    }

    @MainActor
    private func launchEmptyLibrary() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments += [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-ApplePersistenceIgnoreState",
            "YES",
            "-settings.app-language",
            "en",
            "-media-library.root-bookmarks",
            ""
        ]
        application.launch()
        return application
    }

    private func assertTopTrailing(
        _ element: XCUIElement,
        in window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            window.frame.maxX - element.frame.maxX,
            LayoutExpectation.maximumToolbarInset,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            element.frame.minY - window.frame.minY,
            LayoutExpectation.maximumToolbarInset,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertApplicationMenuStructure(
        _ application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertCanonicalTopLevelMenu(
            application,
            file: file,
            line: line
        )

        let actionsMenu = application.menuBars.menuBarItems["Actions"]
        actionsMenu.click()
        let disabledPlaybackItems = [
            "Play",
            "Back 10 seconds",
            "Forward 10 seconds",
            "Previous Video",
            "Next Video",
            "Volume Up",
            "Volume Down",
            "Mute"
        ]
        for itemTitle in disabledPlaybackItems {
            let item = application.menuItems[itemTitle]
            XCTAssertTrue(item.exists, file: file, line: line)
            XCTAssertFalse(item.isEnabled, file: file, line: line)
        }

        let addFolderItem = application.menuItems["Add Folder"]
        XCTAssertTrue(addFolderItem.exists, file: file, line: line)
        XCTAssertTrue(addFolderItem.isEnabled, file: file, line: line)

        let fullScreenItem = application.menuItems["Toggle Full Screen"]
        XCTAssertTrue(fullScreenItem.exists, file: file, line: line)
        XCTAssertTrue(fullScreenItem.isEnabled, file: file, line: line)
        application.typeKey(.escape, modifierFlags: [])

        let appMenu = application.menuBars.menuBarItems["Muralume"]
        appMenu.click()
        XCTAssertTrue(
            application.menuItems["Settings…"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(
            application.menuItems["Settings"].exists,
            file: file,
            line: line
        )
        application.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func assertCanonicalTopLevelMenu(
        _ application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            application.menuBars.menuBarItems["File"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(
            application.menuBars.menuBarItems["Edit"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(
            application.menuBars.menuBarItems["Format"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(
            application.menuBars.menuBarItems["View"].exists,
            file: file,
            line: line
        )

        let appMenu = application.menuBars.menuBarItems["Muralume"]
        XCTAssertTrue(
            appMenu.waitForExistence(timeout: 5),
            file: file,
            line: line
        )
        let actionsMenu = application.menuBars.menuBarItems["Actions"]
        XCTAssertTrue(
            actionsMenu.waitForExistence(timeout: 5),
            file: file,
            line: line
        )
        let windowMenu = application.menuBars.menuBarItems["Window"]
        XCTAssertTrue(
            windowMenu.waitForExistence(timeout: 5),
            file: file,
            line: line
        )
        let helpMenu = application.menuBars.menuBarItems["Help"]
        XCTAssertTrue(
            helpMenu.waitForExistence(timeout: 5),
            file: file,
            line: line
        )
    }

    private func assertWindowControlsAlignWithBrand(
        closeButton: XCUIElement,
        fullScreenButton: XCUIElement,
        brand: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            closeButton.frame.midY,
            brand.frame.midY,
            accuracy: LayoutExpectation.maximumWindowControlVerticalOffset,
            file: file,
            line: line
        )
        let brandControlGap =
            brand.frame.minX - fullScreenButton.frame.maxX
        XCTAssertGreaterThanOrEqual(
            brandControlGap,
            LayoutExpectation.minimumBrandControlGap,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            brandControlGap,
            LayoutExpectation.maximumBrandControlGap,
            file: file,
            line: line
        )
    }
}
