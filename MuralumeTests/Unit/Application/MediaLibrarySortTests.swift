import XCTest
@testable import Muralume

final class MediaLibrarySortTests: XCTestCase {
    func testNameSortUsesNaturalOrderingAndStablePathTieBreak() {
        let items = [
            makeItem(name: "Clip 10", path: "B/clip.mov"),
            makeItem(name: "Clip 2", path: "Z/clip.mov"),
            makeItem(name: "Clip 2", path: "A/clip.mov")
        ]

        let sortedItems = MediaLibrarySort().sorted(items)

        XCTAssertEqual(
            sortedItems.map(\.relativePath),
            ["A/clip.mov", "Z/clip.mov", "B/clip.mov"]
        )
    }

    func testCreationDateSortKeepsMissingDatesLastInBothDirections() {
        let oldItem = makeItem(
            name: "Old",
            path: "old.mov",
            creationDate: Date(timeIntervalSince1970: 10)
        )
        let newItem = makeItem(
            name: "New",
            path: "new.mov",
            creationDate: Date(timeIntervalSince1970: 20)
        )
        let unknownItem = makeItem(name: "Unknown", path: "unknown.mov")

        let ascending = MediaLibrarySort(
            field: .creationDate,
            direction: .ascending
        ).sorted([unknownItem, newItem, oldItem])
        let descending = MediaLibrarySort(
            field: .creationDate,
            direction: .descending
        ).sorted([unknownItem, oldItem, newItem])

        XCTAssertEqual(ascending.map(\.displayName), ["Old", "New", "Unknown"])
        XCTAssertEqual(descending.map(\.displayName), ["New", "Old", "Unknown"])
    }

    func testFileSizeSortSupportsBothDirections() {
        let small = makeItem(name: "Small", path: "small.mov", fileSize: 4)
        let large = makeItem(name: "Large", path: "large.mov", fileSize: 12)

        let ascending = MediaLibrarySort(
            field: .fileSize,
            direction: .ascending
        ).sorted([large, small])
        let descending = MediaLibrarySort(
            field: .fileSize,
            direction: .descending
        ).sorted([small, large])

        XCTAssertEqual(ascending.map(\.displayName), ["Small", "Large"])
        XCTAssertEqual(descending.map(\.displayName), ["Large", "Small"])
    }

    private func makeItem(
        name: String,
        path: String,
        creationDate: Date? = nil,
        fileSize: Int64 = 0
    ) -> LibraryMediaItem {
        let rootURL = URL(fileURLWithPath: "/tmp/library")
        return LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent(path),
            displayName: name,
            relativePath: path,
            relativeDirectory: URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .relativePath,
            creationDate: creationDate,
            fileSize: fileSize
        )
    }
}
