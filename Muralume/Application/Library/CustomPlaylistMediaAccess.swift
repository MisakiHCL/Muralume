import Foundation

struct CustomPlaylistMediaGrant: Codable, Hashable, Identifiable, Sendable {
    typealias ID = UUID

    let id: ID
    let sourcePath: String
    let kind: MediaSourceKind
    let bookmark: Data

    init(id: ID = UUID(), sourcePath: String, kind: MediaSourceKind, bookmark: Data) {
        self.id = id
        self.sourcePath = sourcePath
        self.kind = kind
        self.bookmark = bookmark
    }
}

enum CustomPlaylistMediaIssue: String, Codable, Hashable, Sendable {
    case authorizationRequired
    case permissionDenied
    case fileMissing
    case unsupportedFormat
    case cannotOpen
    case temporarilyUnavailable
    case resolving
}

struct CustomPlaylistMediaResolution: Sendable {
    var itemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem]
    var issuesByEntryID: [CustomPlaylistEntry.ID: CustomPlaylistMediaIssue]
    var authorizedRootIDs: Set<MediaLibraryRoot.ID>
    var refreshedGrants: [CustomPlaylistMediaGrant]

    init(
        itemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem] = [:],
        issuesByEntryID: [CustomPlaylistEntry.ID: CustomPlaylistMediaIssue] = [:],
        authorizedRootIDs: Set<MediaLibraryRoot.ID> = [],
        refreshedGrants: [CustomPlaylistMediaGrant] = []
    ) {
        self.itemsByEntryID = itemsByEntryID
        self.issuesByEntryID = issuesByEntryID
        self.authorizedRootIDs = authorizedRootIDs
        self.refreshedGrants = refreshedGrants
    }
}

@MainActor
protocol CustomPlaylistMediaAccessResolving: AnyObject {
    func resolve(
        grants: [CustomPlaylistMediaGrant], entries: [CustomPlaylistEntry]
    ) async -> CustomPlaylistMediaResolution

    func authorize(
        selectedURL: URL, sourcePath: String, kind: MediaSourceKind, grantID: UUID?
    ) async -> CustomPlaylistMediaGrant?

    func shutdown() async
}

extension CustomPlaylistMediaAccessResolving {
    func authorize(
        selectedURL: URL, sourcePath: String, kind: MediaSourceKind, grantID: UUID?
    ) async -> CustomPlaylistMediaGrant? { nil }
}
