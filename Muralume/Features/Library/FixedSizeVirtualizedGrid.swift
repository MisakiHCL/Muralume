import AppKit
import SwiftUI

struct VirtualizedGridSnapshot<Item: Identifiable> where Item.ID: Hashable {
    private(set) var items: [Item] = []
    private(set) var revision: AnyHashable?
    private var indices: [Item.ID: Int] = [:]

    mutating func apply(_ items: [Item], revision: AnyHashable) -> Bool {
        guard self.revision != revision else { return false }
        self.revision = revision
        self.items = items
        let retainsCapacity = items.count >= indices.count / 4
        indices.removeAll(keepingCapacity: retainsCapacity)
        indices.reserveCapacity(items.count)
        for (index, item) in items.enumerated() { indices[item.id] = index }
        return true
    }

    func index(for id: Item.ID) -> Int? { indices[id] }

    mutating func reset() {
        items.removeAll(keepingCapacity: false)
        indices.removeAll(keepingCapacity: false)
        revision = nil
    }
}

private struct VirtualizedGridContentRevision: Hashable {
    let model: AnyHashable
    let colorScheme: ColorScheme
    let displayScale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection
    let localeIdentifier: String
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let differentiateWithoutColor: Bool
    let width: CGFloat
    let height: CGFloat
}

struct FixedSizeVirtualizedGrid<Item: Identifiable, RowContent: View>:
    NSViewRepresentable where Item.ID: Hashable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    let items: [Item]
    let snapshotRevision: AnyHashable
    let rowContentRevision: AnyHashable
    let scrollTargetID: Item.ID?
    let scrollToTopRequest: UInt64?
    let itemSize: CGSize
    let spacing: CGFloat
    private let rowContent: (Item) -> RowContent

    init(
        items: [Item],
        snapshotRevision: some Hashable,
        rowContentRevision: some Hashable,
        scrollTargetID: Item.ID?,
        scrollToTopRequest: UInt64? = nil,
        itemSize: CGSize,
        spacing: CGFloat,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.snapshotRevision = AnyHashable(snapshotRevision)
        self.rowContentRevision = AnyHashable(rowContentRevision)
        self.scrollTargetID = scrollTargetID
        self.scrollToTopRequest = scrollToTopRequest
        self.itemSize = itemSize
        self.spacing = spacing
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = VirtualizedGridCollectionView()
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.autoresizingMask = [.width]
        collectionView.register(
            VirtualizedGridItem.self,
            forItemWithIdentifier: VirtualizedGridItem.identifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator

        let scrollView = VirtualizedGridScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        collectionView.layoutHandler = {
            [weak coordinator = context.coordinator, weak collectionView,
             weak scrollView] in
            guard let collectionView, let scrollView else { return }
            coordinator?.didLayout(collectionView, scrollView: scrollView)
        }
        scrollView.visibilityHandler = {
            [weak coordinator = context.coordinator, weak collectionView] in
            guard let collectionView else { return }
            coordinator?.refreshVisibleItems(in: collectionView)
        }
        scrollView.layoutHandler = {
            [weak coordinator = context.coordinator, weak collectionView,
             weak scrollView] in
            guard let collectionView, let scrollView else { return }
            coordinator?.didLayout(collectionView, scrollView: scrollView)
        }
        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? NSCollectionView,
              let layout = collectionView.collectionViewLayout
                as? NSCollectionViewFlowLayout else { return }
        let effectiveSize = CGSize(
            width: max(itemSize.width, 1), height: max(itemSize.height, 1)
        )
        if layout.itemSize != effectiveSize
            || layout.minimumLineSpacing != spacing
            || layout.minimumInteritemSpacing != spacing {
            layout.itemSize = effectiveSize
            layout.minimumLineSpacing = max(spacing, 0)
            layout.minimumInteritemSpacing = max(spacing, 0)
            layout.invalidateLayout()
        }

        let rowContent = rowContent
        let colorScheme = colorScheme
        let displayScale = displayScale
        let dynamicTypeSize = dynamicTypeSize
        let layoutDirection = layoutDirection
        let locale = locale
        let reduceMotion = reduceMotion
        let reduceTransparency = reduceTransparency
        let colorSchemeContrast = colorSchemeContrast
        let differentiateWithoutColor = differentiateWithoutColor
        let environment = context.environment
        let contentRevision = AnyHashable(VirtualizedGridContentRevision(
            model: rowContentRevision,
            colorScheme: colorScheme,
            displayScale: displayScale,
            dynamicTypeSize: dynamicTypeSize,
            layoutDirection: layoutDirection,
            localeIdentifier: locale.identifier,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased,
            differentiateWithoutColor: differentiateWithoutColor,
            width: effectiveSize.width,
            height: effectiveSize.height
        ))
        context.coordinator.update(
            items: items, snapshotRevision: snapshotRevision,
            contentRevision: contentRevision,
            scrollTargetID: scrollTargetID,
            scrollToTopRequest: scrollToTopRequest,
            collectionView: collectionView, scrollView: scrollView
        ) { item in
            AnyView(rowContent(item)
                .id(item.id)
                .environment(\.self, environment))
        }
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView, coordinator: Coordinator
    ) {
        coordinator.dismantle(scrollView: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource,
        NSCollectionViewDelegate {
        private struct ScrollTarget: Equatable {
            let id: Item.ID
            let index: Int
        }
        private var snapshot = VirtualizedGridSnapshot<Item>()
        private var updateTracker = VirtualizedTableUpdateTracker()
        private var contentRevision: AnyHashable?
        private var makeContent: ((Item) -> AnyView)?
        private var requestedTarget: ScrollTarget?
        private var centeredTarget: ScrollTarget?
        private var pendingScrollTask: Task<Void, Never>?
        private let hostedItems = NSHashTable<VirtualizedGridItem>.weakObjects()
        weak var collectionView: NSCollectionView?

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int { snapshot.items.count }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: VirtualizedGridItem.identifier, for: indexPath
            )
            if let item = item as? VirtualizedGridItem { hostedItems.add(item) }
            configure(item, at: indexPath, in: collectionView)
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            configure(item, at: indexPath, in: collectionView)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) { (item as? VirtualizedGridItem)?.clearContent() }

        func update(
            items: [Item], snapshotRevision: AnyHashable,
            contentRevision: AnyHashable,
            scrollTargetID: Item.ID?, scrollToTopRequest: UInt64?,
            collectionView: NSCollectionView, scrollView: NSScrollView,
            makeContent: @escaping (Item) -> AnyView
        ) {
            self.makeContent = makeContent
            self.contentRevision = contentRevision
            let changed = snapshot.apply(items, revision: snapshotRevision)
            if changed {
                hostedItems.allObjects.forEach { $0.clearContent() }
                collectionView.reloadData()
            }
            refreshVisibleItems(in: collectionView)
            let target = scrollTargetID.flatMap { id in
                snapshot.index(for: id).map { ScrollTarget(id: id, index: $0) }
            }
            if requestedTarget != target {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                requestedTarget = target
                centeredTarget = nil
            }
            if updateTracker.shouldScrollToTop(
                snapshotDidChange: changed, request: scrollToTopRequest
            ) {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
                centeredTarget = requestedTarget
                VirtualizedGridScrollGeometry.scrollToTop(
                    collectionView: collectionView, scrollView: scrollView
                )
            } else {
                didLayout(collectionView, scrollView: scrollView)
            }
        }

        func refreshVisibleItems(in collectionView: NSCollectionView) {
            for item in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item) else {
                    continue
                }
                configure(item, at: indexPath, in: collectionView)
            }
        }

        private func configure(
            _ item: NSCollectionViewItem, at indexPath: IndexPath,
            in collectionView: NSCollectionView
        ) {
            guard let item = item as? VirtualizedGridItem else { return }
            // Data-source/willDisplay requests are AppKit's visibility truth.
            // The item can still have a zero or old offscreen frame here.
            guard snapshot.items.indices.contains(indexPath.item),
                  let makeContent, let contentRevision else {
                item.clearContent()
                return
            }
            let model = snapshot.items[indexPath.item]
            let id = AnyHashable(model.id)
            guard item.needsContent(id: id, revision: contentRevision) else {
                return
            }
            item.setContent(makeContent(model), id: id, revision: contentRevision)
        }

        func didLayout(
            _ collectionView: NSCollectionView, scrollView: NSScrollView
        ) {
            VirtualizedGridScrollGeometry.centerColumns(
                collectionView: collectionView, scrollView: scrollView
            )
            VirtualizedGridScrollGeometry.synchronizeDocumentSize(
                collectionView: collectionView, scrollView: scrollView
            )
            refreshVisibleItems(in: collectionView)
            guard requestedTarget != centeredTarget,
                  pendingScrollTask == nil else { return }
            pendingScrollTask = Task {
                @MainActor [weak self, weak collectionView, weak scrollView] in
                await Task.yield()
                guard !Task.isCancelled, let self,
                      let collectionView, let scrollView else { return }
                self.pendingScrollTask = nil
                guard let target = self.requestedTarget,
                      self.centeredTarget != target,
                      scrollView.contentSize.width > 0,
                      scrollView.contentSize.height > 0,
                      self.snapshot.index(for: target.id) == target.index else {
                    return
                }
                let indexPath = IndexPath(item: target.index, section: 0)
                guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      attributes.frame.width > 0, attributes.frame.height > 0 else {
                    return
                }
                collectionView.scrollToItems(
                    at: [indexPath],
                    scrollPosition: .centeredVertically
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
                if collectionView.visibleRect.intersects(attributes.frame) {
                    self.centeredTarget = target
                }
            }
        }

        func dismantle(scrollView: NSScrollView) {
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
            (collectionView as? VirtualizedGridCollectionView)?.layoutHandler = nil
            (scrollView as? VirtualizedGridScrollView)?.visibilityHandler = nil
            (scrollView as? VirtualizedGridScrollView)?.layoutHandler = nil
            hostedItems.allObjects.forEach { $0.clearContent() }
            hostedItems.removeAllObjects()
            makeContent = nil
            contentRevision = nil
            requestedTarget = nil
            centeredTarget = nil
            snapshot.reset()
            updateTracker.reset()
            collectionView?.delegate = nil
            collectionView?.dataSource = nil
            collectionView?.prefetchDataSource = nil
            collectionView = nil
        }
    }
}

@MainActor
enum VirtualizedGridScrollGeometry {
    static func centerColumns(
        collectionView: NSCollectionView, scrollView: NSScrollView
    ) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
              scrollView.contentSize.width > 0, layout.itemSize.width > 0 else { return }
        let width = scrollView.contentSize.width
        let spacing = layout.minimumInteritemSpacing
        let columns = max(Int((width + spacing) / (layout.itemSize.width + spacing)), 1)
        let usedWidth = CGFloat(columns) * layout.itemSize.width + CGFloat(columns - 1) * spacing
        let inset = max((width - usedWidth) / 2, 0)
        guard abs(layout.sectionInset.left - inset) > 0.25
            || abs(layout.sectionInset.right - inset) > 0.25 else { return }
        // Flow layout otherwise spreads spare width between columns. Keep the
        // requested gap and center the complete grid inside the actual viewport.
        layout.sectionInset = NSEdgeInsets(
            top: layout.sectionInset.top, left: inset,
            bottom: layout.sectionInset.bottom, right: inset
        )
        layout.invalidateLayout()
    }

    static func synchronizeDocumentSize(
        collectionView: NSCollectionView, scrollView: NSScrollView
    ) {
        guard let layout = collectionView.collectionViewLayout,
              scrollView.contentSize.width > 0 else { return }
        let size = NSSize(
            width: scrollView.contentSize.width,
            height: max(layout.collectionViewContentSize.height, scrollView.contentSize.height)
        )
        if collectionView.frame.size != size {
            collectionView.setFrameSize(size)
        }
    }

    static func scrollToTop(
        collectionView: NSCollectionView, scrollView: NSScrollView
    ) {
        collectionView.layoutSubtreeIfNeeded()
        if collectionView.numberOfSections > 0,
           collectionView.numberOfItems(inSection: 0) > 0 {
            collectionView.scrollToItems(
                at: [IndexPath(item: 0, section: 0)], scrollPosition: .top
            )
        }
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: -scrollView.contentInsets.top)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

@MainActor
private final class VirtualizedGridCollectionView: NSCollectionView {
    var layoutHandler: (() -> Void)?
    private var invokesHandler = false

    override func layout() {
        super.layout()
        guard !invokesHandler else { return }
        invokesHandler = true
        defer { invokesHandler = false }
        layoutHandler?()
    }
}

@MainActor
private final class VirtualizedGridScrollView: NSScrollView {
    var visibilityHandler: (() -> Void)?
    var layoutHandler: (() -> Void)?
    private var invokesHandler = false
    private var invokesLayoutHandler = false

    override func layout() {
        super.layout()
        guard !invokesLayoutHandler else { return }
        invokesLayoutHandler = true
        defer { invokesLayoutHandler = false }
        layoutHandler?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { invalidateViewportLayout() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        invalidateViewportLayout()
    }

    private func invalidateViewportLayout() {
        // A representable can be updated while its viewport is still zero.
        // Reconcile through native lifecycle events once it joins a window or
        // becomes visible; do not wait for a new model revision or a retry timer.
        needsLayout = true
        documentView?.needsLayout = true
        (documentView as? NSCollectionView)?.collectionViewLayout?.invalidateLayout()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard !invokesHandler else { return }
        invokesHandler = true
        defer { invokesHandler = false }
        visibilityHandler?()
    }
}

@MainActor
final class VirtualizedGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("muralume.virtualizedGrid.item")
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var contentID: AnyHashable?
    private var contentRevision: AnyHashable?

    override func loadView() {
        view = NSView()
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }

    func needsContent(id: AnyHashable, revision: AnyHashable) -> Bool {
        contentID != id || contentRevision != revision
    }

    func setContent(_ content: AnyView, id: AnyHashable, revision: AnyHashable) {
        _ = view
        contentID = id
        contentRevision = revision
        hostingView.rootView = content
    }

    func clearContent() {
        hostingView.rootView = AnyView(EmptyView())
        contentID = nil
        contentRevision = nil
    }
}
