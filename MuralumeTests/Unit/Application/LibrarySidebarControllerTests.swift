import Foundation
import XCTest
@testable import Muralume

@MainActor
final class LibrarySidebarControllerTests: XCTestCase {
    func testDefaultsToMediaLibraryWithEmptySearchState() {
        let controller = LibrarySidebarController()

        XCTAssertEqual(controller.destination, .mediaLibrary)
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.searchFocusRequest, 0)
        XCTAssertEqual(controller.playbackQueueFocusRequest, 0)
    }

    func testTopLevelNavigationUsesCanonicalOrderAndGrouping() {
        XCTAssertEqual(
            LibrarySidebarNavigationItem.allCases,
            [.mediaLibrary, .playlists, .nowPlaying]
        )
        XCTAssertEqual(
            LibrarySidebarDestination.mediaLibrary.navigationItem,
            .mediaLibrary
        )
        XCTAssertEqual(
            LibrarySidebarDestination.playlists.navigationItem,
            .playlists
        )
        XCTAssertEqual(
            LibrarySidebarDestination.playlist(makePlaylistID())
                .navigationItem,
            .playlists
        )
        XCTAssertEqual(
            LibrarySidebarDestination.playQueue.navigationItem,
            .nowPlaying
        )
    }

    func testSelectingAnotherDestinationClearsQuery() {
        let playlistID = makePlaylistID()
        let controller = LibrarySidebarController()
        controller.requestSearch()
        controller.updateQuery("sky")

        controller.selectDestination(.playlist(playlistID))

        XCTAssertEqual(controller.destination, .playlist(playlistID))
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.searchFocusRequest, 0)
    }

    func testSelectingSameCollectionPreservesQuery() {
        let playlistID = makePlaylistID()
        let controller = LibrarySidebarController(
            destination: .playlist(playlistID),
            query: "travel"
        )

        controller.selectDestination(.playlist(playlistID))

        XCTAssertEqual(controller.query, "travel")
    }

    func testNonSearchableDestinationRejectsQueryUpdates() {
        let controller = LibrarySidebarController(destination: .playlists)

        controller.updateQuery("ignored")

        XCTAssertEqual(controller.query, "")
        XCTAssertFalse(controller.destination.supportsSearch)
    }

    func testRequestSearchPreservesCurrentSearchableCollectionAndQuery() {
        let playlistID = makePlaylistID()
        let controller = LibrarySidebarController(
            destination: .playlist(playlistID),
            query: "travel"
        )
        let initialRequest = controller.searchFocusRequest

        controller.requestSearch()

        XCTAssertEqual(controller.destination, .playlist(playlistID))
        XCTAssertEqual(controller.query, "travel")
        XCTAssertEqual(
            controller.searchFocusRequest,
            initialRequest &+ 1
        )
    }

    func testRequestSearchRoutesOverviewAndQueueToMediaLibrary() {
        for origin in [
            LibrarySidebarDestination.playlists,
            .playQueue
        ] {
            let controller = LibrarySidebarController(
                destination: origin,
                query: "stale"
            )

            controller.requestSearch()

            XCTAssertEqual(controller.destination, .mediaLibrary)
            XCTAssertEqual(controller.query, "")
            XCTAssertEqual(controller.searchFocusRequest, 1)
        }
    }

    func testConsumedSearchFocusRequestDoesNotSurviveViewReconstruction() {
        let controller = LibrarySidebarController()
        controller.requestSearch()
        let request = controller.searchFocusRequest

        controller.consumeSearchFocusRequest(request)

        XCTAssertEqual(controller.searchFocusRequest, 0)
    }

    func testConsumedFocusRequestsKeepMonotonicallyIncreasingIdentity() {
        let controller = LibrarySidebarController()
        controller.requestSearch()
        let firstRequest = controller.searchFocusRequest
        controller.consumeSearchFocusRequest(firstRequest)

        controller.requestSearch()

        XCTAssertGreaterThan(controller.searchFocusRequest, firstRequest)
    }

    func testStaleConsumptionDoesNotClearNewerSearchFocusRequest() {
        let controller = LibrarySidebarController()
        controller.requestSearch()
        let staleRequest = controller.searchFocusRequest
        controller.requestSearch()
        let currentRequest = controller.searchFocusRequest

        controller.consumeSearchFocusRequest(staleRequest)

        XCTAssertEqual(controller.searchFocusRequest, currentRequest)
    }

    func testSelectingPlayQueueRequestsFocusEveryTime() {
        let controller = LibrarySidebarController()

        controller.selectDestination(.playQueue)
        let firstRequest = controller.playbackQueueFocusRequest
        controller.selectDestination(.playQueue)

        XCTAssertEqual(controller.destination, .playQueue)
        XCTAssertEqual(
            controller.playbackQueueFocusRequest,
            firstRequest &+ 1
        )
    }

    func testDeletingCurrentPlaylistFallsBackToOverview() {
        let playlistID = makePlaylistID()
        let controller = LibrarySidebarController(
            destination: .playlist(playlistID),
            query: "sky"
        )

        controller.playlistDidDelete(playlistID)

        XCTAssertEqual(controller.destination, .playlists)
        XCTAssertEqual(controller.query, "")
    }

    func testDeletingAnotherPlaylistDoesNotChangeCurrentState() {
        let currentPlaylistID = makePlaylistID(seed: 1)
        let deletedPlaylistID = makePlaylistID(seed: 2)
        let controller = LibrarySidebarController(
            destination: .playlist(currentPlaylistID),
            query: "sky"
        )

        controller.playlistDidDelete(deletedPlaylistID)

        XCTAssertEqual(
            controller.destination,
            .playlist(currentPlaylistID)
        )
        XCTAssertEqual(controller.query, "sky")
    }

    private func makePlaylistID(seed: UInt8 = 0) -> CustomPlaylist.ID {
        CustomPlaylist.ID(
            rawValue: UUID(
                uuid: (
                    seed, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, seed
                )
            )
        )
    }
}
