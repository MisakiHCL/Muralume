import Foundation

struct MediaLibraryRoot: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let standardizedPath: String
    }

    let id: ID
    let url: URL
    let displayName: String

    init(url: URL, displayName: String) {
        let standardizedURL = url.standardizedFileURL
        id = ID(standardizedPath: standardizedURL.path)
        self.url = standardizedURL
        self.displayName = displayName
    }
}

struct LibraryMediaItem: Identifiable, Hashable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let rootPath: String
        let relativePath: String
    }

    let id: ID
    let rootURL: URL
    let rootName: String
    let url: URL
    let displayName: String
    let relativePath: String
    let relativeDirectory: String
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64

    init(
        rootURL: URL,
        rootName: String,
        url: URL,
        displayName: String,
        relativePath: String,
        relativeDirectory: String,
        creationDate: Date?,
        modificationDate: Date? = nil,
        fileSize: Int64
    ) {
        let standardizedRootURL = rootURL.standardizedFileURL
        let standardizedURL = url.standardizedFileURL

        id = ID(
            rootPath: standardizedRootURL.path,
            relativePath: relativePath
        )
        self.rootURL = standardizedRootURL
        self.rootName = rootName
        self.url = standardizedURL
        self.displayName = displayName
        self.relativePath = relativePath
        self.relativeDirectory = relativeDirectory
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
    }
}

struct MediaLibrarySnapshot: Equatable, Sendable {
    static let empty = MediaLibrarySnapshot(roots: [], items: [])

    let roots: [MediaLibraryRoot]
    let items: [LibraryMediaItem]
    /// Roots that were reachable but could not be scanned completely.
    /// Missing queue entries under these roots must not be treated as deleted.
    let incompleteRootPaths: Set<String>

    init(
        roots: [MediaLibraryRoot],
        items: [LibraryMediaItem],
        incompleteRootPaths: Set<String> = []
    ) {
        self.roots = roots
        self.items = items
        self.incompleteRootPaths = incompleteRootPaths
    }
}

enum MediaLibraryFilePolicy {
    static let supportedVideoExtensions: Set<String> = [
        "m4v",
        "mov",
        "mp4"
    ]
}
