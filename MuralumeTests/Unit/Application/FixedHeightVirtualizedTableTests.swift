import AppKit
import SwiftUI
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

    @MainActor
    func testFirstCenterWaitsForViewportAndCompletesInsideNativeLayout() {
        let fixture = TableCenteringFixture(size: .zero)
        defer { fixture.dismantle() }
        fixture.update(target: 200)
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0,
                       "A measuring viewport must not first reveal the target at a different offset")

        fixture.layout(size: CGSize(width: 600, height: 500))
        fixture.assertCentered(200)
    }

    @MainActor
    func testMeasuringViewportReconcilesWithoutTakingBackUserScroll() {
        let fixture = TableCenteringFixture(size: CGSize(width: 600, height: 10))
        defer { fixture.dismantle() }
        fixture.update(target: 200)
        fixture.layout(size: CGSize(width: 600, height: 10))
        fixture.assertCentered(200)

        fixture.layout(size: CGSize(width: 600, height: 500))
        fixture.assertCentered(200)
        fixture.scrollView.contentView.scroll(to: .zero)
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
        fixture.update(target: 200)
        fixture.layout(size: CGSize(width: 600, height: 400))
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testNativeDocumentHeightNormalizationCentersWithinTheSameLayout() {
        let fixture = TableCenteringFixture(size: CGSize(width: 600, height: 500))
        defer { fixture.dismantle() }
        fixture.update(target: 200)
        fixture.tableView.setFrameSize(CGSize(width: 600, height: 0))
        // Asking NSTableView for row geometry normalizes its zero measuring
        // frame to the real row extent. Centering uses this same native extent
        // and must not need another run-loop turn to repair its first position.
        let lastRow = fixture.tableView.rect(ofRow: 220)
        XCTAssertGreaterThan(lastRow.height, 0)
        XCTAssertGreaterThanOrEqual(fixture.tableView.bounds.height, lastRow.maxY)
        fixture.coordinator.tableDidLayout(tableView: fixture.tableView, scrollView: fixture.scrollView)
        fixture.assertCentered(200)
        let firstLayoutOffset = fixture.scrollView.contentView.bounds.minY

        fixture.layout(size: CGSize(width: 600, height: 500))
        fixture.assertCentered(200)
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, firstLayoutOffset, accuracy: 0.5)
    }

    @MainActor
    func testExplicitSearchTopWinsOverInitialCenterAndViewportChanges() {
        let fixture = TableCenteringFixture(size: CGSize(width: 600, height: 10))
        defer { fixture.dismantle() }
        fixture.update(target: 200, scrollToTopRequest: 1)
        fixture.layout(size: CGSize(width: 600, height: 500))
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testAppendingSnapshotDoesNotRecenterAnAlreadyPositionedTrailingRow() {
        let fixture = TableCenteringFixture(size: CGSize(width: 600, height: 500))
        defer { fixture.dismantle() }
        fixture.update(target: 220)
        fixture.layout(size: CGSize(width: 600, height: 500))
        let originalOffset = fixture.scrollView.contentView.bounds.minY
        XCTAssertGreaterThan(originalOffset, 0)

        fixture.update(target: 220, count: 260, revision: 2)
        fixture.layout(size: CGSize(width: 600, height: 500))
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, originalOffset, accuracy: 0.5)

        fixture.update(target: 230, count: 260, revision: 3)
        fixture.layout(size: CGSize(width: 600, height: 500))
        fixture.assertCentered(230)
    }
}

private struct TableCenteringItem: Identifiable {
    let id: Int
}

@MainActor
private final class TableCenteringFixture {
    let coordinator = FixedHeightVirtualizedTable<TableCenteringItem, Text>.Coordinator()
    let tableView = NSTableView()
    let scrollView: NSScrollView

    init(size: CGSize) {
        scrollView = NSScrollView(frame: CGRect(origin: .zero, size: size))
        tableView.addTableColumn(NSTableColumn(identifier: .init("column")))
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = CGSize(width: 0, height: 4)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        scrollView.documentView = tableView
        scrollView.automaticallyAdjustsContentInsets = false
        coordinator.tableView = tableView
    }

    func update(target: Int, count: Int = 221, revision: Int = 1, scrollToTopRequest: UInt64? = nil) {
        coordinator.update(
            items: (0..<count).map(TableCenteringItem.init), snapshotRevision: AnyHashable(revision),
            rowContentRevision: AnyHashable(1), scrollTargetID: target,
            scrollToTopRequest: scrollToTopRequest, tableView: tableView, scrollView: scrollView,
            makeRowContent: { AnyView(Text("Row \($0.id)")) }
        )
    }

    func layout(size: CGSize) {
        scrollView.setFrameSize(size)
        scrollView.layoutSubtreeIfNeeded()
        // Model the document geometry AppKit resolves after reloadData. The
        // stale-document test deliberately invokes the earlier layout phase.
        tableView.setFrameSize(CGSize(width: size.width, height: tableView.rect(ofRow: tableView.numberOfRows - 1).maxY))
        tableView.layoutSubtreeIfNeeded()
        coordinator.tableDidLayout(tableView: tableView, scrollView: scrollView)
    }

    func assertCentered(_ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = scrollView.contentView.bounds
        let expected = tableView.rect(ofRow: row).midY - bounds.height / 2
        XCTAssertEqual(bounds.minY, expected, accuracy: 0.5, file: file, line: line)
    }

    func dismantle() {
        coordinator.dismantle(scrollView: scrollView)
        scrollView.documentView = nil
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
