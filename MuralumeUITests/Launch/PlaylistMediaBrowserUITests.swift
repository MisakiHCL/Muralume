import XCTest

final class PlaylistMediaBrowserUITests: MediaBrowserUITestCase {
    @MainActor
    func testPlaylistLayoutsShareLibraryPreferenceAndChecklistRemovalPreservesSources() throws {
        let application = try launchEmptyLibrary()
        let playlistName = "Shared Browser UI \(UUID().uuidString.prefix(8))"
        defer {
            cleanup(application, playlistName: playlistName)
            if application.state != .notRunning { application.terminate() }
        }

        try importFixtureFolder(into: application)
        try waitForLabel("3 videos, 1 media source", on: element(Identifier.librarySummary, in: application),
                         timeout: Timeout.media)
        try click(Identifier.libraryList, in: application)
        try createPlaylist(named: playlistName, in: application)
        try navigateToLibrary(application)
        try click(Identifier.librarySelection, in: application)
        try click(Identifier.librarySelectAll, in: application)
        try assertSelectedCount(3, identifier: Identifier.librarySelectedCount, in: application)
        try addSelection(to: playlistName, in: application)
        try click(Identifier.librarySelection, in: application)
        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        try waitForLabel("3 videos", on: element(Identifier.searchSummary, in: application), timeout: Timeout.media)
        try assertLayoutSelection(Identifier.libraryList, otherID: Identifier.libraryGrid, in: application)
        try assertPlaylistItemGeometry(Fixture.landscape, isGrid: false, in: application)
        try assertPlaylistReopens(playlistName, isGrid: false, in: application)

        try click(Identifier.libraryGrid, in: application)
        try assertLayoutSelection(Identifier.libraryGrid, otherID: Identifier.libraryList, in: application)
        try assertPlaylistItemGeometry(Fixture.landscape, isGrid: true, in: application)
        try assertPlaylistReopens(playlistName, isGrid: true, in: application)
        try click(Identifier.playlistSelection, in: application)
        try require(playlistEntry(Fixture.landscape, in: application)).click()
        try assertSelectedCount(1, identifier: Identifier.playlistSelectedCount, in: application)
        try click(Identifier.libraryList, in: application)
        try assertSelectedCount(1, identifier: Identifier.playlistSelectedCount, in: application)
        try assertPlaylistItemGeometry(Fixture.landscape, isGrid: false, in: application)

        // Both actions are reached through the common checklist menu.
        try click(Identifier.playlistSelectAll, in: application)
        try assertSelectedCount(3, identifier: Identifier.playlistSelectedCount, in: application)
        try click(Identifier.playlistClearSelection, in: application)
        try assertSelectedCount(0, identifier: Identifier.playlistSelectedCount, in: application)
        try require(playlistEntry(Fixture.landscape, in: application)).click()
        try require(playlistEntry(Fixture.portrait, in: application)).click()
        try assertSelectedCount(2, identifier: Identifier.playlistSelectedCount, in: application)
        try click(Identifier.playlistRemoveSelected, in: application)
        try assertSelectedCount(0, identifier: Identifier.playlistSelectedCount, in: application)
        XCTAssertTrue(playlistEntry(Fixture.landscape, in: application).waitForNonExistence(timeout: Timeout.control))
        XCTAssertTrue(playlistEntry(Fixture.portrait, in: application).waitForNonExistence(timeout: Timeout.control))
        _ = try require(playlistEntry(Fixture.alternateTracks, in: application))
        try click(Identifier.playlistSelection, in: application)
        try waitForLabel("1 video", on: element(Identifier.searchSummary, in: application))

        try navigateToLibrary(application)
        try assertLayoutSelection(Identifier.libraryList, otherID: Identifier.libraryGrid, in: application)
        try waitForLabel("3 videos, 1 media source", on: element(Identifier.librarySummary, in: application))
        for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
            _ = try require(libraryItem(name, in: application))
        }
        try click(Identifier.libraryGrid, in: application)
        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        try assertLayoutSelection(Identifier.libraryGrid, otherID: Identifier.libraryList, in: application)
        try assertPlaylistItemGeometry(Fixture.alternateTracks, isGrid: true, in: application)
    }

    @MainActor
    func testAddVideosPickerAddsMultipleFilesAndCancelKeepsCurrentPlaylistWithoutLibraryImport() throws {
        let application = try launchEmptyLibrary()
        let playlistName = "Direct Videos UI \(UUID().uuidString.prefix(8))"
        defer {
            dismissNativePickerIfPresent(in: application)
            cleanup(application, playlistName: playlistName)
            if application.state != .notRunning { application.terminate() }
        }

        try createPlaylist(named: playlistName, in: application)
        try waitForLabel("0 videos", on: element(Identifier.searchSummary, in: application))
        try click(Identifier.playlistAddVideos, in: application)
        let cancelledPicker = try require(application.dialogs.firstMatch)
        _ = try require(cancelledPicker.staticTexts["Choose videos to add to this playlist."])
        try require(cancelledPicker.buttons["Cancel"]).click()
        XCTAssertTrue(cancelledPicker.waitForNonExistence(timeout: Timeout.control))
        try assertCurrentPlaylist(playlistName, count: 0, in: application)

        try click(Identifier.playlistAddVideos, in: application)
        try selectAllFixtureVideosInPicker(in: application)
        try assertCurrentPlaylist(playlistName, count: 3, in: application)
        for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
            _ = try require(playlistEntry(name, in: application))
        }

        // Selecting the same files again must preserve unique entries.
        try click(Identifier.playlistAddVideos, in: application)
        try selectAllFixtureVideosInPicker(in: application)
        try assertCurrentPlaylist(playlistName, count: 3, in: application)
        try click(Identifier.playlistAddVideos, in: application)
        let populatedPicker = try require(application.dialogs.firstMatch)
        try require(populatedPicker.buttons["Cancel"]).click()
        XCTAssertTrue(populatedPicker.waitForNonExistence(timeout: Timeout.control))
        try assertCurrentPlaylist(playlistName, count: 3, in: application)
        try navigateToLibrary(application)
        try waitForLabel("0 videos, 0 media sources", on: element(Identifier.librarySummary, in: application))
        for name in [Fixture.landscape, Fixture.portrait, Fixture.alternateTracks] {
            XCTAssertFalse(libraryItem(name, in: application).exists)
        }

        // Direct imports persist their own grants, with no library source to restore.
        try quitNormally(application)
        try MuralumeUITestSession.launch(application, for: type(of: self))
        application.activate()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: Timeout.control))
        try navigateToPlaylists(application)
        try require(application.buttons[playlistName]).click()
        try assertCurrentPlaylist(playlistName, count: 3, in: application)
        try require(playlistEntry(Fixture.landscape, in: application)).click()
        try assertPlaybackAdvances(Fixture.landscape, in: application)
        try navigateToLibrary(application)
        try waitForLabel("0 videos, 0 media sources", on: element(Identifier.librarySummary, in: application))
    }

    @MainActor
    private func assertPlaylistReopens(_ name: String, isGrid: Bool, in application: XCUIApplication) throws {
        try click(Identifier.libraryToggle, in: application)
        XCTAssertTrue(element(Identifier.playlistDetail, in: application).waitForNonExistence(timeout: Timeout.control))
        try ensureLibrarySidebarIsVisible(application)
        try assertCurrentPlaylist(name, count: 3, in: application)
        try assertPlaylistItemGeometry(Fixture.landscape, isGrid: isGrid, in: application)
    }

    @MainActor
    private func assertCurrentPlaylist(_ name: String, count: Int, in application: XCUIApplication) throws {
        let detail = try require(element(Identifier.playlistDetail, in: application))
        _ = try require(detail.staticTexts[name])
        try waitForLabel(count == 1 ? "1 video" : "\(count) videos",
                         on: element(Identifier.searchSummary, in: application), timeout: Timeout.media)
        _ = try require(element(Identifier.playlistActions, in: application))
        XCTAssertFalse(element(Identifier.playlistAddVideos, in: application).exists,
                       "Adding videos stays inside the playlist actions menu")
    }

    @MainActor
    private func assertPlaylistItemGeometry(_ name: String, isGrid: Bool, in application: XCUIApplication) throws {
        let item = try require(playlistEntry(name, in: application))
        let shape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = item.frame
            guard frame.width > 0, frame.height > 0 else { return false }
            return isGrid ? abs(frame.width - frame.height) <= 4 : frame.width > frame.height * 2
        }, object: item)
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [shape], timeout: Timeout.control) == .completed ? true : nil,
            "The playlist must render \(isGrid ? "square grid cards" : "wide list rows") using the shared layout"
        )
    }
}
