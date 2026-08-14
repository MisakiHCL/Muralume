import AppKit
import XCTest
@testable import Muralume

final class FixedHeightVirtualizedTableTests: XCTestCase {
    private struct SnapshotToken: Hashable {
        let contentRevision: UInt64
        let query: String
    }

    func testSnapshotTokenCanIncludeContentRevisionAndQuery() {
        var tracker = VirtualizedTableUpdateTracker()
        let unfiltered = AnyHashable(
            SnapshotToken(contentRevision: 7, query: "")
        )
        let filtered = AnyHashable(
            SnapshotToken(contentRevision: 7, query: "sky")
        )

        XCTAssertTrue(tracker.consumeSnapshotToken(unfiltered))
        XCTAssertFalse(tracker.consumeSnapshotToken(unfiltered))
        XCTAssertTrue(tracker.consumeSnapshotToken(filtered))
        XCTAssertFalse(tracker.consumeSnapshotToken(filtered))
    }

    func testScrollToTopRequestIsConsumedExactlyOnce() {
        var tracker = VirtualizedTableUpdateTracker()

        XCTAssertFalse(tracker.consumeScrollToTopRequest(nil))
        XCTAssertTrue(tracker.consumeScrollToTopRequest(1))
        XCTAssertFalse(tracker.consumeScrollToTopRequest(1))
        XCTAssertFalse(tracker.consumeScrollToTopRequest(nil))
        XCTAssertTrue(tracker.consumeScrollToTopRequest(1))
        XCTAssertTrue(tracker.consumeScrollToTopRequest(2))
    }

    func testFilteredSnapshotReusesRequestAndStillScrollsToTop() {
        var tracker = VirtualizedTableUpdateTracker()
        let firstSearch = AnyHashable(
            SnapshotToken(contentRevision: 7, query: "sky")
        )
        let unfiltered = AnyHashable(
            SnapshotToken(contentRevision: 7, query: "")
        )
        let secondSearch = AnyHashable(
            SnapshotToken(contentRevision: 7, query: "在")
        )

        XCTAssertTrue(tracker.consumeSnapshotToken(firstSearch))
        XCTAssertTrue(
            tracker.shouldScrollToTop(
                snapshotDidChange: true,
                request: 4
            )
        )
        XCTAssertTrue(tracker.consumeSnapshotToken(unfiltered))
        XCTAssertFalse(
            tracker.shouldScrollToTop(
                snapshotDidChange: true,
                request: nil
            )
        )
        XCTAssertTrue(tracker.consumeSnapshotToken(secondSearch))
        XCTAssertTrue(
            tracker.shouldScrollToTop(
                snapshotDidChange: true,
                request: 4
            )
        )
    }

    @MainActor
    func testScrollToTopNormalizesDeepOffsetAfterFiltering() {
        for filteredCount in [9, 1] {
            let source = VirtualizedTableAppKitDataSource(count: 221)
            let tableView = NSTableView(
                frame: NSRect(x: 0, y: 0, width: 600, height: 500)
            )
            tableView.addTableColumn(
                NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier("column")
                )
            )
            tableView.headerView = nil
            tableView.rowHeight = 72
            tableView.intercellSpacing = NSSize(width: 0, height: 4)
            tableView.dataSource = source
            tableView.delegate = source

            let scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 600, height: 500)
            )
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.contentInsets = NSEdgeInsets(
                top: 6,
                left: 0,
                bottom: 6,
                right: 0
            )
            defer {
                tableView.delegate = nil
                tableView.dataSource = nil
                scrollView.documentView = nil
            }

            tableView.reloadData()
            scrollView.layoutSubtreeIfNeeded()
            tableView.scrollRowToVisible(200)
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)

            source.count = filteredCount
            tableView.reloadData()
            VirtualizedTableScrollGeometry.scrollToTop(
                tableView: tableView,
                scrollView: scrollView
            )
            scrollView.layoutSubtreeIfNeeded()

            let visibleRows = tableView.rows(in: tableView.visibleRect)
            XCTAssertEqual(visibleRows.location, 0)
            XCTAssertGreaterThan(visibleRows.length, 0)
        }
    }

    func testResetAllowsSnapshotAndScrollRequestsToBeAppliedAgain() {
        var tracker = VirtualizedTableUpdateTracker()
        let token = AnyHashable(
            SnapshotToken(contentRevision: 3, query: "travel")
        )
        XCTAssertTrue(tracker.consumeSnapshotToken(token))
        XCTAssertTrue(tracker.consumeScrollToTopRequest(4))

        tracker.reset()

        XCTAssertTrue(tracker.consumeSnapshotToken(token))
        XCTAssertTrue(tracker.consumeScrollToTopRequest(4))
    }

    func testPlaylistCollectionRevisionInvalidatesHostedRows() {
        let initial = LibraryPlaylistRowContentRevision(
            currentItemID: nil,
            unavailableItemsRevision: 0,
            playbackState: .available,
            playlistCollectionRevision: 1,
            playlistMenuEntries: []
        )
        let afterAddingAnItem = LibraryPlaylistRowContentRevision(
            currentItemID: nil,
            unavailableItemsRevision: 0,
            playbackState: .available,
            playlistCollectionRevision: 2,
            playlistMenuEntries: []
        )

        XCTAssertNotEqual(initial, afterAddingAnItem)
    }
}

@MainActor
private final class VirtualizedTableAppKitDataSource: NSObject,
    NSTableViewDataSource, NSTableViewDelegate {
    var count: Int

    init(count: Int) {
        self.count = count
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        NSTextField(labelWithString: "Row \(row)")
    }
}
