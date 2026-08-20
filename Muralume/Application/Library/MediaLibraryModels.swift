import Foundation

enum MediaSourceKind: String, Codable, Hashable, Sendable {
    case file
    case folder
}

struct MediaSource: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let standardizedPath: String
    }

    let id: ID
    /// Keep the resolved URL intact so security-scope teardown uses the exact
    /// URL whose scope was started.
    let url: URL
    let kind: MediaSourceKind

    init(url: URL, kind: MediaSourceKind) {
        id = ID(standardizedPath: url.standardizedFileURL.path)
        self.url = url
        self.kind = kind
    }
}

struct UnavailableMediaSource: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let rawValue: String
    }

    let id: ID
    let displayName: String
    let lastKnownURL: URL
    let kind: MediaSourceKind
}

struct MediaLibraryRoot: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let standardizedPath: String
    }

    let id: ID
    let url: URL
    let displayName: String
    let kind: MediaSourceKind

    init(
        url: URL,
        displayName: String,
        kind: MediaSourceKind = .folder
    ) {
        let standardizedURL = url.standardizedFileURL
        id = ID(standardizedPath: standardizedURL.path)
        self.url = standardizedURL
        self.displayName = displayName
        self.kind = kind
    }
}

struct LibraryMediaItem: Identifiable, Hashable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let rootPath: String
        let relativePath: String
        private let normalizedMediaPath: String

        private enum CodingKeys: String, CodingKey {
            case rootPath
            case relativePath
        }

        init(rootPath: String, relativePath: String) {
            self.rootPath = rootPath
            self.relativePath = relativePath
            // SwiftUI diffing and queue indexes hash IDs frequently.
            normalizedMediaPath = Self.normalizedMediaPath(
                rootPath: rootPath,
                relativePath: relativePath
            )
        }

        init(mediaURL: URL) {
            let standardizedPath = mediaURL.standardizedFileURL.path
            rootPath = standardizedPath
            relativePath = ""
            normalizedMediaPath = standardizedPath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                rootPath: try container.decode(String.self, forKey: .rootPath),
                relativePath: try container.decode(
                    String.self,
                    forKey: .relativePath
                )
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rootPath, forKey: .rootPath)
            try container.encode(relativePath, forKey: .relativePath)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.normalizedMediaPath == rhs.normalizedMediaPath
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(normalizedMediaPath)
        }

        var standardizedMediaPath: String {
            normalizedMediaPath
        }

        private static func normalizedMediaPath(
            rootPath: String,
            relativePath: String
        ) -> String {
            let rootURL = URL(fileURLWithPath: rootPath)
            let mediaURL = if relativePath.isEmpty {
                rootURL
            } else {
                rootURL.appendingPathComponent(relativePath)
            }
            // Hashing must stay independent of mutable filesystem state.
            // Alias/symlink/resource-ID normalization happens before IDs enter
            // long-lived sets and dictionaries.
            return mediaURL.standardizedFileURL.path
        }
    }

    let id: ID
    let rootURL: URL
    let rootName: String
    let kind: MediaSourceKind
    let url: URL
    let displayName: String
    let relativePath: String
    let relativeDirectory: String
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64
    let fileIdentity: MediaFileIdentity?

    init(
        rootURL: URL,
        rootName: String,
        kind: MediaSourceKind = .folder,
        url: URL,
        displayName: String,
        relativePath: String,
        relativeDirectory: String,
        creationDate: Date?,
        modificationDate: Date? = nil,
        fileSize: Int64,
        fileIdentity: MediaFileIdentity? = nil
    ) {
        let standardizedRootURL = rootURL.standardizedFileURL
        let standardizedURL = url.standardizedFileURL

        id = ID(
            rootPath: standardizedRootURL.path,
            relativePath: relativePath
        )
        self.rootURL = standardizedRootURL
        self.rootName = rootName
        self.kind = kind
        self.url = standardizedURL
        self.displayName = displayName
        self.relativePath = relativePath
        self.relativeDirectory = relativeDirectory
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.fileIdentity = fileIdentity?.isValid == true
            ? fileIdentity
            : nil
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

enum SupportedVideoContentType: String, CaseIterable, Sendable {
    case mpeg4 = "public.mpeg-4"
    case quickTimeMovie = "com.apple.quicktime-movie"
    case appleM4V = "com.apple.m4v-video"
    case mpeg = "public.mpeg"
    case mpeg2Video = "public.mpeg-2-video"
    case mpeg2TransportStream = "public.mpeg-2-transport-stream"
    case threeGPP = "public.3gpp"
    case threeGPP2 = "public.3gpp2"
    case avi = "public.avi"
    case dvMovie = "public.dv-movie"
}

enum MediaLibraryFilePolicy {
    static let supportedVideoExtensions: Set<String> = [
        "3g2",
        "3gp",
        "3gp2",
        "3gpp",
        "avi",
        "dif",
        "dv",
        "m1v",
        "m2t",
        "m2ts",
        "m2v",
        "m4v",
        "mov",
        "mp4",
        "mpe",
        "mpeg",
        "mpg",
        "mts",
        "qt",
        "sdv",
        "ts"
    ]
}

enum MediaLibrarySourceAccessState: Equatable, Sendable {
    /// No persisted or currently accessible media sources exist.
    case empty
    /// Every persisted source that was considered is currently accessible.
    case available
    /// Persisted sources exist, but none can currently be accessed.
    case temporarilyUnavailable
    /// At least one source is accessible and at least one remains unavailable.
    case partiallyUnavailable

    var hasUnavailableSources: Bool {
        switch self {
        case .temporarilyUnavailable, .partiallyUnavailable:
            true
        case .empty, .available:
            false
        }
    }
}

enum ExternalPlaybackNotice: Equatable, Sendable {
    case noPlayableFiles
    case skippedFiles(Int)
}

enum MediaImportPolicy {
    /// Bounds one picker/drop transaction before any bookmark work begins.
    static let maximumTopLevelSourceCount = 256

    /// Bounds simultaneously active security-scoped grants for one process.
    static let maximumActiveSourceCount = 256

    /// Bounds bookmark resolution work during one process restoration.
    static let maximumRestoredSourceRecordCount = 256

    /// Prevents legacy migration from being permanently starved by an
    /// unavailable typed-record prefix while an active-source slot remains.
    static let reservedLegacyRestoreCandidateCount = 1

    /// Apple does not publish a maximum security-scoped bookmark size. This
    /// deliberately generous bound rejects damaged opaque payloads before URL
    /// resolution while remaining far above bookmarks produced in practice.
    static let maximumBookmarkByteCount = 1 * 1_024 * 1_024
}
