import AppKit
import XCTest

final class MediaBrowserUITests: XCTestCase {
    private enum Identifier {
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
        static let playlistSelectedCount = "muralume.playlist-selected-count"
        static let playlistRemoveSelected = "muralume.playlist-remove-selected"
        static let playlistEntryPrefix = "muralume.playlist-entry."
        static let searchSummary = "muralume.search-results-summary"
        static let playerTopBar = "muralume.player-top-bar"
        static let playbackTimeline = "muralume.playback-timeline"
    }

    private enum Fixture {
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

    private enum Timeout {
        static let control: TimeInterval = 5
        static let media: TimeInterval = 30
        static let quit: TimeInterval = 10
    }

    private enum ScreenshotPolicy {
        static let optInEnvironmentKey = "MURALUME_UI_TEST_WINDOW_SCREENSHOTS"
        static let mainWindowIdentifier = "main-window"
    }

    private enum Language: String {
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
    func testGridSearchAndBatchPlaylistEditingPreserveLibraryMedia() throws {
        let application = try launchEmptyLibrary()
        let playlistName = "Browser UI \(UUID().uuidString.prefix(8))"
        defer {
            cleanup(application, playlistName: playlistName)
            if application.state != .notRunning {
                application.terminate()
            }
        }

        try importFixtureFolder(into: application)
        try waitForLabel(
            "3 videos, 1 media source",
            on: element(Identifier.librarySummary, in: application),
            timeout: Timeout.media
        )
        try createPlaylist(named: playlistName, in: application)
        try navigateToLibrary(application)

        try click(Identifier.libraryList, in: application)
        _ = try require(libraryItem(Fixture.landscape, in: application))
        _ = try require(libraryItem(Fixture.portrait, in: application))
        try assertFixtureTooltips(in: application, layout: "list")
        attachScreenshot("Media browser — list", from: application)

        try click(Identifier.libraryGrid, in: application)
        _ = try require(libraryItem(Fixture.landscape, in: application))
        try assertFixtureTooltips(in: application, layout: "grid")
        try click(Identifier.librarySelection, in: application)
        try require(libraryItem(Fixture.landscape, in: application)).click()
        try assertSelectedCount(1, identifier: Identifier.librarySelectedCount, in: application)

        let search = try require(application.textFields[Identifier.librarySearch])
        try replaceText(in: search, with: "20s", application: application)
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)
        _ = try require(libraryItem(Fixture.landscape, in: application))
        _ = try require(libraryItem(Fixture.portrait, in: application))
        XCTAssertTrue(
            libraryItem(Fixture.alternateTracks, in: application)
                .waitForNonExistence(timeout: Timeout.control)
        )
        // Narrow a nonempty result while keeping a common matching media item.
        // Pending-frame continuity is covered separately by deterministic search tests.
        try replaceText(in: search, with: Fixture.portrait, application: application)
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)
        _ = try require(libraryItem(Fixture.portrait, in: application))
        XCTAssertTrue(
            libraryItem(Fixture.landscape, in: application)
                .waitForNonExistence(timeout: Timeout.control)
        )
        try click(Identifier.librarySelectAll, in: application)
        try assertSelectedCount(1, identifier: Identifier.librarySelectedCount, in: application)
        try replaceSearch(with: "", in: application)
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)
        _ = try require(libraryItem(Fixture.alternateTracks, in: application))

        try require(libraryItem(Fixture.landscape, in: application)).click()
        try require(libraryItem(Fixture.portrait, in: application)).click()
        try assertSelectedCount(2, identifier: Identifier.librarySelectedCount, in: application)
        attachScreenshot("Media browser — two selected in grid", from: application)
        try addSelection(to: playlistName, in: application)

        // Adding the whole result must keep the first two members unique.
        try click(Identifier.librarySelectAll, in: application)
        try assertSelectedCount(3, identifier: Identifier.librarySelectedCount, in: application)
        try click(Identifier.libraryClearSelection, in: application)
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)
        try click(Identifier.librarySelectAll, in: application)
        try addSelection(to: playlistName, in: application)
        try click(Identifier.librarySelection, in: application)

        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        _ = try require(element(Identifier.playlistDetail, in: application))
        try waitForLabel("3 videos", on: element(Identifier.searchSummary, in: application))
        try click(Identifier.playlistSelection, in: application)
        try require(playlistEntry(Fixture.landscape, in: application)).click()
        try require(playlistEntry(Fixture.portrait, in: application)).click()
        try assertSelectedCount(2, identifier: Identifier.playlistSelectedCount, in: application)
        try click(Identifier.playlistRemoveSelected, in: application)
        try assertSelectedCount(0, identifier: Identifier.playlistSelectedCount, in: application)
        XCTAssertTrue(
            playlistEntry(Fixture.landscape, in: application)
                .waitForNonExistence(timeout: Timeout.control)
        )
        XCTAssertTrue(
            playlistEntry(Fixture.portrait, in: application)
                .waitForNonExistence(timeout: Timeout.control)
        )
        _ = try require(playlistEntry(Fixture.alternateTracks, in: application))
        try click(Identifier.playlistSelection, in: application)
        try waitForLabel("1 video", on: element(Identifier.searchSummary, in: application))
        attachScreenshot("Playlist — one video remains after batch removal", from: application)

        try navigateToLibrary(application)
        try waitForLabel(
            "3 videos, 1 media source",
            on: element(Identifier.librarySummary, in: application)
        )
        _ = try require(libraryItem(Fixture.landscape, in: application))
        _ = try require(libraryItem(Fixture.portrait, in: application))
        _ = try require(libraryItem(Fixture.alternateTracks, in: application))
    }

    @MainActor
    func testAddSelectionCreatesEmptyAndPopulatedPlaylistsWithoutChangingSources()
        throws {
        let application = try launchEmptyLibrary()
        let suffix = UUID().uuidString.prefix(8)
        let emptyPlaylistName = "Empty Browser UI \(suffix)"
        let selectedPlaylistName = "Selected Browser UI \(suffix)"
        let cancelledPlaylistName = "Cancelled Browser UI \(suffix)"
        defer {
            cleanup(
                application,
                playlistNames: [emptyPlaylistName, selectedPlaylistName]
            )
            if application.state != .notRunning {
                application.terminate()
            }
        }

        try navigateToPlaylists(application)
        try waitForLabel(
            "0 playlists", on: element(Identifier.playlistOverview, in: application)
        )
        try navigateToLibrary(application)
        try importFixtureFolder(into: application)
        try waitForLabel(
            "3 videos, 1 media source",
            on: element(Identifier.librarySummary, in: application),
            timeout: Timeout.media
        )
        try click(Identifier.libraryGrid, in: application)
        try click(Identifier.librarySelection, in: application)
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)

        let addMenu = try require(element(Identifier.libraryAddSelected, in: application))
        XCTAssertTrue(addMenu.isEnabled, "Add to Playlist must remain available with no selection or playlists")
        addMenu.click()
        let newPlaylist = try require(
            application.menuItems[Identifier.createPlaylistFromSelection]
        )
        let menu = try require(
            application.menus.containing(
                .menuItem, identifier: Identifier.createPlaylistFromSelection
            ).firstMatch
        )
        XCTAssertEqual(menu.menuItems.count, 1, "An empty playlist store offers only New Playlist")
        try waitForLabel("New Playlist", on: newPlaylist)
        XCTAssertTrue(newPlaylist.isEnabled)
        newPlaylist.click()
        let cancelledField = try require(application.textFields[Identifier.playlistName])
        try replaceText(in: cancelledField, with: cancelledPlaylistName, application: application)
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(cancelledField.waitForNonExistence(timeout: Timeout.control))
        try assertSelectedCount(0, identifier: Identifier.librarySelectedCount, in: application)
        try waitForLabel("Done", on: element(Identifier.librarySelection, in: application))

        try click(Identifier.libraryAddSelected, in: application)
        try click(Identifier.createPlaylistFromSelection, in: application)
        try completePlaylistName(emptyPlaylistName, in: application)
        try waitForLabel("0 videos", on: element(Identifier.searchSummary, in: application))
        try navigateToPlaylists(application)
        try waitForLabel("1 playlist", on: element(Identifier.playlistOverview, in: application))
        XCTAssertFalse(application.buttons[cancelledPlaylistName].exists)

        try navigateToLibrary(application)
        try click(Identifier.librarySelection, in: application)
        try require(libraryItem(Fixture.landscape, in: application)).click()
        try require(libraryItem(Fixture.portrait, in: application)).click()
        try assertSelectedCount(2, identifier: Identifier.librarySelectedCount, in: application)
        try click(Identifier.libraryAddSelected, in: application)
        try click(Identifier.createPlaylistFromSelection, in: application)
        _ = try require(application.textFields[Identifier.playlistName])
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            application.textFields[Identifier.playlistName]
                .waitForNonExistence(timeout: Timeout.control)
        )
        try assertSelectedCount(2, identifier: Identifier.librarySelectedCount, in: application)

        try click(Identifier.libraryAddSelected, in: application)
        try click(Identifier.createPlaylistFromSelection, in: application)
        try completePlaylistName(selectedPlaylistName, in: application)
        try waitForLabel("2 videos", on: element(Identifier.searchSummary, in: application))
        _ = try require(playlistEntry(Fixture.landscape, in: application))
        _ = try require(playlistEntry(Fixture.portrait, in: application))
        XCTAssertFalse(playlistEntry(Fixture.alternateTracks, in: application).exists)
        attachScreenshot("Create playlist from two selected videos", from: application)

        try navigateToLibrary(application)
        try waitForLabel(
            "3 videos, 1 media source",
            on: element(Identifier.librarySummary, in: application)
        )
        _ = try require(libraryItem(Fixture.landscape, in: application))
        _ = try require(libraryItem(Fixture.portrait, in: application))
        _ = try require(libraryItem(Fixture.alternateTracks, in: application))
        try navigateToPlaylists(application)
        try waitForLabel("2 playlists", on: element(Identifier.playlistOverview, in: application))
    }

    @MainActor
    func testPlaylistStorageIsIsolatedPerSessionAndSurvivesSameSessionRelaunch()
        throws {
        let sessionA = try launchEmptyLibrary()
        let playlistName = "Session UI \(UUID().uuidString.prefix(8))"
        var activeApplication = sessionA
        var activeSessionIsA = true
        defer {
            if activeSessionIsA {
                cleanup(activeApplication, playlistName: playlistName)
            }
            if activeApplication.state != .notRunning {
                activeApplication.terminate()
            }
        }

        try navigateToPlaylists(sessionA)
        try waitForLabel("0 playlists", on: element(Identifier.playlistOverview, in: sessionA))
        try createPlaylist(named: playlistName, in: sessionA)
        try quitNormally(sessionA)

        let sessionB = try launchEmptyLibrary()
        activeApplication = sessionB
        activeSessionIsA = false
        XCTAssertNotEqual(
            sessionA.launchEnvironment[MuralumeUITestSession.environmentKey],
            sessionB.launchEnvironment[MuralumeUITestSession.environmentKey]
        )
        try navigateToPlaylists(sessionB)
        try waitForLabel("0 playlists", on: element(Identifier.playlistOverview, in: sessionB))
        XCTAssertFalse(sessionB.buttons[playlistName].exists)
        try quitNormally(sessionB)

        // Reuse the wrapper's original UUID rather than creating another session.
        try MuralumeUITestSession.launch(sessionA, for: type(of: self))
        activeApplication = sessionA
        activeSessionIsA = true
        sessionA.activate()
        XCTAssertTrue(sessionA.wait(for: .runningForeground, timeout: Timeout.control))
        try navigateToPlaylists(sessionA)
        try waitForLabel("1 playlist", on: element(Identifier.playlistOverview, in: sessionA))
        _ = try require(sessionA.buttons[playlistName])
    }

    @MainActor
    func testLibraryLayoutPreferenceSurvivesColdLaunch() throws {
        let application = try launchEmptyLibrary()
        defer {
            if application.state != .notRunning {
                // Leave the isolated UI-test app's preference at its default.
                let list = element(Identifier.libraryList, in: application)
                if list.exists && list.isEnabled { list.click() }
                application.terminate()
            }
        }

        try click(Identifier.libraryList, in: application)
        for (selectedID, otherID) in [
            (Identifier.libraryGrid, Identifier.libraryList),
            (Identifier.libraryList, Identifier.libraryGrid)
        ] {
            try click(selectedID, in: application)
            try assertLayoutSelection(selectedID, otherID: otherID, in: application)
            try quitNormally(application)
            // No layout launch argument is injected: this must read saved preferences.
            try MuralumeUITestSession.launch(application, for: type(of: self))
            application.activate()
            XCTAssertTrue(application.wait(for: .runningForeground, timeout: Timeout.control))
            try assertLayoutSelection(selectedID, otherID: otherID, in: application)
        }
    }

    @MainActor
    func testPlaylistPlaysAfterLibrarySourceRemovalAndColdLaunch() throws {
        let application = try launchEmptyLibrary()
        let playlistName = "Independent Playlist UI \(UUID().uuidString.prefix(8))"
        defer {
            cleanup(application, playlistName: playlistName)
            if application.state != .notRunning { application.terminate() }
        }

        try importFixtureFolder(into: application)
        try waitForLabel(
            "3 videos, 1 media source",
            on: element(Identifier.librarySummary, in: application),
            timeout: Timeout.media
        )
        try createPlaylist(named: playlistName, in: application)
        try navigateToLibrary(application)
        try click(Identifier.librarySelection, in: application)
        try require(libraryItem(Fixture.landscape, in: application)).click()
        try require(libraryItem(Fixture.portrait, in: application)).click()
        try assertSelectedCount(2, identifier: Identifier.librarySelectedCount, in: application)
        try addSelection(to: playlistName, in: application)
        try click(Identifier.librarySelection, in: application)
        try removeImportedSource(
            from: application,
            removeLabel: "Remove",
            confirmationLabel: "Remove Folder",
            emptySummary: "0 videos, 0 media sources"
        )
        try waitForLabel(
            "0 videos, 0 media sources",
            on: element(Identifier.librarySummary, in: application)
        )

        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        try waitForLabel("2 videos", on: element(Identifier.searchSummary, in: application))
        let first = try require(playlistEntry(Fixture.landscape, in: application))
        try waitUntilEnabled(first)
        first.click()
        try assertPlaybackAdvances(Fixture.landscape, in: application)
        try quitNormally(application)

        try MuralumeUITestSession.launch(application, for: type(of: self))
        application.activate()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: Timeout.control))
        try assertPlaybackAdvances(Fixture.landscape, in: application)
        try navigateToLibrary(application)
        try waitForLabel(
            "0 videos, 0 media sources",
            on: element(Identifier.librarySummary, in: application)
        )
        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        try waitForLabel("2 videos", on: element(Identifier.searchSummary, in: application))
        let second = try require(playlistEntry(Fixture.portrait, in: application))
        try waitUntilEnabled(second)
        second.click()
        try assertPlaybackAdvances(Fixture.portrait, in: application)
    }

    @MainActor
    func testSimplifiedChineseGridSelectionRemainsVisible() throws {
        let application = try launchEmptyLibrary(language: .simplifiedChinese)
        defer {
            if application.state != .notRunning {
                if application.dialogs.firstMatch.buttons["取消"].exists {
                    application.dialogs.firstMatch.buttons["取消"].click()
                }
                do {
                    try removeImportedSource(
                        from: application,
                        removeLabel: "移除",
                        confirmationLabel: "移除文件夹",
                        emptySummary: "0 个视频，0 个媒体来源",
                        allowMissingSource: true
                    )
                } catch {
                    attachScreenshot("中文网格验收 — 清理媒体来源", from: application)
                }
                application.terminate()
            }
        }

        try importFixtureFolder(into: application)
        try waitForLabel(
            "3 个视频，1 个媒体来源",
            on: element(Identifier.librarySummary, in: application),
            timeout: Timeout.media
        )
        try click(Identifier.libraryGrid, in: application)
        try click(Identifier.librarySelection, in: application)
        let landscape = try require(libraryItem(Fixture.landscape, in: application))
        let portrait = try require(libraryItem(Fixture.portrait, in: application))
        landscape.click()
        portrait.click()
        try waitForLabel(
            "已选择 2 项",
            on: element(Identifier.librarySelectedCount, in: application)
        )
        XCTAssertTrue(landscape.isHittable, "The selected landscape card should remain visible")
        XCTAssertTrue(portrait.isHittable, "The selected portrait card should remain visible")
        attachScreenshot("中文网格验收 — 已选择两项", from: application)
    }

    @MainActor
    private func launchEmptyLibrary(language: Language = .english) throws -> XCUIApplication {
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
    private func importFixtureFolder(into application: XCUIApplication) throws {
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
            try replaceText(in: pathEntry, with: Fixture.directory.path, application: application)
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
    private func createPlaylist(named name: String, in application: XCUIApplication) throws {
        try navigateToPlaylists(application)
        try click(Identifier.newPlaylist, in: application)
        try completePlaylistName(name, in: application)
    }

    @MainActor
    private func completePlaylistName(_ name: String, in application: XCUIApplication) throws {
        let field = try require(application.textFields[Identifier.playlistName])
        try replaceText(in: field, with: name, application: application)
        try require(application.buttons["Create"]).click()
        _ = try require(element(Identifier.playlistDetail, in: application))
        XCTAssertTrue(field.waitForNonExistence(timeout: Timeout.control))
    }

    @MainActor
    private func quitNormally(_ application: XCUIApplication) throws {
        application.activate()
        application.typeKey("q", modifierFlags: .command)
        _ = try XCTUnwrap(
            application.wait(for: .notRunning, timeout: Timeout.quit) ? true : nil,
            "The app must finish its normal shutdown and flush the session playlist store"
        )
    }

    @MainActor
    private func assertFixtureTooltips(in application: XCUIApplication, layout: String) throws {
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
    private func navigateToLibrary(_ application: XCUIApplication) throws {
        try leavePlaylistDetail(application)
        try click(Identifier.libraryTitle, in: application)
        try require(application.menuItems[Identifier.librarySection]).click()
        _ = try require(element(Identifier.librarySummary, in: application))
    }

    @MainActor
    private func navigateToPlaylists(_ application: XCUIApplication) throws {
        try leavePlaylistDetail(application)
        try click(Identifier.libraryTitle, in: application)
        try require(application.menuItems[Identifier.playlistsSection]).click()
        _ = try require(element(Identifier.newPlaylist, in: application))
    }

    @MainActor
    private func leavePlaylistDetail(_ application: XCUIApplication) throws {
        try ensureLibrarySidebarIsVisible(application)
        if element(Identifier.playlistDetail, in: application).exists {
            try require(application.buttons["All Playlists"]).click()
        }
    }

    @MainActor
    private func ensureLibrarySidebarIsVisible(_ application: XCUIApplication) throws {
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
    private func addSelection(to playlistName: String, in application: XCUIApplication) throws {
        try click(Identifier.libraryAddSelected, in: application)
        try require(application.menuItems[playlistName]).click()
    }

    @MainActor
    private func replaceSearch(with query: String, in application: XCUIApplication) throws {
        let field = application.textFields[Identifier.librarySearch]
        try replaceText(in: field, with: query, application: application)
    }

    @MainActor
    private func replaceText(
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
    private func assertSelectedCount(
        _ count: Int,
        identifier: String,
        in application: XCUIApplication
    ) throws {
        try waitForLabel("\(count) selected", on: element(identifier, in: application))
    }

    @MainActor
    private func assertLayoutSelection(
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
    private func assertPlaybackAdvances(
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
    private func libraryItem(_ name: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                Identifier.libraryItemPrefix,
                name + ".mp4"
            )
        ).firstMatch
    }

    @MainActor
    private func playlistEntry(_ name: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                Identifier.playlistEntryPrefix,
                name
            )
        ).firstMatch
    }

    @MainActor
    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func require(
        _ element: XCUIElement,
        description: String = "Expected UI element to exist within the control timeout"
    ) throws -> XCUIElement {
        try XCTUnwrap(
            element.waitForExistence(timeout: Timeout.control) ? element : nil,
            description
        )
    }

    @MainActor
    private func click(_ identifier: String, in application: XCUIApplication) throws {
        if identifier == Identifier.librarySelectAll
            || identifier == Identifier.libraryClearSelection {
            let actions = try require(
                element(Identifier.librarySelectionActions, in: application)
            )
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
    private func waitForLabel(
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
    private func waitUntilEnabled(_ element: XCUIElement) throws {
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
    private func attachScreenshot(_ name: String, from application: XCUIApplication) {
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
    private func cleanup(_ application: XCUIApplication, playlistName: String) {
        cleanup(application, playlistNames: [playlistName])
    }

    @MainActor
    private func cleanup(_ application: XCUIApplication, playlistNames: [String]) {
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
    private func removeImportedSource(
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
