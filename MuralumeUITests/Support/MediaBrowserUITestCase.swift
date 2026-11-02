import AppKit
import XCTest

/// Shared synthetic fixtures and guarded native input for media-browser UI tests.
class MediaBrowserUITestCase: XCTestCase {
    enum Identifier {
        static let addMedia = "muralume.add-media"
        static let libraryTitle = "muralume.library-title"
        static let librarySection = "muralume.library-section.media-library"
        static let playlistsSection = "muralume.library-section.playlists"
        static let libraryToggle = "muralume.media-library-toggle"
        static let librarySummary = "muralume.library-summary"
        static let librarySearch = "muralume.library-search"
        static let libraryList = "muralume.library-layout.list"
        static let libraryGrid = "muralume.library-layout.grid"
        static let librarySelection = "muralume.library-selection"
        static let librarySelectionActions = "muralume.library-selection-actions"
        static let librarySelectAll = "muralume.library-select-all"
        static let libraryClearSelection = "muralume.library-clear-selection"
        static let libraryAddSelected = "muralume.library-add-selected"
        static let librarySelectedCount = "muralume.library-selected-count"
        static let libraryItemPrefix = "muralume.library-item."
        static let editLibrary = "muralume.edit-library"
        static let newPlaylist = "muralume.playlist-new"
        static let createPlaylistFromSelection = "muralume.playlist-create-from-selection"
        static let playlistOverview = "muralume.playlists-overview"
        static let playlistName = "muralume.playlist-name"
        static let playlistDetail = "muralume.playlist-detail"
        static let playlistActions = "muralume.playlist-actions"
        static let playlistSelection = "muralume.playlist-selection"
        static let playlistSelectionActions = "muralume.playlist-selection-actions"
        static let playlistSelectAll = "muralume.playlist-select-all"
        static let playlistClearSelection = "muralume.playlist-clear-selection"
        static let playlistAddVideos = "muralume.playlist-add-videos"
        static let playlistSelectedCount = "muralume.playlist-selected-count"
        static let playlistRemoveSelected = "muralume.playlist-remove-selected"
        static let playlistEntryPrefix = "muralume.playlist-entry."
        static let searchSummary = "muralume.search-results-summary"
        static let playerTopBar = "muralume.player-top-bar"
        static let playbackTimeline = "muralume.playback-timeline"
    }

    enum Fixture {
        static let landscape = "landscape-20s-h264"
        static let portrait = "portrait-20s-h264"
        static let alternateTracks = "alternate-tracks-5s"

        static var directory: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("MuralumeTests/Fixtures", isDirectory: true)
                .standardizedFileURL
        }
    }

    enum Timeout {
        static let control: TimeInterval = 5
        static let media: TimeInterval = 30
        static let quit: TimeInterval = 10
    }

    enum ScreenshotPolicy {
        static let optInEnvironmentKey = "MURALUME_UI_TEST_WINDOW_SCREENSHOTS"
        static let mainWindowIdentifier = "main-window"
    }

    enum Language: String {
        case english = "en"
        case simplifiedChinese = "zh-Hans"

        var locale: String {
            switch self {
            case .english: "en_US"
            case .simplifiedChinese: "zh_CN"
            }
        }
    }

    @MainActor
    func launchEmptyLibrary(language: Language = .english) throws -> XCUIApplication {
        let application = try MuralumeUITestSession.makeApplication(for: type(of: self))
        application.launchArguments += [
            "-AppleLanguages", "(\(language.rawValue))",
            "-AppleLocale", language.locale,
            "-ApplePersistenceIgnoreState", "YES",
            "-settings.app-language", language.rawValue,
            "-settings.playback.volume", "1",
            "-settings.playback.is-muted", "false",
            "-settings.playback.restorable-volume", "1",
            "-settings.playback.rate", "1",
            "-settings.playback.order", "shuffled",
            "-media-library.source-records", "",
            "-media-library.root-bookmarks", ""
        ]
        try MuralumeUITestSession.launch(application, for: type(of: self))
        application.activate()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: Timeout.control))
        return application
    }

    @MainActor
    func importFixtureFolder(into application: XCUIApplication) throws {
        try MuralumeUITestInputSource.withASCIILayout { inputSource in
            for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: Fixture.directory.appendingPathComponent(name + ".mp4").path
                    ),
                    "The repository's synthetic video fixture must exist"
                )
            }
            try click(Identifier.addMedia, in: application)
            let picker = application.dialogs.firstMatch
            defer {
                let goTo = application.sheets["GoToWindow"]
                let closeGoTo = goTo.buttons["CloseButton"]
                if closeGoTo.exists { closeGoTo.click() }
                let cancel = picker.buttons.matching(NSPredicate(
                    format: "title == %@ OR label == %@", "Cancel", "Cancel"
                )).firstMatch
                if picker.exists, cancel.exists, cancel.isEnabled { cancel.click() }
            }
            _ = try require(picker)
            try navigatePicker(to: Fixture.directory, in: application, inputSource: inputSource)
            let add = try require(
                picker.buttons.matching(
                    NSPredicate(format: "label == %@ OR identifier == %@", "Add", "OKButton")
                ).firstMatch
            )
            try waitUntilEnabled(add)
            add.click()
            XCTAssertTrue(picker.waitForNonExistence(timeout: Timeout.control))
        }
    }

    @MainActor
    func selectAllFixtureVideosInPicker(in application: XCUIApplication) throws {
        try MuralumeUITestInputSource.withASCIILayout { inputSource in
            for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
                _ = try XCTUnwrap(FileManager.default.fileExists(
                    atPath: Fixture.directory.appendingPathComponent(name + ".mp4").path
                ) ? true : nil, "Only the repository's synthetic fixtures may be selected")
            }
            let picker = try require(application.dialogs.firstMatch)
            defer { dismissNativePickerIfPresent(in: application) }
            try navigatePicker(
                to: Fixture.directory.appendingPathComponent(Fixture.landscape + ".mp4"),
                in: application, inputSource: inputSource
            )
            let add = try require(picker.buttons.matching(NSPredicate(
                format: "label == %@ OR identifier == %@", "Add", "OKButton"
            )).firstMatch)
            // A file path selects a known fixture instead of leaving its parent
            // directory selected. Confirm that selection before extending it.
            try waitUntilEnabled(add)
            try inputSource.prepareForConfirmation()
            application.typeKey("a", modifierFlags: .command)
            try waitUntilEnabled(add)
            add.click()
            _ = try XCTUnwrap(picker.waitForNonExistence(timeout: Timeout.control) ? true : nil,
                              "The native picker must close after adding the selected videos")
        }
    }

    @MainActor
    func navigatePicker(
        to fixtureURL: URL,
        in application: XCUIApplication,
        inputSource: MuralumeUITestInputSource.Selection
    ) throws {
        let allowed = [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks].map {
            Fixture.directory.appendingPathComponent($0 + ".mp4")
        } + [Fixture.directory]
        _ = try XCTUnwrap(allowed.contains(fixtureURL) ? true : nil, "Only synthetic fixtures may be selected")
        application.typeKey("g", modifierFlags: [.command, .shift])
        let goToWindow = try require(application.sheets["GoToWindow"])
        let pathEntry: XCUIElement
        let pathTextField = application.textFields["PathTextField"]
        if pathTextField.waitForExistence(timeout: Timeout.control) {
            pathEntry = pathTextField
        } else if application.comboBoxes.firstMatch.waitForExistence(timeout: Timeout.control) {
            pathEntry = application.comboBoxes.firstMatch
        } else {
            pathEntry = try require(
                application.textFields.matching(
                    NSPredicate(format: "hasKeyboardFocus == true")
                ).firstMatch
            )
        }
        try replaceText(in: pathEntry, with: fixtureURL.path, application: application)
        pathEntry.click()
        try inputSource.prepareForConfirmation()
        pathEntry.typeKey(.return, modifierFlags: [])
        // The first Return may accept path completion. Keep the exact folder
        // selected and confirm only after the Go to Folder sheet has closed.
        if !goToWindow.waitForNonExistence(timeout: Timeout.control), pathEntry.exists {
            pathEntry.click()
            try inputSource.prepareForConfirmation()
            pathEntry.typeKey(.return, modifierFlags: [])
        }
        _ = try XCTUnwrap(
            goToWindow.waitForNonExistence(timeout: Timeout.control) ? true : nil,
            "Go to Folder must close after selecting the fixture directory"
        )
    }

    @MainActor
    func dismissNativePickerIfPresent(in application: XCUIApplication) {
        let closeGoTo = application.sheets["GoToWindow"].buttons["CloseButton"]
        if closeGoTo.exists { closeGoTo.click() }
        let picker = application.dialogs.firstMatch
        let cancel = picker.buttons.matching(NSPredicate(
            format: "title == %@ OR label == %@", "Cancel", "Cancel"
        )).firstMatch
        if picker.exists, cancel.exists, cancel.isEnabled { cancel.click() }
    }

    @MainActor
    func createPlaylist(named name: String, in application: XCUIApplication) throws {
        try navigateToPlaylists(application)
        try click(Identifier.newPlaylist, in: application)
        try completePlaylistName(name, in: application)
    }

    @MainActor
    func completePlaylistName(_ name: String, in application: XCUIApplication) throws {
        let field = try require(application.textFields[Identifier.playlistName])
        try replaceText(in: field, with: name, application: application)
        try require(application.buttons["Create"]).click()
        _ = try require(element(Identifier.playlistDetail, in: application))
        XCTAssertTrue(field.waitForNonExistence(timeout: Timeout.control))
    }

    @MainActor
    func quitNormally(_ application: XCUIApplication) throws {
        application.activate()
        application.typeKey("q", modifierFlags: .command)
        _ = try XCTUnwrap(
            application.wait(for: .notRunning, timeout: Timeout.quit) ? true : nil,
            "The app must finish its normal shutdown and flush the session playlist store"
        )
    }

    @MainActor
    func assertFixtureTooltips(in application: XCUIApplication, layout: String) throws {
        for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
            let item = try require(libraryItem(name, in: application))
            // XCTest exposes the native help tag but omits its text attributes.
            // Assert visibility here; optional captures are restricted to the app window.
            try require(element(Identifier.librarySummary, in: application)).hover()
            XCTAssertTrue(application.helpTags.firstMatch.waitForNonExistence(timeout: Timeout.control))
            item.hover()
            _ = try require(application.helpTags.firstMatch)
            attachScreenshot("Media browser — \(layout) tooltip — \(name)", from: application)
        }
    }

    @MainActor
    func navigateToLibrary(_ application: XCUIApplication) throws {
        try leavePlaylistDetail(application)
        try click(Identifier.libraryTitle, in: application)
        try require(application.menuItems[Identifier.librarySection]).click()
        _ = try require(element(Identifier.librarySummary, in: application))
    }

    @MainActor
    func navigateToPlaylists(_ application: XCUIApplication) throws {
        try leavePlaylistDetail(application)
        try click(Identifier.libraryTitle, in: application)
        try require(application.menuItems[Identifier.playlistsSection]).click()
        _ = try require(element(Identifier.newPlaylist, in: application))
    }

    @MainActor
    func leavePlaylistDetail(_ application: XCUIApplication) throws {
        try ensureLibrarySidebarIsVisible(application)
        if element(Identifier.playlistDetail, in: application).exists {
            try require(application.buttons["All Playlists"]).click()
        }
    }

    @MainActor
    func ensureLibrarySidebarIsVisible(_ application: XCUIApplication) throws {
        // Playback hides the chrome after 2.5 seconds. Reveal it through
        // pointer activity before locating its toggle, without taking a capture.
        application.windows.firstMatch.hover()
        let toggle = try require(element(Identifier.libraryToggle, in: application))
        if !toggle.isSelected {
            toggle.click()
        }
        let title = element(Identifier.libraryTitle, in: application)
        let detail = element(Identifier.playlistDetail, in: application)
        let sidebarReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                title.exists || detail.exists
            },
            object: application
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [sidebarReady], timeout: Timeout.media) == .completed
                ? true : nil,
            "The open library sidebar must finish loading its overview or playlist detail"
        )
    }

    @MainActor
    func addSelection(to playlistName: String, in application: XCUIApplication) throws {
        try click(Identifier.libraryAddSelected, in: application)
        try require(application.menuItems[playlistName]).click()
    }

    @MainActor
    func replaceSearch(with query: String, in application: XCUIApplication) throws {
        let field = application.textFields[Identifier.librarySearch]
        try replaceText(in: field, with: query, application: application)
    }

    @MainActor
    func replaceText(
        in field: XCUIElement,
        with text: String,
        application: XCUIApplication
    ) throws {
        field.click()
        field.typeKey(.leftArrow, modifierFlags: .command)
        field.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        field.typeKey(.delete, modifierFlags: [])
        let emptyField = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let field = object as? XCUIElement, field.exists else { return false }
                return (field.value as? String ?? "").isEmpty
            },
            object: field
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [emptyField], timeout: Timeout.control) == .completed ? true : nil,
            "The text field must be empty before inserting literal text"
        )
        if text.isEmpty {
            return
        }

        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let originalItems = try (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                let data = try XCTUnwrap(
                    original.data(forType: type),
                    "Could not preserve a clipboard representation; the clipboard was not changed"
                )
                _ = try XCTUnwrap(
                    copy.setData(data, forType: type) ? true : nil,
                    "Could not clone a clipboard representation; the clipboard was not changed"
                )
            }
            return copy
        }
        _ = try XCTUnwrap(
            pasteboard.changeCount == originalChangeCount ? true : nil,
            "The clipboard changed while preserving it; no test text was written"
        )
        pasteboard.clearContents()
        var ownedChangeCount = pasteboard.changeCount
        defer {
            // Restore every representation, including images, without overwriting
            // a newer copy made by the user while the UI operation was running.
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                if !originalItems.isEmpty {
                    XCTAssertTrue(
                        pasteboard.writeObjects(originalItems),
                        "The original clipboard items must be restored"
                    )
                }
            }
        }
        let written = pasteboard.setString(text, forType: .string)
        ownedChangeCount = pasteboard.changeCount
        _ = try XCTUnwrap(written ? true : nil, "Could not prepare literal UI-test text")

        if field.identifier == Identifier.playlistName {
            // Text input can leave a short-lived native candidate dialog.
            // It is not our SwiftUI naming overlay or a permission alert.
            _ = application.dialogs.firstMatch.waitForNonExistence(timeout: Timeout.control)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        } else {
            field.rightClick()
        }
        // An empty native editor has Cut/Copy disabled, making Paste its first
        // enabled context-menu action. Keyboard navigation also works when
        // AppKit exposes that transient menu outside the app's XCTest tree.
        application.typeKey(.home, modifierFlags: [])
        application.typeKey(.return, modifierFlags: [])
        try waitForLabel(text, on: field)
    }

    @MainActor
    func assertSelectedCount(
        _ count: Int,
        identifier: String,
        in application: XCUIApplication
    ) throws {
        try waitForLabel("\(count) selected", on: element(identifier, in: application))
    }

    @MainActor
    func assertLayoutSelection(
        _ selectedID: String,
        otherID: String,
        in application: XCUIApplication
    ) throws {
        let selected = try require(element(selectedID, in: application))
        let other = try require(element(otherID, in: application))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: selected
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [expectation], timeout: Timeout.control) == .completed
                ? true : nil,
            "The requested library layout must remain selected after a cold launch"
        )
        XCTAssertFalse(other.isSelected, "Only one library layout may be selected")
    }

    @MainActor
    func assertPlaybackAdvances(
        _ name: String,
        in application: XCUIApplication
    ) throws {
        // An open sidebar keeps the real playback controls accessible while
        // XCTest waits for the title and observes timeline advancement.
        try ensureLibrarySidebarIsVisible(application)
        let topBar = try require(element(Identifier.playerTopBar, in: application))
        _ = try require(topBar.descendants(matching: .any).matching(
            NSPredicate(format: "title == %@ OR label == %@ OR value == %@", name, name, name)
        ).firstMatch)
        let timeline = try require(
            element(Identifier.playbackTimeline, in: application).sliders.firstMatch
        )
        try waitUntilEnabled(timeline)
        let originalValue = String(describing: timeline.value ?? "")
        let advancement = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let slider = object as? XCUIElement, slider.exists, slider.isEnabled else {
                    return false
                }
                return String(describing: slider.value ?? "") != originalValue
            },
            object: timeline
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [advancement], timeout: Timeout.control) == .completed
                ? true : nil,
            "The playlist video must load and its playback position must advance"
        )
    }

    @MainActor
    func libraryItem(_ name: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                Identifier.libraryItemPrefix,
                name + ".mp4"
            )
        ).firstMatch
    }

    @MainActor
    func playlistEntry(_ name: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                Identifier.playlistEntryPrefix,
                name
            )
        ).firstMatch
    }

    @MainActor
    func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func require(
        _ element: XCUIElement,
        description: String = "Expected UI element to exist within the control timeout"
    ) throws -> XCUIElement {
        try XCTUnwrap(
            element.waitForExistence(timeout: Timeout.control) ? element : nil,
            description
        )
    }

    @MainActor
    func click(_ identifier: String, in application: XCUIApplication) throws {
        let selectionActionsID: String?
        switch identifier {
        case Identifier.playlistAddVideos:
            selectionActionsID = Identifier.playlistActions
        case Identifier.librarySelectAll, Identifier.libraryClearSelection:
            selectionActionsID = Identifier.librarySelectionActions
        case Identifier.playlistSelectAll, Identifier.playlistClearSelection:
            selectionActionsID = Identifier.playlistSelectionActions
        default:
            selectionActionsID = nil
        }
        if let selectionActionsID {
            let actions = try require(element(selectionActionsID, in: application))
            try waitUntilEnabled(actions)
            actions.click()
        }
        let control = try require(
            element(identifier, in: application),
            description: "Expected UI control: \(identifier)"
        )
        try waitUntilEnabled(control)
        control.click()
    }

    @MainActor
    func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval = Timeout.control
    ) throws {
        _ = try require(element)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "title == %@ OR label == %@ OR value == %@", label, label, label
            ),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        _ = try XCTUnwrap(
            result == .completed ? true : nil,
            "Expected UI title, label, or value ‘\(label)’ within \(timeout) seconds"
        )
    }

    @MainActor
    func waitUntilEnabled(_ element: XCUIElement) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.isEnabled == true
            },
            object: element
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [expectation], timeout: Timeout.control) == .completed
                ? true : nil,
            "Expected the UI control to become enabled within the control timeout"
        )
    }

    @MainActor
    func attachScreenshot(_ name: String, from application: XCUIApplication) {
        guard ProcessInfo.processInfo.environment[ScreenshotPolicy.optInEnvironmentKey] == "1" else {
            return
        }
        let window = application.windows[ScreenshotPolicy.mainWindowIdentifier]
        guard window.exists else { return }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func cleanup(_ application: XCUIApplication, playlistName: String) {
        cleanup(application, playlistNames: [playlistName])
    }

    @MainActor
    func cleanup(_ application: XCUIApplication, playlistNames: [String]) {
        guard application.state != .notRunning else { return }
        if application.dialogs.firstMatch.buttons["Cancel"].exists {
            application.dialogs.firstMatch.buttons["Cancel"].click()
        }
        if application.textFields[Identifier.playlistName].exists {
            application.typeKey(.escape, modifierFlags: [])
        }
        // The unique name limits cleanup to data created by this test.
        do {
            try navigateToPlaylists(application)
            for playlistName in playlistNames {
                let playlist = application.buttons[playlistName]
                if playlist.exists {
                    playlist.click()
                    try click(Identifier.playlistActions, in: application)
                    try require(application.menuItems["Delete"]).click()
                    let confirmation = try require(application.sheets.firstMatch.buttons["Delete"])
                    confirmation.click()
                    _ = try require(element(Identifier.newPlaylist, in: application))
                }
            }
            try navigateToLibrary(application)
            try removeImportedSource(
                from: application,
                removeLabel: "Remove",
                confirmationLabel: "Remove Folder",
                emptySummary: "0 videos, 0 media sources",
                allowMissingSource: true
            )
        } catch {
            attachScreenshot("Media browser cleanup", from: application)
        }
    }

    @MainActor
    func removeImportedSource(
        from application: XCUIApplication,
        removeLabel: String,
        confirmationLabel: String,
        emptySummary: String,
        allowMissingSource: Bool = false
    ) throws {
        let edit = element(Identifier.editLibrary, in: application)
        if allowMissingSource {
            guard edit.exists && edit.isEnabled else { return }
        } else {
            _ = try require(edit, description: "Expected the imported source's Edit Library control")
            try waitUntilEnabled(edit)
        }
        edit.click()
        let remove = application.buttons[removeLabel]
        if allowMissingSource {
            guard remove.waitForExistence(timeout: Timeout.control) else { return }
        } else {
            _ = try require(remove, description: "Expected the imported source's ‘\(removeLabel)’ button")
            try waitUntilEnabled(remove)
        }
        remove.click()
        let confirmation = try require(
            application.sheets.firstMatch.buttons[confirmationLabel]
        )
        confirmation.click()
        try waitForLabel(
            emptySummary,
            on: element(Identifier.librarySummary, in: application)
        )
    }
}
