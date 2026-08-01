import Foundation

struct FileSystemMediaLibraryScanner: MediaLibraryScanning {
    private struct RootScanResult {
        let items: [LibraryMediaItem]
        let isComplete: Bool
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        try Self.scanSynchronously(rootURLs: rootURLs)
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: item.url.path) {
            return .available
        }

        // A failed existence probe is ambiguous when a volume or parent
        // directory is temporarily inaccessible. Only an authoritative
        // listing of the immediate parent can prove that the file is gone.
        let parentURL = item.url.deletingLastPathComponent()
        do {
            let children = try fileManager.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            return children.contains {
                $0.standardizedFileURL == item.url.standardizedFileURL
            } ? .available : .missing
        } catch {
            return .temporarilyUnavailable
        }
    }

    private static func scanSynchronously(
        rootURLs: [URL]
    ) throws -> MediaLibrarySnapshot {
        let fileManager = FileManager.default
        let normalizedRootURLs = normalizedUniqueRootURLs(rootURLs)
        var roots: [MediaLibraryRoot] = []
        var items: [LibraryMediaItem] = []
        var incompleteRootPaths: Set<String> = []
        var firstRootError: MediaLibraryScanError?

        for rootURL in normalizedRootURLs {
            try Task.checkCancellation()
            do {
                let root = try inspectRoot(
                    at: rootURL,
                    fileManager: fileManager
                )
                let rootScan = try scan(
                    root: root,
                    fileManager: fileManager
                )
                roots.append(root)
                items.append(contentsOf: rootScan.items)
                if !rootScan.isComplete {
                    incompleteRootPaths.insert(root.id.standardizedPath)
                }
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
            items: items.sorted(by: itemPathPrecedes),
            incompleteRootPaths: incompleteRootPaths
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
    ) throws -> RootScanResult {
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
                rootFailureRecorder.record(failedURL)
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
                rootFailureRecorder.record(fileURL)
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

            let relativeItemPath: String
            do {
                relativeItemPath = try relativePath(
                    for: fileURL,
                    under: root.url
                )
            } catch {
                rootFailureRecorder.record(fileURL)
                continue
            }
            items.append(
                LibraryMediaItem(
                    rootURL: root.url,
                    rootName: root.displayName,
                    url: fileURL,
                    displayName: fileURL
                        .deletingPathExtension()
                        .lastPathComponent,
                    relativePath: relativeItemPath,
                    relativeDirectory: relativeDirectory(
                        for: relativeItemPath
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

        return RootScanResult(
            items: items,
            isComplete: !rootFailureRecorder.didEncounterFailure
        )
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
    private var storedDidEncounterFailure = false

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

    var didEncounterFailure: Bool {
        lock.withLock {
            storedDidEncounterFailure
        }
    }

    func record(_ failedURL: URL) {
        lock.withLock {
            storedDidEncounterFailure = true
            if failedURL.standardizedFileURL.path == rootPath,
               storedFailedRootURL == nil {
                storedFailedRootURL = failedURL
            }
        }
    }
}
