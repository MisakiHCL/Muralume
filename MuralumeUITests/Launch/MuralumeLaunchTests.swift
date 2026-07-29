import XCTest

final class MuralumeLaunchTests: XCTestCase {
    private enum LayoutExpectation {
        static let maximumSidebarHeaderTopInset: CGFloat = 80
        static let maximumSidebarHeaderTrailingInset: CGFloat = 64
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
        let viewMenu = application.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let enterFullScreenItem = application.menuItems[
            "Enter Full Screen"
        ]
        XCTAssertTrue(enterFullScreenItem.waitForExistence(timeout: 5))
        enterFullScreenItem.click()
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
