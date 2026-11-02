import SwiftUI
import XCTest
@testable import Muralume

@MainActor
final class MediaBrowserItemLayoutTests: XCTestCase {
    func testStandardListCardHasEqualEightPointArtworkInsets() {
        let rowHeight = MuralumeTheme.Size.playlistRowHeight(for: .large)
        let artwork = MuralumeTheme.Size.mediaItemListArtworkSize(rowHeight: rowHeight)
        XCTAssertEqual(rowHeight, 64)
        XCTAssertEqual(artwork, CGSize(width: 84, height: 48))
        XCTAssertEqual((rowHeight - artwork.height) / 2, MuralumeTheme.Size.mediaItemContentPadding)
        XCTAssertEqual(MuralumeTheme.Size.mediaItemContentPadding, 8)
    }

    func testDynamicTextArtworkFillsInnerHeightWithoutExpandingIntoMetadataLane() {
        var previousHeight = MuralumeTheme.Size.playlistRowHeight
        for size in DynamicTypeSize.allCases {
            let height = MuralumeTheme.Size.playlistRowHeight(for: size)
            let artwork = MuralumeTheme.Size.mediaItemListArtworkSize(rowHeight: height)
            XCTAssertGreaterThanOrEqual(height, previousHeight)
            XCTAssertEqual(artwork.width, 84)
            XCTAssertGreaterThanOrEqual(artwork.height, 48)
            XCTAssertEqual((height - artwork.height) / 2, 8)
            previousHeight = height
        }
    }

    func testResolvedPlaylistAndLibraryUseSameMetadataEvenWithStaleReference() {
        let item = makeItem(
            rootURL: URL(fileURLWithPath: "/tmp/Media Library"),
            name: "Current name", path: "Nested/Current.mp4", fileSize: 4_096
        )
        let reference = MediaReference(
            mediaItemID: item.id, fileIdentity: nil, lastKnownDisplayName: "Old name"
        )
        let localization = AppLocalizationController(initialLanguage: .english)
        let library = MediaBrowserItemMetadata(item: item, localization: localization)
        let playlist = MediaBrowserItemMetadata(
            item: item, reference: reference, localization: localization
        )
        XCTAssertEqual(playlist, library)
        XCTAssertEqual(playlist.name, "Current name")
        XCTAssertEqual(playlist.tooltipText(), item.url.path)
        XCTAssertNotNil(playlist.fileSize)
        XCTAssertNotNil(playlist.creationDate)
    }

    func testUnresolvedReferenceDoesNotInventFileSizeOrCreationDate() {
        let reference = MediaReference(
            mediaItemID: .init(rootPath: "/tmp/Media Library", relativePath: "Nested/Clip.mp4"),
            fileIdentity: nil, lastKnownDisplayName: "Clip"
        )
        let metadata = MediaBrowserItemMetadata(
            item: nil, reference: reference,
            localization: AppLocalizationController(initialLanguage: .english)
        )
        XCTAssertEqual(metadata.name, "Clip")
        XCTAssertEqual(metadata.location, "Media Library / Nested")
        XCTAssertNil(metadata.fileSize)
        XCTAssertNil(metadata.creationDate)
        XCTAssertEqual(metadata.accessibilityLabel, "Clip, Media Library / Nested")
    }

    func testUnavailableSameNamedPlaylistReferencesKeepDistinctPathsAndLocalizedReasonsInHover() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let localization = AppLocalizationController(initialLanguage: language)
            let reason = localization.localized("playlists.media.issue.fileMissing")
            let tooltips = ["/tmp/First", "/tmp/Second"].map { root in
                let reference = MediaReference(
                    mediaItemID: .init(rootPath: root, relativePath: "Nested/Clip.mp4"),
                    fileIdentity: nil, lastKnownDisplayName: "Clip"
                )
                let metadata = MediaBrowserItemMetadata(item: nil, reference: reference, localization: localization)
                let tooltip = metadata.tooltipText(status: reason)
                XCTAssertTrue(tooltip.contains(root + "/Nested/Clip.mp4"))
                XCTAssertTrue(tooltip.contains(reason))
                return tooltip
            }
            XCTAssertNotEqual(tooltips[0], tooltips[1])
        }
    }
}
