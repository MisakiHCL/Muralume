import XCTest

final class MediaBrowserUITests: MediaBrowserUITestCase {
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

}
