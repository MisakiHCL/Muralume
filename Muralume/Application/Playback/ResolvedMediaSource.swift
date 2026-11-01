import Foundation

/// Value models share this owner without duplicating or prematurely closing its grant.
final class MediaSourceAccessLease: Hashable, @unchecked Sendable {
    private let owner: any AnyObject & Sendable

    init<Owner: AnyObject & Sendable>(retaining owner: Owner) {
        self.owner = owner
    }

    static func == (lhs: MediaSourceAccessLease, rhs: MediaSourceAccessLease) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct ResolvedMediaSource: Equatable, Sendable {
    let url: URL
    let displayName: String
    var accessLease: MediaSourceAccessLease? = nil
}

enum MediaPlaybackCompatibilityPolicy {
    static let aliasDirectoryName = "PlaybackAliases"

    /// AVFoundation recognizes these containers once the same read-only file
    /// is presented through its canonical extension. The source is never
    /// copied, renamed, or modified.
    static let canonicalExtensionByAlias: [String: String] = [
        "divx": "avi",
        "f4v": "mp4",
        "m2p": "mpg",
        "mod": "mpg",
        "mp2v": "m2v",
        "mpeg4": "mp4",
        "mpg4": "mp4",
        "mpv": "m2v",
        "tod": "m2ts",
        "vob": "mpg",
        "xvid": "avi"
    ]

    static func canonicalExtension(for sourceURL: URL) -> String? {
        canonicalExtensionByAlias[sourceURL.pathExtension.lowercased()]
    }
}

/// Keeps a temporary compatibility symlink alive for exactly as long as an
/// AVFoundation-backed operation needs it. Only the symlink lives in the
/// app's temporary directory; media stays at its user-selected location.
final class MediaPlaybackURLLease: @unchecked Sendable {
    let url: URL
    private let accessLease: MediaSourceAccessLease?

    private let lock = NSLock()
    private var removableURL: URL?

    init(
        sourceURL: URL,
        accessLease: MediaSourceAccessLease? = nil,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) throws {
        self.accessLease = accessLease
        guard let canonicalExtension =
            MediaPlaybackCompatibilityPolicy.canonicalExtension(
                for: sourceURL
            ) else {
            url = sourceURL
            removableURL = nil
            return
        }

        let directoryURL = temporaryDirectoryURL.appendingPathComponent(
            MediaPlaybackCompatibilityPolicy.aliasDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let aliasURL = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(canonicalExtension)
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: sourceURL
        )
        url = aliasURL
        removableURL = aliasURL
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        let urlToRemove = lock.withLock {
            defer { removableURL = nil }
            return removableURL
        }
        if let urlToRemove {
            try? FileManager.default.removeItem(at: urlToRemove)
        }
    }
}
