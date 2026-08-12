import XCTest

final class MuralumeRealMediaTests: XCTestCase {
    private enum Environment {
        static let mediaFile = "MURALUME_REAL_MEDIA_FILE"
    }

    private enum AccessibilityIdentifier {
        static let addMedia = "muralume.add-media"
        static let librarySummary = "muralume.library-summary"
        static let librarySidebar = "muralume.library-sidebar"
        static let libraryToggle = "muralume.media-library-toggle"
        static let editLibrary = "muralume.edit-library"
        static let enterDesktop = "muralume.enter-desktop"
        static let desktopStatusItem = "muralume.desktop-status-item"
    }

    private enum Expectation {
        static let panelTimeout: TimeInterval = 5
        static let mediaImportTimeout: TimeInterval = 30
        static let playbackReadyTimeout: TimeInterval = 20
        static let desktopTransitionTimeout: TimeInterval = 10
        static let cleanupTimeout: TimeInterval = 10
    }

    @MainActor
    func testImportsLocalMediaAndRunsDynamicDesktop() throws {
        let environment = ProcessInfo.processInfo.environment
        let mediaURL = try localMediaFile(in: environment)
        let application = launchEmptyLibrary()
        defer {
            if application.state != .notRunning {
                application.terminate()
            }
        }

        guard importMedia(mediaURL, into: application) else {
            return
        }
        guard waitForImportedMedia(in: application) else {
            return
        }
        guard enterDynamicDesktop(in: application) else {
            return
        }
        guard returnToPlayerFromStatusItem(application) else {
            return
        }
        _ = removeImportedMedia(from: application)
    }

    private func localMediaFile(
        in environment: [String: String]
    ) throws -> URL {
        let filePath = try XCTUnwrap(
            environment[Environment.mediaFile],
            "Missing \(Environment.mediaFile)"
        )
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        XCTAssertEqual(
            fileURL.pathExtension.lowercased(),
            "mp4",
            "The injected real-media fixture must be an MP4"
        )
        return fileURL
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
            "ordered",
            "-media-library.source-records",
            "",
            "-media-library.root-bookmarks",
            ""
        ]
        application.launch()
        return application
    }

    @MainActor
    private func importMedia(
        _ mediaURL: URL,
        into application: XCUIApplication
    ) -> Bool {
        let addMediaButton = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.addMedia)
            .firstMatch
        guard addMediaButton.waitForExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The Add Media button did not appear")
            return false
        }
        addMediaButton.click()

        let mediaPicker = application.dialogs.firstMatch
        guard mediaPicker.waitForExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The media picker did not appear")
            return false
        }
        guard navigateMediaPicker(mediaPicker, to: mediaURL) else {
            return false
        }

        let mediaName = mediaURL.lastPathComponent
        let mediaBaseName = mediaURL.deletingPathExtension().lastPathComponent
        let mediaItem = mediaPicker
            .descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "value == %@ OR value == %@",
                    mediaName,
                    mediaBaseName
                )
            )
            .firstMatch
        guard mediaItem.waitForExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The media picker did not show \(mediaName)")
            return false
        }
        mediaItem.click()

        let addButton = mediaPicker.buttons
            .matching(
                NSPredicate(
                    format: "label == %@ OR identifier == %@",
                    "Add",
                    "OKButton"
                )
            )
            .firstMatch
        guard addButton.waitForExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The media picker did not expose its Add button")
            return false
        }
        guard waitUntilEnabled(
            addButton,
            timeout: Expectation.panelTimeout,
            description: "The media picker did not select \(mediaURL.path)"
        ) else {
            return false
        }
        addButton.click()
        guard mediaPicker.waitForNonExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The media picker did not close after selecting the video")
            return false
        }
        return true
    }

    @MainActor
    private func navigateMediaPicker(
        _ mediaPicker: XCUIElement,
        to mediaURL: URL
    ) -> Bool {
        let folderURL = mediaURL.deletingLastPathComponent()
            .standardizedFileURL
        let folderComponents = folderURL.pathComponents
        guard folderComponents.count >= 3,
              folderComponents[0] == "/",
              folderComponents[1] == "Users" else {
            XCTFail("The real-media fixture must be inside /Users/<name>")
            return false
        }
        let homeComponents = Array(folderComponents.prefix(3))
        let homeName = homeComponents[2]

        let homeItem = mediaPicker.staticTexts
            .matching(
                NSPredicate(
                    format: "value == %@",
                    homeName
                )
            )
            .firstMatch
        guard homeItem.waitForExistence(
            timeout: Expectation.panelTimeout
        ) else {
            XCTFail("The media picker did not expose the user home folder")
            return false
        }
        homeItem.click()

        for component in folderComponents.dropFirst(homeComponents.count) {
            let folderItem = mediaPicker.textFields
                .matching(NSPredicate(format: "value == %@", component))
                .firstMatch
            guard folderItem.waitForExistence(
                timeout: Expectation.panelTimeout
            ) else {
                XCTFail("The media picker did not show folder \(component)")
                return false
            }
            folderItem.click()
        }
        return true
    }

    @MainActor
    private func waitForImportedMedia(
        in application: XCUIApplication
    ) -> Bool {
        let summary = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.librarySummary)
            .firstMatch
        guard summary.waitForExistence(
            timeout: Expectation.mediaImportTimeout
        ) else {
            XCTFail("The media library summary did not appear")
            return false
        }
        let importedPredicate = NSPredicate {
            evaluatedObject, _ in
            guard let element = evaluatedObject as? XCUIElement else {
                return false
            }
            return element.label == "1 video, 1 media source"
        }
        let importedExpectation = XCTNSPredicateExpectation(
            predicate: importedPredicate,
            object: summary
        )
        guard XCTWaiter.wait(
            for: [importedExpectation],
            timeout: Expectation.mediaImportTimeout
        ) == .completed else {
            XCTFail("The selected video was not imported within the time limit")
            return false
        }
        return true
    }

    @MainActor
    private func enterDynamicDesktop(
        in application: XCUIApplication
    ) -> Bool {
        let enterDesktopButton = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.enterDesktop)
            .firstMatch
        guard enterDesktopButton.waitForExistence(
            timeout: Expectation.playbackReadyTimeout
        ) else {
            XCTFail("The Dynamic Desktop button did not appear")
            return false
        }
        guard waitUntilEnabled(
            enterDesktopButton,
            timeout: Expectation.playbackReadyTimeout,
            description: "The imported video did not become playable"
        ) else {
            return false
        }
        enterDesktopButton.click()

        guard application.windows.firstMatch.waitForNonExistence(
            timeout: Expectation.desktopTransitionTimeout
        ) else {
            XCTFail("The player window did not hide for Dynamic Desktop")
            return false
        }
        return true
    }

    @MainActor
    private func returnToPlayerFromStatusItem(
        _ application: XCUIApplication
    ) -> Bool {
        let statusItem = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.desktopStatusItem)
            .firstMatch
        let labelledStatusItem = application
            .descendants(matching: .statusItem)
            .matching(NSPredicate(format: "label == %@", "Muralume"))
            .firstMatch
        let activeStatusItem: XCUIElement
        if statusItem.waitForExistence(
            timeout: Expectation.desktopTransitionTimeout
        ) {
            activeStatusItem = statusItem
        } else {
            guard labelledStatusItem.waitForExistence(
                timeout: Expectation.desktopTransitionTimeout
            ) else {
                XCTFail("The Dynamic Desktop status item did not appear")
                return false
            }
            activeStatusItem = labelledStatusItem
        }
        activeStatusItem.click()

        let returnItem = application.menuItems["Return to Player"]
        guard returnItem.waitForExistence(
            timeout: Expectation.desktopTransitionTimeout
        ) else {
            XCTFail("The Return to Player status menu item did not appear")
            return false
        }
        returnItem.click()
        guard application.windows.firstMatch.waitForExistence(
            timeout: Expectation.desktopTransitionTimeout
        ) else {
            XCTFail("The player window did not return from Dynamic Desktop")
            return false
        }
        return true
    }

    @MainActor
    private func removeImportedMedia(
        from application: XCUIApplication
    ) -> Bool {
        let sidebar = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.librarySidebar)
            .firstMatch
        if !sidebar.exists {
            application
                .descendants(matching: .any)
                .matching(identifier: AccessibilityIdentifier.libraryToggle)
                .firstMatch
                .click()
        }
        guard sidebar.waitForExistence(
            timeout: Expectation.cleanupTimeout
        ) else {
            XCTFail("The media library did not appear for cleanup")
            return false
        }

        let editButton = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.editLibrary)
            .firstMatch
        guard editButton.waitForExistence(
            timeout: Expectation.cleanupTimeout
        ) else {
            XCTFail("The media library edit action did not appear")
            return false
        }
        editButton.click()

        let removeButton = application.buttons["Remove Video"]
        guard removeButton.waitForExistence(
            timeout: Expectation.cleanupTimeout
        ) else {
            XCTFail("The imported video could not be removed")
            return false
        }
        removeButton.click()

        let confirmationSheet = application.sheets
            .matching(NSPredicate(format: "label == %@", "alert"))
            .firstMatch
        guard confirmationSheet.waitForExistence(
            timeout: Expectation.cleanupTimeout
        ) else {
            XCTFail("The remove-video confirmation did not appear")
            return false
        }
        let confirmation = confirmationSheet.buttons["Remove Video"]
        guard confirmation.waitForExistence(
            timeout: Expectation.cleanupTimeout
        ) else {
            XCTFail("The remove-video confirmation action did not appear")
            return false
        }
        confirmation.click()

        let summary = application
            .descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.librarySummary)
            .firstMatch
        let emptyPredicate = NSPredicate {
            evaluatedObject, _ in
            guard let element = evaluatedObject as? XCUIElement else {
                return false
            }
            return element.label == "0 videos, 0 media sources"
        }
        let emptyExpectation = XCTNSPredicateExpectation(
            predicate: emptyPredicate,
            object: summary
        )
        guard XCTWaiter.wait(
            for: [emptyExpectation],
            timeout: Expectation.cleanupTimeout
        ) == .completed else {
            XCTFail("The imported media was not cleared during cleanup")
            return false
        }
        return true
    }

    @MainActor
    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval,
        description: String
    ) -> Bool {
        let enabledPredicate = NSPredicate {
            evaluatedObject, _ in
            (evaluatedObject as? XCUIElement)?.isEnabled == true
        }
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: enabledPredicate,
            object: element
        )
        enabledExpectation.expectationDescription = description
        guard XCTWaiter.wait(
            for: [enabledExpectation],
            timeout: timeout
        ) == .completed else {
            XCTFail(description)
            return false
        }
        return true
    }
}
