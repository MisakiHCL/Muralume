import AppKit
import SwiftUI

private struct VirtualizedTableRowContentRevision: Hashable {
    let model: AnyHashable
    let colorScheme: ColorScheme
    let displayScale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection
    let localeIdentifier: String
    let rowHeight: CGFloat
}

private enum VirtualizedTableMemoryPolicy {
    static let indexCapacityRetentionDivisor = 4
}

struct VirtualizedTableUpdateTracker {
    private(set) var appliedSnapshotToken: AnyHashable?
    private(set) var appliedScrollToTopRequest: UInt64?

    mutating func consumeSnapshotToken(_ token: AnyHashable) -> Bool {
        guard appliedSnapshotToken != token else {
            return false
        }
        appliedSnapshotToken = token
        return true
    }

    mutating func consumeScrollToTopRequest(_ request: UInt64?) -> Bool {
        guard let request else {
            // Clearing search re-arms the same view for a later search. The
            // request counter does not have to change before that first
            // filtered snapshot arrives.
            appliedScrollToTopRequest = nil
            return false
        }
        guard appliedScrollToTopRequest != request else {
            return false
        }
        appliedScrollToTopRequest = request
        return true
    }

    mutating func shouldScrollToTop(
        snapshotDidChange: Bool,
        request: UInt64?
    ) -> Bool {
        let requestDidChange = consumeScrollToTopRequest(request)
        return request != nil && (snapshotDidChange || requestDidChange)
    }

    mutating func reset() {
        appliedSnapshotToken = nil
        appliedScrollToTopRequest = nil
    }
}

@MainActor
enum VirtualizedTableScrollGeometry {
    static func scrollToTop(
        tableView: NSTableView,
        scrollView: NSScrollView
    ) {
        guard tableView.numberOfRows > 0 else {
            return
        }

        // After reloadData shrinks a deeply scrolled table, its clip view can
        // temporarily retain an offset beyond the new document height. Asking
        // NSTableView to reveal row zero first lets AppKit normalize both
        // geometries; writing the clip offset directly can leave zero visible
        // rows until a second search update.
        tableView.scrollRowToVisible(0)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

struct FixedHeightVirtualizedTable<
    Item: Identifiable,
    RowContent: View
>: NSViewRepresentable where Item.ID: Hashable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale

    let items: [Item]
    let snapshotRevision: AnyHashable
    let rowContentRevision: AnyHashable
    let scrollTargetID: Item.ID?
    let scrollToTopRequest: UInt64?
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let verticalContentInset: CGFloat
    private let rowContent: (Item) -> RowContent

    init(
        items: [Item],
        snapshotRevision: some Hashable,
        rowContentRevision: some Hashable,
        scrollTargetID: Item.ID?,
        scrollToTopRequest: UInt64? = nil,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        verticalContentInset: CGFloat,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.snapshotRevision = AnyHashable(snapshotRevision)
        self.rowContentRevision = AnyHashable(rowContentRevision)
        self.scrollTargetID = scrollTargetID
        self.scrollToTopRequest = scrollToTopRequest
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.verticalContentInset = verticalContentInset
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = WidthTrackingTableView()
        tableView.addTableColumn(
            NSTableColumn(
                identifier: FixedHeightVirtualizedTableIdentifier.column
            )
        )
        tableView.tableColumns[0].resizingMask = .autoresizingMask
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsTypeSelect = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false

        tableView.layoutHandler = {
            [weak coordinator = context.coordinator,
             weak tableView,
             weak scrollView] in
            guard let tableView, let scrollView else {
                return
            }
            coordinator?.tableDidLayout(
                tableView: tableView,
                scrollView: scrollView
            )
        }

        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else {
            return
        }

        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: rowSpacing)
        let nativeVerticalInset = max(
            verticalContentInset - (rowSpacing / 2),
            0
        )
        scrollView.contentInsets = NSEdgeInsets(
            top: nativeVerticalInset,
            left: 0,
            bottom: nativeVerticalInset,
            right: 0
        )

        let rowContent = self.rowContent
        let colorScheme = self.colorScheme
        let displayScale = self.displayScale
        let dynamicTypeSize = self.dynamicTypeSize
        let layoutDirection = self.layoutDirection
        let locale = self.locale
        let effectiveRowContentRevision = AnyHashable(
            VirtualizedTableRowContentRevision(
                model: rowContentRevision,
                colorScheme: colorScheme,
                displayScale: displayScale,
                dynamicTypeSize: dynamicTypeSize,
                layoutDirection: layoutDirection,
                localeIdentifier: locale.identifier,
                rowHeight: rowHeight
            )
        )

        context.coordinator.update(
            items: items,
            snapshotRevision: snapshotRevision,
            rowContentRevision: effectiveRowContentRevision,
            scrollTargetID: scrollTargetID,
            scrollToTopRequest: scrollToTopRequest,
            tableView: tableView,
            scrollView: scrollView
        ) { item in
            AnyView(
                rowContent(item)
                    .id(item.id)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.displayScale, displayScale)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.locale, locale)
            )
        }
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(scrollView: scrollView)
    }
}

extension FixedHeightVirtualizedTable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource,
        NSTableViewDelegate {
        private struct ScrollTarget: Equatable {
            let id: Item.ID
            let index: Int
        }

        private var items: [Item] = []
        private var itemIndices: [Item.ID: Int] = [:]
        private var updateTracker = VirtualizedTableUpdateTracker()
        private var appliedRowContentRevision: AnyHashable?
        private var requestedScrollTarget: ScrollTarget?
        private var centeredScrollTarget: ScrollTarget?
        private var makeRowContent: ((Item) -> AnyView)?
        private var pendingCenterTask: Task<Void, Never>?
        private let hostedCells = NSHashTable<HostedTableCell>.weakObjects()
        weak var tableView: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard items.indices.contains(row),
                  let makeRowContent else {
                return nil
            }

            let cell: HostedTableCell
            if let reusedCell = tableView.makeView(
                withIdentifier: FixedHeightVirtualizedTableIdentifier.cell,
                owner: self
            ) as? HostedTableCell {
                cell = reusedCell
            } else {
                cell = HostedTableCell()
                cell.identifier = FixedHeightVirtualizedTableIdentifier.cell
                hostedCells.add(cell)
            }

            cell.setContent(makeRowContent(items[row]))
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            didRemove rowView: NSTableRowView,
            forRow row: Int
        ) {
            (rowView.view(atColumn: 0) as? HostedTableCell)?.clearContent()
        }

        func tableView(
            _ tableView: NSTableView,
            shouldSelectRow row: Int
        ) -> Bool {
            false
        }

        func update(
            items: [Item],
            snapshotRevision: AnyHashable,
            rowContentRevision: AnyHashable,
            scrollTargetID: Item.ID?,
            scrollToTopRequest: UInt64?,
            tableView: NSTableView,
            scrollView: NSScrollView,
            makeRowContent: @escaping (Item) -> AnyView
        ) {
            self.makeRowContent = makeRowContent

            let snapshotDidChange = updateTracker.consumeSnapshotToken(
                snapshotRevision
            )
            if snapshotDidChange {
                applySnapshot(
                    items,
                    to: tableView
                )
                appliedRowContentRevision = rowContentRevision
            } else if appliedRowContentRevision != rowContentRevision {
                appliedRowContentRevision = rowContentRevision
                refreshVisibleRows(in: tableView)
            }

            let target = scrollTargetID.flatMap { id in
                itemIndices[id].map { ScrollTarget(id: id, index: $0) }
            }
            updateScrollTarget(
                target,
                tableView: tableView,
                scrollView: scrollView
            )
            if updateTracker.shouldScrollToTop(
                snapshotDidChange: snapshotDidChange,
                request: scrollToTopRequest
            ) {
                scrollToTop(
                    tableView: tableView,
                    scrollView: scrollView
                )
            }
        }

        func dismantle(scrollView _: NSScrollView) {
            pendingCenterTask?.cancel()
            pendingCenterTask = nil
            (tableView as? WidthTrackingTableView)?.layoutHandler = nil
            requestedScrollTarget = nil
            centeredScrollTarget = nil
            hostedCells.allObjects.forEach { $0.clearContent() }
            makeRowContent = nil
            items.removeAll(keepingCapacity: false)
            itemIndices.removeAll(keepingCapacity: false)
            updateTracker.reset()
            appliedRowContentRevision = nil

            tableView?.delegate = nil
            tableView?.dataSource = nil
            tableView = nil
        }

        private func applySnapshot(
            _ items: [Item],
            to tableView: NSTableView
        ) {
            self.items = items
            let shouldReleaseIndexCapacity = items.count
                < itemIndices.count
                    / VirtualizedTableMemoryPolicy
                        .indexCapacityRetentionDivisor
            itemIndices.removeAll(
                keepingCapacity: !shouldReleaseIndexCapacity
            )
            itemIndices.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                itemIndices[item.id] = index
            }
            tableView.reloadData()
        }

        private func scrollToTop(
            tableView: NSTableView,
            scrollView: NSScrollView
        ) {
            pendingCenterTask?.cancel()
            pendingCenterTask = nil
            // An explicit top request wins over centering the current item
            // until a different target is requested.
            centeredScrollTarget = requestedScrollTarget
            VirtualizedTableScrollGeometry.scrollToTop(
                tableView: tableView,
                scrollView: scrollView
            )
        }

        private func refreshVisibleRows(in tableView: NSTableView) {
            guard let makeRowContent else {
                return
            }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound,
                  visibleRows.length > 0 else {
                return
            }

            let lowerBound = max(visibleRows.location, 0)
            let upperBound = min(NSMaxRange(visibleRows), items.count)
            guard lowerBound < upperBound else {
                return
            }

            for row in lowerBound..<upperBound {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? HostedTableCell else {
                    continue
                }
                cell.setContent(makeRowContent(items[row]))
            }
        }

        private func updateScrollTarget(
            _ target: ScrollTarget?,
            tableView: NSTableView,
            scrollView: NSScrollView
        ) {
            guard requestedScrollTarget != target else {
                centerRequestedRowIfNeeded(
                    tableView: tableView,
                    scrollView: scrollView
                )
                return
            }
            requestedScrollTarget = target
            centeredScrollTarget = nil
            pendingCenterTask?.cancel()
            pendingCenterTask = nil
            centerRequestedRowIfNeeded(
                tableView: tableView,
                scrollView: scrollView
            )
        }

        fileprivate func tableDidLayout(
            tableView: NSTableView,
            scrollView: NSScrollView
        ) {
            guard requestedScrollTarget != centeredScrollTarget,
                  pendingCenterTask == nil else {
                return
            }
            pendingCenterTask = Task {
                @MainActor [weak self, weak tableView, weak scrollView] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      let tableView,
                      let scrollView else {
                    return
                }
                self.pendingCenterTask = nil
                self.centerRequestedRowIfNeeded(
                    tableView: tableView,
                    scrollView: scrollView
                )
            }
        }

        private func centerRequestedRowIfNeeded(
            tableView: NSTableView,
            scrollView: NSScrollView
        ) {
            guard let target = requestedScrollTarget,
                  centeredScrollTarget != target,
                  items.indices.contains(target.index),
                  items[target.index].id == target.id else {
                return
            }

            tableView.scrollRowToVisible(target.index)
            guard centerRow(
                at: target.index,
                tableView: tableView,
                scrollView: scrollView
            ) else {
                return
            }
            centeredScrollTarget = target
        }

        private func centerRow(
            at index: Int,
            tableView: NSTableView,
            scrollView: NSScrollView
        ) -> Bool {
            guard items.indices.contains(index) else {
                return false
            }

            let clipView = scrollView.contentView
            let viewportHeight = clipView.bounds.height
            guard viewportHeight > 0 else {
                return false
            }

            let rowRectangle = tableView.rect(ofRow: index)
            let minimumOffset = -scrollView.contentInsets.top
            let maximumOffset = max(
                tableView.bounds.height
                    - viewportHeight
                    + scrollView.contentInsets.bottom,
                minimumOffset
            )
            let centeredOffset = rowRectangle.midY - (viewportHeight / 2)
            let verticalOffset = min(
                max(centeredOffset, minimumOffset),
                maximumOffset
            )

            clipView.scroll(
                to: NSPoint(x: clipView.bounds.minX, y: verticalOffset)
            )
            scrollView.reflectScrolledClipView(clipView)
            return true
        }
    }
}

@MainActor
private final class WidthTrackingTableView: NSTableView {
    var layoutHandler: (() -> Void)?
    private var isInvokingLayoutHandler = false

    override func layout() {
        super.layout()
        synchronizeColumnWidth()

        guard !isInvokingLayoutHandler else {
            return
        }
        isInvokingLayoutHandler = true
        defer {
            isInvokingLayoutHandler = false
        }
        layoutHandler?()
    }

    private func synchronizeColumnWidth() {
        guard let column = tableColumns.first else {
            return
        }
        let availableWidth = enclosingScrollView?.contentSize.width
            ?? bounds.width
        guard availableWidth > 0,
              abs(column.width - availableWidth) > 0.5 else {
            return
        }
        column.width = availableWidth
    }
}

@MainActor
private final class HostedTableCell: NSTableCellView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setContent(_ content: AnyView) {
        hostingView.rootView = content
    }

    func clearContent() {
        hostingView.rootView = AnyView(EmptyView())
    }
}

private enum FixedHeightVirtualizedTableIdentifier {
    static let column = NSUserInterfaceItemIdentifier(
        "muralume.virtualizedTable.column"
    )
    static let cell = NSUserInterfaceItemIdentifier(
        "muralume.virtualizedTable.cell"
    )
}
