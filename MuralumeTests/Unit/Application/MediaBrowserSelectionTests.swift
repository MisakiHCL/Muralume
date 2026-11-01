import Foundation
import XCTest
@testable import Muralume

final class MediaBrowserSelectionTests: XCTestCase {
    func testDefaultsToEmptySelectionOutsideSelectionMode() {
        let selection = MediaBrowserSelection<String>()

        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertFalse(selection.isSelecting)
        XCTAssertEqual(selection.revision, 0)
    }

    func testBeginningSelectionEntersModeAndClearsPreviousSelection() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.toggle("first")
        let revision = selection.revision

        selection.begin()

        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(selection.revision, revision + 1)
    }

    func testEndingSelectionClearsIDsAndDoesNotRestoreThemOnReentry() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.selectAll(["first", "second"])
        let revision = selection.revision

        selection.end()

        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(selection.revision, revision + 1)

        selection.begin()

        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testClearPreservesSelectionMode() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.toggle("first")
        let revision = selection.revision

        selection.clear()

        XCTAssertTrue(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(selection.revision, revision + 1)
    }

    func testToggleAddsAndRemovesOnlyTheRequestedID() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.selectAll(["first", "second"])
        let revision = selection.revision

        selection.toggle("third")
        XCTAssertEqual(selection.ids, ["first", "second", "third"])
        XCTAssertEqual(selection.revision, revision + 1)

        selection.toggle("second")
        XCTAssertEqual(selection.ids, ["first", "third"])
        XCTAssertEqual(selection.revision, revision + 2)
        XCTAssertTrue(selection.isSelecting)
    }

    func testSelectionRequestsOutsideSelectionModeAreIgnored() {
        var selection = MediaBrowserSelection<String>()

        selection.toggle("first")
        selection.selectAll(["first", "second"])

        XCTAssertFalse(selection.isSelecting)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(selection.revision, 0)
    }

    func testSelectAllReplacesOldSearchResultAndDeduplicatesInput() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.selectAll(["old", "shared"])
        let revision = selection.revision

        selection.selectAll(["shared", "new", "new"])

        XCTAssertEqual(selection.ids, ["shared", "new"])
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.revision, revision + 1)
    }

    func testSelectAllWithEmptySearchResultClearsSelectionAndPreservesMode() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.selectAll(["first", "second"])
        let revision = selection.revision

        selection.selectAll([])

        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.revision, revision + 1)
    }

    func testRetainDropsMissingItemsWithoutSelectingNewRefreshItems() {
        var selection = MediaBrowserSelection<String>()
        selection.begin()
        selection.selectAll(["first", "removed"])
        let revision = selection.revision

        selection.retain(["first", "new"])

        XCTAssertEqual(selection.ids, ["first"])
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.revision, revision + 1)

        selection.retain([])

        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.revision, revision + 2)
    }

    func testRepeatedRequestsWithNoStateChangePreserveRevision() {
        var selection = MediaBrowserSelection<String>()
        selection.end()
        selection.clear()
        selection.retain(["unselected"])
        XCTAssertEqual(selection.revision, 0)

        selection.begin()
        let emptyRevision = selection.revision
        selection.begin()
        selection.clear()
        selection.selectAll([])
        selection.retain([])
        XCTAssertEqual(selection.revision, emptyRevision)

        selection.selectAll(["first", "second"])
        let selectedRevision = selection.revision
        selection.selectAll(["second", "first", "first"])
        selection.retain(["first", "second", "unselected"])
        XCTAssertEqual(selection.revision, selectedRevision)

        selection.end()
        let endedRevision = selection.revision
        selection.end()
        selection.clear()
        selection.toggle("first")
        selection.selectAll(["first"])
        selection.retain(["first"])
        XCTAssertEqual(selection.revision, endedRevision)
    }

    func testSelectAllRemainsBoundedByTheSuppliedResult() {
        var selection = MediaBrowserSelection<Int>()
        selection.begin()
        selection.selectAll(Array(0..<10_000))

        selection.selectAll([42, 42, 44])

        XCTAssertEqual(selection.ids, [42, 44])
    }

    func testBrowserLayoutsHaveStablePersistableValues() {
        XCTAssertEqual(MediaBrowserLayout.allCases.map(\.rawValue), ["list", "grid"])
        XCTAssertEqual(MediaBrowserLayout(rawValue: "list"), .list)
        XCTAssertEqual(MediaBrowserLayout(rawValue: "grid"), .grid)
        XCTAssertNil(MediaBrowserLayout(rawValue: "unsupported"))
    }

    func testRetainClearsSamePathSelectionWhenFileIdentityOrMetadataChanges() {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([1]), fileIdentifier: Data([2])
        )
        let replacementIdentity = MediaFileIdentity(
            volumeIdentifier: Data([1]), fileIdentifier: Data([3])
        )
        let original = mediaItem(path: "clip.mov", identity: identity)
        let replacements = [
            mediaItem(path: "clip.mov", identity: replacementIdentity),
            mediaItem(path: "clip.mov", identity: identity, fileSize: 101),
            mediaItem(
                path: "clip.mov", identity: identity,
                modificationDate: Date(timeIntervalSince1970: 11)
            ),
            mediaItem(path: "clip.mov", identity: nil)
        ]

        for replacement in replacements {
            XCTAssertEqual(replacement.id, original.id)
            var selection = MediaBrowserSelection<MediaBrowserItemIdentity>()
            selection.begin()
            selection.toggle(MediaBrowserItemIdentity(original))
            let revision = selection.revision

            selection.retain([MediaBrowserItemIdentity(replacement)])

            XCTAssertTrue(selection.ids.isEmpty)
            XCTAssertTrue(selection.isSelecting)
            XCTAssertEqual(selection.revision, revision + 1)
        }
    }

    func testRefreshAndReorderingPreserveSelectionWithTheSameFileFingerprint() {
        let firstIdentity = MediaFileIdentity(
            volumeIdentifier: Data([1]), fileIdentifier: Data([2])
        )
        let secondIdentity = MediaFileIdentity(
            volumeIdentifier: Data([1]), fileIdentifier: Data([3])
        )
        let original = [
            mediaItem(path: "first.mov", identity: firstIdentity),
            mediaItem(path: "second.mov", identity: secondIdentity)
        ]
        var selection = MediaBrowserSelection<MediaBrowserItemIdentity>()
        selection.begin()
        selection.selectAll(original.map(MediaBrowserItemIdentity.init))
        let selectedIDs = selection.ids
        let revision = selection.revision
        let refreshed = [
            mediaItem(path: "second.mov", identity: secondIdentity, displayName: "Updated label"),
            mediaItem(path: "first.mov", identity: firstIdentity, displayName: "Another label")
        ]

        selection.retain(Set(refreshed.map(MediaBrowserItemIdentity.init)))

        XCTAssertEqual(selection.ids, selectedIDs)
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.revision, revision)
    }

    private func mediaItem(
        path: String,
        identity: MediaFileIdentity?,
        fileSize: Int64 = 100,
        modificationDate: Date? = Date(timeIntervalSince1970: 10),
        displayName: String = "Synthetic video"
    ) -> LibraryMediaItem {
        let root = URL(fileURLWithPath: "/SyntheticBrowserLibrary")
        return LibraryMediaItem(
            rootURL: root,
            rootName: "Synthetic",
            url: root.appendingPathComponent(path),
            displayName: displayName,
            relativePath: path,
            relativeDirectory: "",
            creationDate: nil,
            modificationDate: modificationDate,
            fileSize: fileSize,
            fileIdentity: identity
        )
    }
}
