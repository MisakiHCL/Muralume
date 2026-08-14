import XCTest

final class MuralumeLaunchTests: XCTestCase {
    private enum SidebarAccessibilityIdentifier {
        static let titleMenu = "muralume.library-title"
        static let retiredModePicker =
            "muralume.library-sidebar.mode-picker"
        static let mediaLibraryMenuItem =
            "muralume.library-section.media-library"
        static let playlistsMenuItem =
            "muralume.library-section.playlists"
        static let playQueueMenuItem =
            "muralume.library-section.play-queue"
        static let playlistOverview = "muralume.playlists-overview"
        static let newPlaylistButton = "muralume.playlist-new"
        static let playlistNameField = "muralume.playlist-name"
        static let librarySearchField = "muralume.library-search"
        static let librarySummary = "muralume.library-summary"
    }

    private enum SidebarText {
        static let mediaLibrary = "Media Library"
        static let playlists = "Playlists"
        static let playQueue = "Play Queue"
        static let navigation =
            "Switch between Media Library, Playlists, and Play Queue"
        static let orderRequirement =
            "Sidebar destinations must remain ordered as Media Library, "
            + "Playlists, and Play Queue."
    }

    private enum LayoutExpectation {
        static let maximumSidebarHeaderTopInset: CGFloat = 80
        static let maximumSidebarHeaderTrailingInset: CGFloat = 64
        static let headerIconActionSize: CGFloat = 36
        static let sidebarStatusBarHeight: CGFloat = 32
        static let maximumAdjacentElementOffset: CGFloat = 1
        static let minimumSidebarTitleMenuHeight: CGFloat = 36
        static let sidebarTitleMenuHitInset: CGFloat = 2
        static let maximumControlSizeOffset: CGFloat = 1
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
        static let minimumSidePanelInset: CGFloat = 16
        // Accessibility frames can land on half-point screen coordinates.
        static let accessibilityCoordinateTolerance: CGFloat = 0.5
        static let maximumSidePanelInsetOffset: CGFloat = 2
        static let maximumWindowEdgeOffset: CGFloat = 2
        static let maximumSidebarTitleHorizontalOffset: CGFloat = 1
        static let fullScreenTransitionTimeout: TimeInterval = 5
        static let windowZoomFrameTolerance: CGFloat = 2
    }

    private enum LifecycleExpectation {
        static let windowTransitionTimeout: TimeInterval = 5
        static let processTerminationObservationTimeout: TimeInterval = 1
        static let finderBundleIdentifier = "com.apple.finder"
    }

    @MainActor
    func testMediaPickerShowsConcisePrompt() {
        let application = launchEmptyLibrary()
        let addMediaButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.add-media")
            .firstMatch

        XCTAssertTrue(addMediaButton.waitForExistence(timeout: 5))
        addMediaButton.click()

        let mediaPicker = application.dialogs.firstMatch
        XCTAssertTrue(mediaPicker.waitForExistence(timeout: 2))
        XCTAssertTrue(
            mediaPicker.staticTexts["Choose videos or folders."]
                .waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testEmptyLibrarySummaryUsesCompactSingleLine() {
        let application = launchEmptyLibrary()
        let addMediaButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.add-media")
            .firstMatch
        let librarySummary = application
            .descendants(matching: .any)
            .matching(
                identifier: SidebarAccessibilityIdentifier.librarySummary
            )
            .firstMatch

        XCTAssertTrue(addMediaButton.waitForExistence(timeout: 5))
        XCTAssertTrue(librarySummary.waitForExistence(timeout: 5))
        XCTAssertEqual(
            librarySummary.label,
            "0 videos, 0 media sources"
        )
        XCTAssertLessThanOrEqual(
            librarySummary.frame.height,
            LayoutExpectation.sidebarStatusBarHeight
        )
        XCTAssertEqual(
            librarySummary.frame.midY - addMediaButton.frame.maxY,
            LayoutExpectation.sidebarStatusBarHeight / 2,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
    }

    @MainActor
    func testSearchOnlyFocusesAfterExplicitFindCommand() {
        let application = launchEmptyLibrary()
        let searchField = application.textFields[
            SidebarAccessibilityIdentifier.librarySearchField
        ]

        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertEqual(
            application.textFields.matching(
                NSPredicate(
                    format: "identifier == %@ AND hasKeyboardFocus == false",
                    SidebarAccessibilityIdentifier.librarySearchField
                )
            ).count,
            1
        )

        let sidebarToggle = application.buttons[
            "muralume.media-library-toggle"
        ]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 2))
        sidebarToggle.click()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 2))
        sidebarToggle.click()
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertEqual(
            application.textFields.matching(
                NSPredicate(
                    format: "identifier == %@ AND hasKeyboardFocus == false",
                    SidebarAccessibilityIdentifier.librarySearchField
                )
            ).count,
            1
        )

        let titleMenu = application
            .descendants(matching: .any)
            .matching(identifier: SidebarAccessibilityIdentifier.titleMenu)
            .firstMatch
        titleMenu.click()
        let playlistsMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playlistsMenuItem
        ]
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        playlistsMenuItem.click()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 2))

        application.typeKey("f", modifierFlags: .command)

        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = expectation(
            for: focused,
            evaluatedWith: searchField
        )
        wait(for: [focusExpectation], timeout: 2)
    }

    @MainActor
    func testPlaylistNameEditorCancelsWhenClickingOutside() {
        let application = launchEmptyLibrary()
        let titleMenu = application
            .descendants(matching: .any)
            .matching(identifier: SidebarAccessibilityIdentifier.titleMenu)
            .firstMatch
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5))
        titleMenu.click()
        let playlistsMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playlistsMenuItem
        ]
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        playlistsMenuItem.click()

        let newPlaylistButton = application.buttons[
            SidebarAccessibilityIdentifier.newPlaylistButton
        ]
        XCTAssertTrue(newPlaylistButton.waitForExistence(timeout: 2))
        newPlaylistButton.click()

        let nameField = application.textFields[
            SidebarAccessibilityIdentifier.playlistNameField
        ]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = expectation(
            for: focused,
            evaluatedWith: nameField
        )
        wait(for: [focusExpectation], timeout: 2)
        application.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .click()

        XCTAssertTrue(nameField.waitForNonExistence(timeout: 2))
        XCTAssertTrue(
            application
                .descendants(matching: .any)
                .matching(
                    identifier:
                        SidebarAccessibilityIdentifier.playlistOverview
                )
                .firstMatch
                .exists
        )
    }

    @MainActor
    func testSidebarTitleMenuUsesStablePopupSpacing() {
        let application = launchEmptyLibrary()
        let titleMenu = application
            .descendants(matching: .any)
            .matching(identifier: SidebarAccessibilityIdentifier.titleMenu)
            .firstMatch

        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5))
        titleMenu.click()

        let mediaLibraryMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.mediaLibraryMenuItem
        ]
        let playlistsMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playlistsMenuItem
        ]
        let nowPlayingMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playQueueMenuItem
        ]
        XCTAssertTrue(mediaLibraryMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(nowPlayingMenuItem.waitForExistence(timeout: 2))
        let menuItems = [
            mediaLibraryMenuItem,
            playlistsMenuItem,
            nowPlayingMenuItem
        ]
        assertSidebarMenuOrder(menuItems)
        let libraryTriggerFrame = titleMenu.frame
        let libraryPopupFrame = application.menus.firstMatch.frame
        let libraryMenuItemFrames = menuItems.map(\.frame)
        nowPlayingMenuItem.click()

        titleMenu.click()
        XCTAssertTrue(mediaLibraryMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(nowPlayingMenuItem.waitForExistence(timeout: 2))
        assertSidebarMenuOrder(menuItems)
        let nowPlayingTriggerFrame = titleMenu.frame
        let nowPlayingPopupFrame = application.menus.firstMatch.frame
        XCTAssertEqual(
            nowPlayingTriggerFrame.minY,
            libraryTriggerFrame.minY,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            nowPlayingTriggerFrame.height,
            libraryTriggerFrame.height,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            nowPlayingPopupFrame.minY - nowPlayingTriggerFrame.maxY,
            libraryPopupFrame.minY - libraryTriggerFrame.maxY,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            nowPlayingPopupFrame.height,
            libraryPopupFrame.height,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        assertSidebarMenuItemFrames(
            menuItems.map(\.frame),
            equalTo: libraryMenuItemFrames
        )
        playlistsMenuItem.click()

        let playlistOverview = application
            .descendants(matching: .any)
            .matching(
                identifier: SidebarAccessibilityIdentifier.playlistOverview
            )
            .firstMatch
        XCTAssertTrue(playlistOverview.waitForExistence(timeout: 2))
        let playlistsTitleMenu = application
            .descendants(matching: .any)
            .matching(identifier: SidebarAccessibilityIdentifier.titleMenu)
            .firstMatch
        XCTAssertTrue(playlistsTitleMenu.waitForExistence(timeout: 2))
        XCTAssertEqual(playlistsTitleMenu.label, SidebarText.navigation)
        XCTAssertEqual(
            playlistsTitleMenu.value as? String,
            SidebarText.playlists
        )
        playlistsTitleMenu.click()
        XCTAssertTrue(mediaLibraryMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(nowPlayingMenuItem.waitForExistence(timeout: 2))
        assertSidebarMenuOrder(menuItems)
        let playlistsTriggerFrame = playlistsTitleMenu.frame
        let playlistsPopupFrame = application.menus.firstMatch.frame
        XCTAssertEqual(
            playlistsTriggerFrame.minY,
            libraryTriggerFrame.minY,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            playlistsTriggerFrame.height,
            libraryTriggerFrame.height,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            playlistsPopupFrame.minY - playlistsTriggerFrame.maxY,
            libraryPopupFrame.minY - libraryTriggerFrame.maxY,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            playlistsPopupFrame.height,
            libraryPopupFrame.height,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        assertSidebarMenuItemFrames(
            menuItems.map(\.frame),
            equalTo: libraryMenuItemFrames
        )
        mediaLibraryMenuItem.click()
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

        let addMediaButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.add-media")
            .firstMatch
        XCTAssertTrue(
            addMediaButton.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(addMediaButton.label, "Add Media…")
        XCTAssertEqual(
            addMediaButton.frame.width,
            LayoutExpectation.headerIconActionSize,
            accuracy: LayoutExpectation.maximumControlSizeOffset
        )
        XCTAssertEqual(
            addMediaButton.frame.height,
            LayoutExpectation.headerIconActionSize,
            accuracy: LayoutExpectation.maximumControlSizeOffset
        )
        XCTAssertEqual(
            application
                .descendants(matching: .any)
                .matching(identifier: "muralume.add-media")
                .count,
            1
        )
        XCTAssertTrue(
            sidebar.frame.contains(
                CGPoint(
                    x: addMediaButton.frame.midX,
                    y: addMediaButton.frame.midY
                )
            )
        )
        XCTAssertLessThanOrEqual(
            addMediaButton.frame.minY - sidebar.frame.minY,
            LayoutExpectation.maximumSidebarHeaderTopInset
        )
        XCTAssertLessThanOrEqual(
            sidebar.frame.maxX - addMediaButton.frame.maxX,
            LayoutExpectation.maximumSidebarHeaderTrailingInset
        )
        addMediaButton.click()
        XCTAssertTrue(
            application.dialogs.firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertFalse(application.menuItems["Add Video…"].exists)
        XCTAssertFalse(application.menuItems["Add Folder…"].exists)
        application.typeKey(.escape, modifierFlags: [])

        let settingsButton = application.buttons[
            "muralume.open-settings"
        ].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        assertTopTrailing(
            settingsButton,
            in: application.windows.firstMatch
        )
        let sidebarTitleMenu = application
            .descendants(matching: .any)
            .matching(
                identifier: SidebarAccessibilityIdentifier.titleMenu
            )
            .firstMatch
        XCTAssertTrue(sidebarTitleMenu.waitForExistence(timeout: 5))
        XCTAssertEqual(sidebarTitleMenu.elementType, .menuButton)
        XCTAssertTrue(sidebarTitleMenu.isHittable)
        XCTAssertGreaterThanOrEqual(
            sidebarTitleMenu.frame.height,
            LayoutExpectation.minimumSidebarTitleMenuHeight
        )
        XCTAssertEqual(
            sidebarTitleMenu.label,
            SidebarText.navigation
        )
        XCTAssertEqual(
            sidebarTitleMenu.value as? String,
            SidebarText.mediaLibrary
        )
        XCTAssertEqual(
            application
                .descendants(matching: .any)
                .matching(
                    identifier: SidebarAccessibilityIdentifier
                        .retiredModePicker
                )
                .count,
            0
        )
        let mediaLibraryTitleX = sidebarTitleMenu.frame.minX

        sidebarTitleMenu
            .coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0)
            )
            .withOffset(
                CGVector(
                    dx: 0,
                    dy: LayoutExpectation.sidebarTitleMenuHitInset
                )
            )
            .click()
        let mediaLibraryMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.mediaLibraryMenuItem
        ]
        let playlistsMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playlistsMenuItem
        ]
        let nowPlayingMenuItem = application.menuItems[
            SidebarAccessibilityIdentifier.playQueueMenuItem
        ]
        XCTAssertTrue(mediaLibraryMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(nowPlayingMenuItem.waitForExistence(timeout: 2))
        let sidebarMenuItems = [
            mediaLibraryMenuItem,
            playlistsMenuItem,
            nowPlayingMenuItem
        ]
        assertSidebarMenuOrder(sidebarMenuItems)
        let librarySelectionTriggerFrame = sidebarTitleMenu.frame
        let librarySelectionMenuItemFrames = sidebarMenuItems.map(\.frame)
        nowPlayingMenuItem.click()

        XCTAssertEqual(
            sidebarTitleMenu.value as? String,
            SidebarText.playQueue
        )
        XCTAssertEqual(
            sidebarTitleMenu.frame.minX,
            mediaLibraryTitleX,
            accuracy: LayoutExpectation.maximumSidebarTitleHorizontalOffset
        )
        XCTAssertTrue(
            application.staticTexts["The play queue is empty"]
                .waitForExistence(timeout: 5)
        )

        sidebarTitleMenu
            .coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 1)
            )
            .withOffset(
                CGVector(
                    dx: 0,
                    dy: -LayoutExpectation.sidebarTitleMenuHitInset
                )
            )
            .click()
        XCTAssertTrue(mediaLibraryMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(playlistsMenuItem.waitForExistence(timeout: 2))
        XCTAssertTrue(nowPlayingMenuItem.waitForExistence(timeout: 2))
        assertSidebarMenuOrder(sidebarMenuItems)
        XCTAssertEqual(
            sidebarTitleMenu.frame.minY,
            librarySelectionTriggerFrame.minY,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        XCTAssertEqual(
            sidebarTitleMenu.frame.height,
            librarySelectionTriggerFrame.height,
            accuracy: LayoutExpectation.maximumAdjacentElementOffset
        )
        assertSidebarMenuItemFrames(
            sidebarMenuItems.map(\.frame),
            equalTo: librarySelectionMenuItemFrames
        )
        mediaLibraryMenuItem.click()
        XCTAssertEqual(
            sidebarTitleMenu.value as? String,
            SidebarText.mediaLibrary
        )
        XCTAssertTrue(application.sliders["Playback Position"].exists)
        assertApplicationMenuStructure(application)

        let playbackModeButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.playback-mode")
            .firstMatch
        XCTAssertTrue(playbackModeButton.waitForExistence(timeout: 5))
        XCTAssertEqual(playbackModeButton.label, "Playback Mode")
        XCTAssertEqual(
            playbackModeButton.value as? String,
            "Shuffle and Repeat"
        )
        playbackModeButton.click()
        let orderedPlaybackMode = application.menuItems["Repeat in Order"]
        XCTAssertTrue(orderedPlaybackMode.waitForExistence(timeout: 2))
        orderedPlaybackMode.click()
        XCTAssertEqual(
            playbackModeButton.value as? String,
            "Repeat in Order"
        )

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

        let mediaLibraryToggle = application.buttons[
            "muralume.media-library-toggle"
        ]
        XCTAssertTrue(mediaLibraryToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(mediaLibraryToggle.isSelected)
        XCTAssertEqual(mediaLibraryToggle.label, "Hide Media Library")
        mediaLibraryToggle.click()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 2))
        XCTAssertEqual(mediaLibraryToggle.label, "Show Media Library")
        mediaLibraryToggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        XCTAssertEqual(
            application
                .descendants(matching: .any)
                .matching(identifier: "muralume.add-media")
                .count,
            1
        )

        let playerControls = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-controls")
            .firstMatch
        XCTAssertTrue(playerControls.waitForExistence(timeout: 5))
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
    func testDoubleClickingPlayerTopBarZoomsAndRestoresWindow() {
        let application = launchEmptyLibrary()
        let window = application.windows.firstMatch
        let playerTopBar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-top-bar")
            .firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(playerTopBar.waitForExistence(timeout: 5))
        let initialFrame = window.frame

        playerTopBar.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).doubleClick()

        let zoomExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "frame != %@",
                NSValue(rect: initialFrame)
            ),
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [zoomExpectation],
                timeout: LayoutExpectation.fullScreenTransitionTimeout
            ),
            .completed
        )
        XCTAssertEqual(application.windows.count, 1)
        XCTAssertTrue(
            application.buttons["muralume.window-minimize"].isEnabled
        )

        playerTopBar.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).doubleClick()

        let restoreExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let window = object as? XCUIElement else {
                    return false
                }
                return Self.framesAreEqual(
                    window.frame,
                    initialFrame,
                    tolerance: LayoutExpectation.windowZoomFrameTolerance
                )
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [restoreExpectation],
                timeout: LayoutExpectation.fullScreenTransitionTimeout
            ),
            .completed
        )
        XCTAssertEqual(application.windows.count, 1)
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

        let playbackModeButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.playback-mode")
            .firstMatch
        XCTAssertTrue(
            playbackModeButton.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        playbackModeButton.click()
        let orderedPlaybackMode = application.menuItems["Repeat in Order"]
        XCTAssertTrue(
            orderedPlaybackMode.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        orderedPlaybackMode.click()
        XCTAssertEqual(
            playbackModeButton.value as? String,
            "Repeat in Order"
        )

        let mediaLibraryToggle = application.buttons[
            "muralume.media-library-toggle"
        ]
        XCTAssertTrue(
            mediaLibraryToggle.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        mediaLibraryToggle.click()
        XCTAssertEqual(mediaLibraryToggle.label, "Show Media Library")
        XCTAssertFalse(mediaLibraryToggle.isSelected)

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
            application.menuItems["Add Media…"].isEnabled
        )
        XCTAssertFalse(application.menuItems["Edit"].isEnabled)
        XCTAssertFalse(
            application.menuItems["Set as Dynamic Desktop"].isEnabled
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
        XCTAssertEqual(
            playbackModeButton.value as? String,
            "Repeat in Order"
        )
        XCTAssertEqual(mediaLibraryToggle.label, "Show Media Library")
        XCTAssertFalse(mediaLibraryToggle.isSelected)

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
        XCTAssertEqual(
            playbackModeButton.value as? String,
            "Repeat in Order"
        )
        XCTAssertFalse(mediaLibraryToggle.isSelected)
    }

    @MainActor
    func testSettingsUsesOneMainWindowAndBlocksPlayerCommands() {
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
        XCTAssertEqual(application.windows.count, 1)
        XCTAssertTrue(mainWindow.frame.contains(settingsView.frame))
        XCTAssertEqual(
            application
                .descendants(matching: .any)
                .matching(identifier: "muralume.settings-view")
                .count,
            1
        )

        let languagePicker = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.language-picker")
            .firstMatch
        let closeSettingsButton = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.settings-close")
            .firstMatch
        XCTAssertTrue(
            languagePicker.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(
            closeSettingsButton.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        let languageRow = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.settings-row.language")
            .firstMatch
        let launchAtLoginRow = application
            .descendants(matching: .any)
            .matching(
                identifier: "muralume.settings-row.launch-at-login"
            )
            .firstMatch
        let launchAtLoginCheckbox = application
            .checkBoxes["muralume.launch-at-login.checkbox"]
            .firstMatch
        XCTAssertTrue(
            languageRow.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(
            launchAtLoginRow.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(
            launchAtLoginCheckbox.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertEqual(
            launchAtLoginCheckbox.label,
            "Launch at Login"
        )
        XCTAssertTrue(
            languageRow.frame.contains(
                CGPoint(
                    x: languagePicker.frame.midX,
                    y: languagePicker.frame.midY
                )
            )
        )
        XCTAssertTrue(
            launchAtLoginRow.frame.contains(
                CGPoint(
                    x: launchAtLoginCheckbox.frame.midX,
                    y: launchAtLoginCheckbox.frame.midY
                )
            )
        )
        assertSidePanelSpacing(
            settingsView,
            in: application,
            window: mainWindow
        )

        languagePicker.click()
        XCTAssertTrue(
            application.menuItems["Follow System"].waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsView.exists)

        let actionsMenu = application.menuBars.menuBarItems["Actions"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 5))
        actionsMenu.click()
        for itemTitle in [
            "Add Media…",
            "Edit",
            "Play",
            "Back 10 seconds",
            "Forward 10 seconds",
            "Previous Video",
            "Next Video",
            "Volume Up",
            "Volume Down",
            "Mute",
            "Set as Dynamic Desktop",
            "Toggle Full Screen"
        ] {
            let item = application.menuItems[itemTitle]
            XCTAssertTrue(item.exists, "\(itemTitle) should remain visible")
            XCTAssertFalse(
                item.isEnabled,
                "\(itemTitle) should be disabled behind Settings"
            )
        }
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

        application.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            settingsView.waitForNonExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
        XCTAssertTrue(mainWindow.exists)
        XCTAssertEqual(application.windows.count, 1)
        XCTAssertEqual(mainWindow.frame, mainWindowFrame)

        let sidebar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.library-sidebar")
            .firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )

        application.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            sidebar.waitForNonExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            )
        )
    }

    @MainActor
    private func assertSidebarMenuOrder(
        _ menuItems: [XCUIElement],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(menuItems.count, 3, file: file, line: line)
        guard menuItems.count == 3 else {
            return
        }

        for index in 0..<(menuItems.count - 1) {
            XCTAssertLessThan(
                menuItems[index].frame.minY,
                menuItems[index + 1].frame.minY,
                SidebarText.orderRequirement,
                file: file,
                line: line
            )
        }
    }

    private func assertSidebarMenuItemFrames(
        _ frames: [CGRect],
        equalTo expectedFrames: [CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            frames.count,
            expectedFrames.count,
            file: file,
            line: line
        )
        guard frames.count == expectedFrames.count else {
            return
        }

        for (frame, expectedFrame) in zip(frames, expectedFrames) {
            XCTAssertEqual(
                frame.minY,
                expectedFrame.minY,
                accuracy: LayoutExpectation.maximumAdjacentElementOffset,
                file: file,
                line: line
            )
            XCTAssertEqual(
                frame.height,
                expectedFrame.height,
                accuracy: LayoutExpectation.maximumAdjacentElementOffset,
                file: file,
                line: line
            )
        }
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
            "-settings.playback.volume",
            "1",
            "-settings.playback.is-muted",
            "false",
            "-settings.playback.restorable-volume",
            "1",
            "-settings.playback.rate",
            "1",
            "-settings.playback.order",
            "shuffled",
            "-media-library.source-records",
            "",
            "-media-library.root-bookmarks",
            ""
        ]
        application.launch()
        return application
    }

    @MainActor
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
    private func assertSidePanelSpacing(
        _ panelContent: XCUIElement,
        in application: XCUIApplication,
        window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let topBar = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-top-bar")
            .firstMatch
        let playerControls = application
            .descendants(matching: .any)
            .matching(identifier: "muralume.player-controls")
            .firstMatch
        XCTAssertTrue(
            topBar.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(
            playerControls.waitForExistence(
                timeout: LifecycleExpectation.windowTransitionTimeout
            ),
            file: file,
            line: line
        )

        let geometryExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let topInset =
                    panelContent.frame.minY - topBar.frame.maxY
                let trailingInset =
                    window.frame.maxX - panelContent.frame.maxX
                let bottomInset =
                    playerControls.frame.minY - panelContent.frame.maxY
                return topInset
                    + LayoutExpectation.accessibilityCoordinateTolerance
                    >= LayoutExpectation.minimumSidePanelInset
                    && abs(topInset - trailingInset)
                    <= LayoutExpectation.maximumSidePanelInsetOffset
                    && abs(topInset - bottomInset)
                    <= LayoutExpectation.maximumSidePanelInsetOffset
            },
            object: panelContent
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [geometryExpectation],
                timeout: LifecycleExpectation.windowTransitionTimeout
            ),
            .completed,
            file: file,
            line: line
        )
        let topInset =
            panelContent.frame.minY - topBar.frame.maxY
        XCTAssertGreaterThanOrEqual(
            topInset + LayoutExpectation.accessibilityCoordinateTolerance,
            LayoutExpectation.minimumSidePanelInset,
            file: file,
            line: line
        )
        XCTAssertEqual(
            window.frame.maxX - panelContent.frame.maxX,
            topInset,
            accuracy: LayoutExpectation.maximumSidePanelInsetOffset,
            file: file,
            line: line
        )
        XCTAssertEqual(
            playerControls.frame.minY - panelContent.frame.maxY,
            topInset,
            accuracy: LayoutExpectation.maximumSidePanelInsetOffset,
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
            "Set as Dynamic Desktop"
        ]
        for itemTitle in disabledPlaybackItems {
            let item = application.menuItems[itemTitle]
            XCTAssertTrue(item.exists, file: file, line: line)
            XCTAssertFalse(item.isEnabled, file: file, line: line)
        }

        let volumeUpItem = application.menuItems["Volume Up"]
        XCTAssertTrue(volumeUpItem.exists, file: file, line: line)
        XCTAssertFalse(volumeUpItem.isEnabled, file: file, line: line)

        for itemTitle in ["Volume Down", "Mute"] {
            let item = application.menuItems[itemTitle]
            XCTAssertTrue(item.exists, file: file, line: line)
            XCTAssertTrue(item.isEnabled, file: file, line: line)
        }

        let addMediaItem = application.menuItems["Add Media…"]
        XCTAssertTrue(addMediaItem.exists, file: file, line: line)
        XCTAssertTrue(addMediaItem.isEnabled, file: file, line: line)
        XCTAssertFalse(
            application.menuItems["Add Video…"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(
            application.menuItems["Add Folder…"].exists,
            file: file,
            line: line
        )

        let editItem = application.menuItems["Edit"]
        XCTAssertTrue(editItem.exists, file: file, line: line)
        XCTAssertFalse(editItem.isEnabled, file: file, line: line)

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

    @MainActor
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

    private static func framesAreEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
