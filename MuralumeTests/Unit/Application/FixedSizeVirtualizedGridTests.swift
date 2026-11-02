import AppKit
import SwiftUI
import XCTest
@testable import Muralume

final class FixedSizeVirtualizedGridTests: XCTestCase {
    func testUnchangedSnapshotDoesNotRebuildLargeIdentityIndex() {
        let counter = GridIdentityReadCounter()
        let items = (0..<10_000).map {
            GridCountedItem(identity: $0, counter: counter)
        }
        var snapshot = VirtualizedGridSnapshot<GridCountedItem>()
        XCTAssertTrue(snapshot.apply(items, revision: AnyHashable(1)))
        XCTAssertEqual(counter.readCount, items.count)
        counter.readCount = 0

        XCTAssertFalse(snapshot.apply(items, revision: AnyHashable(1)))
        XCTAssertEqual(snapshot.index(for: 9_999), 9_999)
        XCTAssertEqual(counter.readCount, 0)

        XCTAssertTrue(snapshot.apply(Array(items.suffix(2)), revision: AnyHashable(2)))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertNil(snapshot.index(for: 0))
        XCTAssertEqual(snapshot.index(for: 9_999), 1)
        snapshot.reset()
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNil(snapshot.index(for: 9_999))
        XCTAssertTrue(snapshot.apply(items, revision: AnyHashable(2)))
    }

    @MainActor
    func testCollectionCreatesContentOnlyForVisibleItemsAndReleasesProvider() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        var contentRequests = 0
        var resource: GridRetainedResource? = GridRetainedResource()
        weak var observedResource = resource
        fixture.update(items: (0..<10_000).map(GridTestItem.init), revision: 1) {
            [resource = resource!] item in
            contentRequests += 1
            return AnyView(Text("\(resource.value) \(item.id)"))
        }
        fixture.layout()
        fixture.coordinator.refreshVisibleItems(in: fixture.collectionView)

        XCTAssertGreaterThan(contentRequests, 0)
        XCTAssertLessThan(contentRequests, 100)
        XCTAssertLessThan(fixture.collectionView.visibleItems().count, 100)
        XCTAssertFalse(fixture.collectionView.isSelectable)
        resource = nil
        XCTAssertNotNil(observedResource)

        fixture.dismantle()
        XCTAssertNil(observedResource)
        XCTAssertNil(fixture.collectionView.dataSource)
        XCTAssertNil(fixture.collectionView.delegate)
    }

    @MainActor
    func testFilteringDeeplyScrolledCollectionRestoresFirstItem() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        fixture.update(items: (0..<300).map(GridTestItem.init), revision: 1)
        fixture.layout()
        fixture.collectionView.scrollToItems(
            at: [IndexPath(item: 280, section: 0)], scrollPosition: .top
        )
        fixture.layout()
        XCTAssertGreaterThan(fixture.scrollView.contentView.bounds.minY, 0)

        fixture.update(
            items: (0..<2).map(GridTestItem.init), revision: 2,
            scrollToTopRequest: 1
        )
        fixture.layout()
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertTrue(
            fixture.collectionView.indexPathsForVisibleItems().contains(
                IndexPath(item: 0, section: 0)
            )
        )
    }

    @MainActor
    func testEndDisplayingAndReuseDiscardHostedContentIdentity() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        let item = VirtualizedGridItem()
        item.setContent(AnyView(Text("Video")), id: AnyHashable(7), revision: AnyHashable(1))
        XCTAssertFalse(item.needsContent(id: AnyHashable(7), revision: AnyHashable(1)))
        fixture.coordinator.collectionView(
            fixture.collectionView, didEndDisplaying: item,
            forRepresentedObjectAt: IndexPath(item: 7, section: 0)
        )
        XCTAssertTrue(item.needsContent(id: AnyHashable(7), revision: AnyHashable(1)))
        item.setContent(AnyView(Text("Video")), id: AnyHashable(7), revision: AnyHashable(1))
        item.prepareForReuse()
        XCTAssertTrue(item.needsContent(id: AnyHashable(7), revision: AnyHashable(1)))
    }

    @MainActor
    func testDataSourceAndWillDisplayPopulateBeforeItemFrameIsAssigned() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        fixture.scrollView.frame = .zero
        fixture.collectionView.frame = .zero
        var requestedIDs: [Int] = []
        fixture.update(items: (0..<11).map(GridTestItem.init), revision: 1) { item in
            requestedIDs.append(item.id)
            return AnyView(Color.blue.frame(width: 88, height: 88))
        }
        requestedIDs.removeAll()

        let indexPath = IndexPath(item: 0, section: 0)
        let item = fixture.coordinator.collectionView(
            fixture.collectionView, itemForRepresentedObjectAt: indexPath
        )
        XCTAssertEqual(requestedIDs, [0], "The native data-source request must return configured content")
        // AppKit is allowed to request/display an item before assigning its
        // final frame. A zero frame must not veto that native display request.
        item.view.frame = .zero
        fixture.coordinator.collectionView(
            fixture.collectionView, willDisplay: item,
            forRepresentedObjectAt: indexPath
        )
        XCTAssertEqual(requestedIDs, [0])
    }

    @MainActor
    func testWillDisplayDoesNotClearReusedItemBeforeFrameAssignment() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        fixture.update(items: (0..<11).map(GridTestItem.init), revision: 1)
        let item = VirtualizedGridItem()
        item.setContent(AnyView(Color.blue), id: AnyHashable(0), revision: AnyHashable(1))
        // Reused views may still carry their previous offscreen position when
        // AppKit announces that it is about to display the new represented item.
        item.view.frame = NSRect(x: -1_000, y: -1_000, width: 88, height: 88)
        fixture.coordinator.collectionView(
            fixture.collectionView, willDisplay: item,
            forRepresentedObjectAt: IndexPath(item: 0, section: 0)
        )
        XCTAssertFalse(item.needsContent(id: AnyHashable(0), revision: AnyHashable(1)))
    }

    @MainActor
    func testProductionHostingMountsZeroSizedGridWithoutAnotherSnapshot() throws {
        let fixture = HostedGridFixture(scrollTargetID: 10)
        defer { fixture.close() }
        XCTAssertTrue(fixture.waitUntil { fixture.collectionView != nil })
        let collection = try XCTUnwrap(fixture.collectionView)
        XCTAssertEqual(collection.enclosingScrollView?.bounds.size, .zero)

        fixture.mount()

        XCTAssertTrue(fixture.waitUntil {
            fixture.hasVisibleContent && fixture.isFullyVisible(item: 10)
        })
        XCTAssertGreaterThan(collection.frame.height, 0)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 11)
        XCTAssertFalse(fixture.recorder.visibleIDs.isEmpty)
    }

    @MainActor
    func testFirstNativeLayoutCentersTargetBeforeAnotherRunLoop() throws {
        let fixture = HostedGridFixture(scrollTargetID: 10)
        defer { fixture.close() }
        XCTAssertTrue(fixture.waitUntil { fixture.collectionView != nil })

        fixture.mount()

        XCTAssertTrue(fixture.isFullyVisible(item: 10),
                      "The first mounted layout must already show the target, without a later Task scrolling it")
    }

    @MainActor
    func testViewportReconciliationKeepsUserScrollAndExplicitSearchTop() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        let items = (0..<300).map(GridTestItem.init)
        fixture.scrollView.setFrameSize(CGSize(width: 400, height: 10))
        fixture.update(items: items, revision: 1, scrollTargetID: 200)
        fixture.layout()
        fixture.scrollView.setFrameSize(CGSize(width: 400, height: 320))
        fixture.layout()
        let target = IndexPath(item: 200, section: 0)
        XCTAssertTrue(fixture.collectionView.indexPathsForVisibleItems().contains(target))

        fixture.scrollView.contentView.scroll(to: .zero)
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
        fixture.scrollView.setFrameSize(CGSize(width: 400, height: 240))
        fixture.update(items: items, revision: 1, scrollTargetID: 200)
        fixture.layout()
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 0.5)

        fixture.update(items: items, revision: 1, scrollTargetID: 201, scrollToTopRequest: 1)
        fixture.layout()
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testAppendingSnapshotKeepsTrailingTargetOffsetUntilTargetChanges() {
        let fixture = GridAppKitFixture()
        defer { fixture.dismantle() }
        fixture.update(items: (0..<221).map(GridTestItem.init), revision: 1, scrollTargetID: 220)
        fixture.layout()
        let originalOffset = fixture.scrollView.contentView.bounds.minY
        XCTAssertGreaterThan(originalOffset, 0)

        let appended = (0..<300).map(GridTestItem.init)
        fixture.update(items: appended, revision: 2, scrollTargetID: 220)
        fixture.layout()
        XCTAssertEqual(fixture.scrollView.contentView.bounds.minY, originalOffset, accuracy: 0.5)

        fixture.update(items: appended, revision: 3, scrollTargetID: 230)
        fixture.layout()
        let targetFrame = fixture.collectionView.layoutAttributesForItem(
            at: IndexPath(item: 230, section: 0)
        )?.frame
        XCTAssertNotNil(targetFrame)
        if let targetFrame {
            XCTAssertTrue(fixture.collectionView.visibleRect.contains(targetFrame),
                          "Target frame \(targetFrame) must be inside the current viewport \(fixture.collectionView.visibleRect)")
        }
        XCTAssertNotEqual(fixture.scrollView.contentView.bounds.minY, originalOffset, accuracy: 0.5)
    }

    @MainActor
    func testProductionHostingRendersAfterHideAndReopenWithoutSnapshotChange() throws {
        let fixture = HostedGridFixture()
        defer { fixture.close() }
        fixture.mount()
        XCTAssertTrue(fixture.waitUntil { fixture.hasVisibleContent })
        let originalCollection = try XCTUnwrap(fixture.collectionView)

        fixture.presentation.isPresented = false
        XCTAssertTrue(fixture.waitUntil { fixture.collectionView == nil })
        XCTAssertTrue(fixture.waitUntil { fixture.recorder.visibleIDs.isEmpty })
        XCTAssertNil(originalCollection.dataSource)

        fixture.presentation.isPresented = true
        XCTAssertTrue(fixture.waitUntil { fixture.hasVisibleContent })
        let reopenedCollection = try XCTUnwrap(fixture.collectionView)
        XCTAssertFalse(originalCollection === reopenedCollection)
        XCTAssertEqual(reopenedCollection.numberOfItems(inSection: 0), 11)
    }
}

private struct GridTestItem: Identifiable {
    let id: Int
}

private final class GridRetainedResource {
    let value = "Video"
}

private final class GridIdentityReadCounter {
    var readCount = 0
}

private struct GridCountedItem: Identifiable {
    let identity: Int
    let counter: GridIdentityReadCounter
    var id: Int {
        counter.readCount += 1
        return identity
    }
}

@MainActor
private final class GridAppKitFixture {
    let coordinator = FixedSizeVirtualizedGrid<GridTestItem, Text>.Coordinator()
    let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))

    init() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 100)
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.register(VirtualizedGridItem.self, forItemWithIdentifier: VirtualizedGridItem.identifier)
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        coordinator.collectionView = collectionView
    }

    func update(
        items: [GridTestItem], revision: Int, scrollTargetID: Int? = nil,
        scrollToTopRequest: UInt64? = nil,
        content: @escaping (GridTestItem) -> AnyView = { AnyView(Text("\($0.id)")) }
    ) {
        coordinator.update(
            items: items, snapshotRevision: AnyHashable(revision),
            contentRevision: AnyHashable(revision), scrollTargetID: scrollTargetID,
            scrollToTopRequest: scrollToTopRequest,
            collectionView: collectionView, scrollView: scrollView,
            makeContent: content
        )
    }

    func layout() {
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        coordinator.didLayout(collectionView, scrollView: scrollView)
    }

    func dismantle() {
        coordinator.dismantle(scrollView: scrollView)
        scrollView.documentView = nil
    }
}

@MainActor
private final class HostedGridPresentation: ObservableObject {
    @Published var isPresented = true
    let scrollTargetID: Int?

    init(scrollTargetID: Int?) { self.scrollTargetID = scrollTargetID }
}

@MainActor
private final class HostedGridRecorder {
    var visibleIDs: Set<Int> = []
}

private struct HostedGridRow: View {
    let item: GridTestItem
    let recorder: HostedGridRecorder

    var body: some View {
        Color.blue
            .frame(width: 88, height: 88)
            .onAppear { recorder.visibleIDs.insert(item.id) }
            .onDisappear { recorder.visibleIDs.remove(item.id) }
    }
}

private struct HostedGridContent: View {
    @ObservedObject var presentation: HostedGridPresentation
    let recorder: HostedGridRecorder

    var body: some View {
        if presentation.isPresented {
            FixedSizeVirtualizedGrid(
                items: (0..<11).map(GridTestItem.init),
                snapshotRevision: 1, rowContentRevision: 1,
                scrollTargetID: presentation.scrollTargetID,
                itemSize: CGSize(width: 88, height: 88), spacing: 4
            ) { item in
                HostedGridRow(item: item, recorder: recorder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private final class HostedGridFixture {
    let presentation: HostedGridPresentation
    let recorder = HostedGridRecorder()
    let hostingView: NSHostingView<HostedGridContent>
    private var window: NSWindow?

    init(scrollTargetID: Int? = nil) {
        presentation = HostedGridPresentation(scrollTargetID: scrollTargetID)
        hostingView = NSHostingView(rootView: HostedGridContent(
            presentation: presentation, recorder: recorder
        ))
        hostingView.sizingOptions = []
        hostingView.frame = .zero
        hostingView.layoutSubtreeIfNeeded()
    }

    var collectionView: NSCollectionView? {
        firstCollection(in: hostingView)
    }

    var hasVisibleContent: Bool {
        guard let collectionView,
              !collectionView.visibleItems().isEmpty else { return false }
        let visibleIDs = collectionView.indexPathsForVisibleItems().map(\.item)
        return visibleIDs.contains { recorder.visibleIDs.contains($0) }
    }

    func isFullyVisible(item: Int) -> Bool {
        guard let collectionView,
              let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: item, section: 0)
              ) else { return false }
        return collectionView.visibleRect.contains(attributes.frame)
    }

    func mount() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        self.window = window
        hostingView.layoutSubtreeIfNeeded()
    }

    func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            hostingView.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        } while Date() < deadline
        return condition()
    }

    func close() {
        window?.contentView = nil
        window?.close()
        window = nil
    }

    private func firstCollection(in view: NSView) -> NSCollectionView? {
        if let collection = view as? NSCollectionView { return collection }
        for child in view.subviews {
            if let collection = firstCollection(in: child) { return collection }
        }
        return nil
    }
}
