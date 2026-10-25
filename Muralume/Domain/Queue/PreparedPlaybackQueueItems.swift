/// Immutable, session-owned queue membership prepared away from the UI executor.
/// The ordered values and their first positions share copy-on-write storage.
/// Callers replace the value when membership or order changes and release it
/// with their library snapshot; no global or cross-library cache is retained.
struct PreparedPlaybackQueueItems<Item: Hashable & Sendable>: Sendable {
    let items: [Item]
    private let firstPositions: [Item: Int]

    /// Validates uniqueness once, preserving the ordinary queue initializer's
    /// first-occurrence behavior for both order and the stored item value.
    init(items: [Item]) {
        var positions: [Item: Int] = [:]
        positions.reserveCapacity(items.count)
        // The common, already-unique case shares its original ordered array.
        // Allocate a replacement array only if an actual duplicate is found.
        var uniqueItems: [Item]?
        for (index, item) in items.enumerated() {
            if positions[item] != nil {
                if uniqueItems == nil {
                    uniqueItems = Array(items[..<index])
                    uniqueItems?.reserveCapacity(items.count)
                }
                continue
            }
            positions[item] = uniqueItems?.count ?? index
            uniqueItems?.append(item)
        }
        self.items = uniqueItems ?? items
        firstPositions = positions
    }

    func index(of item: Item) -> Int? {
        firstPositions[item]
    }
}
