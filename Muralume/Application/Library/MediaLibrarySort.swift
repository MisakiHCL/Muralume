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

        let nameComparison = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        if lhs.id.rootPath != rhs.id.rootPath {
            return lhs.id.rootPath < rhs.id.rootPath
        }
        return lhs.id.relativePath < rhs.id.relativePath
    }
}
