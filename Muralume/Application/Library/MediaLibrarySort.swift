import Foundation

enum MediaLibrarySortField: String, CaseIterable, Sendable {
    case name
    case creationDate
    case fileSize
}

enum MediaLibrarySortDirection: String, CaseIterable, Sendable {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct MediaLibrarySort: Equatable, Sendable {
    var field: MediaLibrarySortField = .name
    var direction: MediaLibrarySortDirection = .ascending

    func sorted(_ items: [LibraryMediaItem]) -> [LibraryMediaItem] {
        items.sorted(by: precedes)
    }

    /// Sorts existing mutable storage without creating a second full array.
    func sortInPlace(_ items: inout [LibraryMediaItem]) {
        items.sort(by: precedes)
    }

    func sortedCancellable(_ items: [LibraryMediaItem]) throws -> [LibraryMediaItem] {
        var sortedItems = items
        try sortInPlaceCancellable(&sortedItems)
        return sortedItems
    }

    func sortInPlaceCancellable(_ items: inout [LibraryMediaItem]) throws {
        try Task.checkCancellation()
        var comparisons = 0
        try items.sort { lhs, rhs in
            if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
            comparisons &+= 1
            return precedes(lhs, rhs)
        }
        try Task.checkCancellation()
    }

    /// Metadata outside these values cannot change any comparator result.
    /// Check the ID representation as well as its normalized hash identity,
    /// because root and relative-path spelling are the final tie breakers.
    func hasSameOrderingValues(
        _ lhs: LibraryMediaItem,
        _ rhs: LibraryMediaItem
    ) -> Bool {
        guard lhs.displayName == rhs.displayName,
              lhs.id.rootPath == rhs.id.rootPath,
              lhs.id.relativePath == rhs.id.relativePath else { return false }
        switch field {
        case .name:
            return true
        case .creationDate:
            return lhs.creationDate == rhs.creationDate
        case .fileSize:
            return lhs.fileSize == rhs.fileSize
        }
    }

    private func precedes(
        _ lhs: LibraryMediaItem,
        _ rhs: LibraryMediaItem
    ) -> Bool {
        let primaryComparison: ComparisonResult

        switch field {
        case .name:
            primaryComparison = lhs.displayName.localizedStandardCompare(
                rhs.displayName
            )
        case .creationDate:
            switch (lhs.creationDate, rhs.creationDate) {
            case let (lhsDate?, rhsDate?):
                primaryComparison = lhsDate.compare(rhsDate)
            case (nil, nil):
                primaryComparison = .orderedSame
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        case .fileSize:
            if lhs.fileSize < rhs.fileSize {
                primaryComparison = .orderedAscending
            } else if lhs.fileSize > rhs.fileSize {
                primaryComparison = .orderedDescending
            } else {
                primaryComparison = .orderedSame
            }
        }

        if primaryComparison != .orderedSame {
            return direction == .ascending
                ? primaryComparison == .orderedAscending
                : primaryComparison == .orderedDescending
        }

        let nameComparison = field == .name ? primaryComparison
            : lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        if lhs.id.rootPath != rhs.id.rootPath {
            return lhs.id.rootPath < rhs.id.rootPath
        }
        return lhs.id.relativePath < rhs.id.relativePath
    }
}
