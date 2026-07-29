import Foundation

struct FileSystemMediaLibraryScanner: MediaLibraryScanning {
    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        try Self.scanSynchronously(rootURLs: rootURLs)
    }

    private static func scanSynchronously(
        rootURLs: [URL]
    ) throws -> MediaLibrarySnapshot {
        let fileManager = FileManager.default
        let normalizedRootURLs = normalizedUniqueRootURLs(rootURLs)
        var roots: [MediaLibraryRoot] = []
        var items: [LibraryMediaItem] = []
        var firstRootError: MediaLibraryScanError?

        for rootURL in normalizedRootURLs {
            try Task.checkCancellation()
            do {
                let root = try inspectRoot(
                    at: rootURL,
                    fileManager: fileManager
                )
                roots.append(root)
                items.append(
                    contentsOf: try scan(
                        root: root,
                        fileManager: fileManager
                    )
                )
            } catch let error as MediaLibraryScanError {
                if firstRootError == nil {
                    firstRootError = error
                }
            }
        }

        if roots.isEmpty, let firstRootError {
            throw firstRootError
        }

        return MediaLibrarySnapshot(
            roots: roots,
            items: items.sorted(by: itemPathPrecedes)
        )
    }

    private static func normalizedUniqueRootURLs(
        _ rootURLs: [URL]
    ) -> [URL] {
        var seenPaths: Set<String> = []

        return rootURLs
            .map(\.standardizedFileURL)
            .filter { seenPaths.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    private static func inspectRoot(
        at rootURL: URL,
        fileManager: FileManager
    ) throws -> MediaLibraryRoot {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw MediaLibraryScanError.rootUnavailable(rootURL)
        }

        let values: URLResourceValues
        do {
            values = try rootURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .nameKey
                ]
            )
        } catch {
            throw MediaLibraryScanError.resourceAccessFailed(rootURL)
        }

        guard values.isSymbolicLink != true else {
            throw MediaLibraryScanError.rootIsSymbolicLink(rootURL)
        }
        guard values.isDirectory == true else {
            throw MediaLibraryScanError.rootIsNotDirectory(rootURL)
        }

        return MediaLibraryRoot(
            url: rootURL,
            displayName: rootDisplayName(
                resourceName: values.name,
                rootURL: rootURL
            )
        )
    }

    private static func scan(
        root: MediaLibraryRoot,
        fileManager: FileManager
    ) throws -> [LibraryMediaItem] {
        let rootFailureRecorder = RootEnumerationFailureRecorder(
            rootURL: root.url
        )
        let resourceKeys = mediaResourceKeys

        guard let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants
            ],
            errorHandler: { failedURL, _ in
                rootFailureRecorder.recordIfRoot(failedURL)
                return !rootFailureRecorder.didFailAtRoot
            }
        ) else {
            throw MediaLibraryScanError.cannotEnumerateRoot(root.url)
        }

        var items: [LibraryMediaItem] = []

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: resourceKeys)
            } catch {
                // One unreadable descendant must not hide the rest of an
                // otherwise accessible media root.
                continue
            }

            if values.isSymbolicLink == true {
                continue
            }
            if values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isPackage == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            let fileExtension = fileURL.pathExtension.lowercased()
            guard MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                fileExtension
            ) else {
                continue
            }

            let relativePath = try relativePath(
                for: fileURL,
                under: root.url
            )
            items.append(
                LibraryMediaItem(
                    rootURL: root.url,
                    rootName: root.displayName,
                    url: fileURL,
                    displayName: fileURL
                        .deletingPathExtension()
                        .lastPathComponent,
                    relativePath: relativePath,
                    relativeDirectory: relativeDirectory(
                        for: relativePath
                    ),
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate,
                    fileSize: Int64(values.fileSize ?? 0)
                )
            )
        }

        if let failedURL = rootFailureRecorder.failedRootURL {
            throw MediaLibraryScanError.enumerationFailed(
                rootURL: root.url,
                failedURL: failedURL
            )
        }

        return items
    }

    private static let mediaResourceKeys: Set<URLResourceKey> = [
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isPackageKey,
        .isRegularFileKey,
        .isSymbolicLinkKey
    ]

    private static func relativePath(
        for fileURL: URL,
        under rootURL: URL
    ) throws -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.starts(with: rootComponents) else {
            throw MediaLibraryScanError.resourceAccessFailed(fileURL)
        }

        return fileComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
    }

    private static func relativeDirectory(
        for relativePath: String
    ) -> String {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .joined(separator: "/")
    }

    private static func rootDisplayName(
        resourceName: String?,
        rootURL: URL
    ) -> String {
        if let resourceName, !resourceName.isEmpty {
            return resourceName
        }
        if !rootURL.lastPathComponent.isEmpty {
            return rootURL.lastPathComponent
        }
        return rootURL.path
    }

    private static func itemPathPrecedes(
        _ lhs: LibraryMediaItem,
        _ rhs: LibraryMediaItem
    ) -> Bool {
        if lhs.url.path != rhs.url.path {
            return lhs.url.path < rhs.url.path
        }
        if lhs.rootURL.path != rhs.rootURL.path {
            return lhs.rootURL.path < rhs.rootURL.path
        }
        return lhs.relativePath < rhs.relativePath
    }
}

private final class RootEnumerationFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let rootPath: String
    private var storedFailedRootURL: URL?

    init(rootURL: URL) {
        rootPath = rootURL.standardizedFileURL.path
    }

    var failedRootURL: URL? {
        lock.withLock {
            storedFailedRootURL
        }
    }

    var didFailAtRoot: Bool {
        failedRootURL != nil
    }

    func recordIfRoot(_ failedURL: URL) {
        guard failedURL.standardizedFileURL.path == rootPath else {
            return
        }

        lock.withLock {
            if storedFailedRootURL == nil {
                storedFailedRootURL = failedURL
            }
        }
    }
}
