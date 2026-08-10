import XCTest
@testable import Muralume

final class MediaLibrarySortTests: XCTestCase {
    func testMediaItemIDKeepsNormalizedIdentity() {
        let nestedID = LibraryMediaItem.ID(
            rootPath: "/tmp/MuralumeLibrary",
            relativePath: "Nested/../Clip.mp4"
        )
        let directID = LibraryMediaItem.ID(
            mediaURL: URL(
                fileURLWithPath: "/tmp/MuralumeLibrary/Clip.mp4"
            )
        )

        XCTAssertEqual(nestedID, directID)
        XCTAssertEqual(Set([nestedID, directID]).count, 1)
        XCTAssertEqual(
            nestedID.standardizedMediaPath,
            "/tmp/MuralumeLibrary/Clip.mp4"
        )
    }

    func testMediaItemIDCodableSchemaRemainsBackwardCompatible() throws {
        let itemID = LibraryMediaItem.ID(
            rootPath: "/tmp/MuralumeLibrary",
            relativePath: "Nested/Clip.mp4"
        )

        let data = try JSONEncoder().encode(itemID)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(
            object,
            [
                "rootPath": "/tmp/MuralumeLibrary",
                "relativePath": "Nested/Clip.mp4"
            ]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(LibraryMediaItem.ID.self, from: data),
            itemID
        )
    }

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

    func testInPlaceSortMatchesValueReturningSort() {
        let sort = MediaLibrarySort(
            field: .fileSize,
            direction: .descending
        )
        let items = [
            makeItem(name: "Medium", path: "medium.mov", fileSize: 8),
            makeItem(name: "Small", path: "small.mov", fileSize: 4),
            makeItem(name: "Large", path: "large.mov", fileSize: 12)
        ]
        var inPlaceItems = items

        sort.sortInPlace(&inPlaceItems)

        XCTAssertEqual(inPlaceItems, sort.sorted(items))
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
