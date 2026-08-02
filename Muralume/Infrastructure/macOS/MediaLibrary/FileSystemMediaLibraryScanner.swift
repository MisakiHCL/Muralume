import Foundation

struct FileSystemMediaLibraryScanner: MediaLibraryScanning {
    private struct RootScanResult {
        let items: [LibraryMediaItem]
        let isComplete: Bool
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        let sources = rootURLs.map { url in
            MediaSource(
                url: url,
                kind: Self.sourceKindHint(at: url) ?? .folder
            )
        }
        return try Self.scanSynchronously(sources: sources)
    }

    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot {
        try Self.scanSynchronously(sources: sources)
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
        sources: [MediaSource]
    ) throws -> MediaLibrarySnapshot {
        let fileManager = FileManager.default
        let normalizedSources = normalizedUniqueSources(sources)
        var roots: [MediaLibraryRoot] = []
        var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        var incompleteRootPaths: Set<String> = []
        var firstRootError: MediaLibraryScanError?

        for source in normalizedSources {
            try Task.checkCancellation()
            do {
                let root = try inspectRoot(
                    source,
                    fileManager: fileManager
                )
                let rootScan = try scan(
                    root: root,
                    fileManager: fileManager
                )
                roots.append(root)
                for item in rootScan.items {
                    if let existingItem = itemsByID[item.id],
                       existingItem.kind == .folder {
                        continue
                    }
                    itemsByID[item.id] = item
                }
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
            roots: roots.sorted(by: rootPathPrecedes),
            items: itemsByID.values.sorted(by: itemPathPrecedes),
            incompleteRootPaths: incompleteRootPaths
        )
    }

    private static func normalizedUniqueSources(
        _ sources: [MediaSource]
    ) -> [MediaSource] {
        var acceptedSources: [MediaSource] = []
        let sortedSources = sources
            .map {
                MediaSource(url: $0.url.standardizedFileURL, kind: $0.kind)
            }
            .sorted(by: sourcePrecedes)

        for candidate in sortedSources {
            if acceptedSources.contains(where: {
                representsSameItem($0.url, candidate.url)
                    || ($0.kind == .folder
                        && folder($0.url, covers: candidate.url))
            }) {
                continue
            }
            acceptedSources.append(candidate)
        }
        return acceptedSources
    }

    private static func inspectRoot(
        _ source: MediaSource,
        fileManager: FileManager
    ) throws -> MediaLibraryRoot {
        let rootURL = source.url
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw MediaLibraryScanError.rootUnavailable(rootURL)
        }

        let values: URLResourceValues
        do {
            values = try rootURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
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
        let liveKind: MediaSourceKind
        if values.isDirectory == true {
            liveKind = .folder
        } else if values.isRegularFile == true {
            guard MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                rootURL.pathExtension.lowercased()
            ) else {
                throw MediaLibraryScanError.unsupportedMediaFile(rootURL)
            }
            liveKind = .file
        } else {
            throw MediaLibraryScanError.rootIsNotDirectory(rootURL)
        }
        guard liveKind == source.kind else {
            throw MediaLibraryScanError.sourceKindMismatch(
                rootURL,
                expected: source.kind
            )
        }

        return MediaLibraryRoot(
            url: rootURL,
            displayName: rootDisplayName(
                resourceName: values.name,
                rootURL: rootURL
            ),
            kind: source.kind
        )
    }

    private static func scan(
        root: MediaLibraryRoot,
        fileManager: FileManager
    ) throws -> RootScanResult {
        if root.kind == .file {
            return RootScanResult(
                items: [try inspectFile(root: root)],
                isComplete: true
            )
        }

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
                    kind: .folder,
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

    private static func inspectFile(
        root: MediaLibraryRoot
    ) throws -> LibraryMediaItem {
        let values: URLResourceValues
        do {
            values = try root.url.resourceValues(forKeys: mediaResourceKeys)
        } catch {
            throw MediaLibraryScanError.resourceAccessFailed(root.url)
        }
        guard values.isRegularFile == true else {
            throw MediaLibraryScanError.resourceAccessFailed(root.url)
        }
        return LibraryMediaItem(
            rootURL: root.url,
            rootName: root.displayName,
            kind: .file,
            url: root.url,
            displayName: root.url.deletingPathExtension().lastPathComponent,
            relativePath: "",
            relativeDirectory: "",
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

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

    private static func rootPathPrecedes(
        _ lhs: MediaLibraryRoot,
        _ rhs: MediaLibraryRoot
    ) -> Bool {
        lhs.url.path < rhs.url.path
    }

    private static func sourcePrecedes(
        _ lhs: MediaSource,
        _ rhs: MediaSource
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .folder
        }
        let lhsDepth = lhs.url.pathComponents.count
        let rhsDepth = rhs.url.pathComponents.count
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        return lhs.url.path < rhs.url.path
    }

    private static func sourceKindHint(at url: URL) -> MediaSourceKind? {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else {
            return nil
        }
        if values.isDirectory == true {
            return .folder
        }
        if values.isRegularFile == true {
            return .file
        }
        return nil
    }

    private static func representsSameItem(
        _ firstURL: URL,
        _ secondURL: URL
    ) -> Bool {
        let firstURL = firstURL.standardizedFileURL.resolvingSymlinksInPath()
        let secondURL = secondURL.standardizedFileURL.resolvingSymlinksInPath()
        if firstURL.path == secondURL.path {
            return true
        }
        guard let firstIdentifier = resourceIdentifier(for: firstURL),
              let secondIdentifier = resourceIdentifier(for: secondURL) else {
            return false
        }
        return firstIdentifier.isEqual(secondIdentifier)
    }

    private static func resourceIdentifier(for url: URL) -> NSObject? {
        try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier as? NSObject
    }

    private static func folder(
        _ directoryURL: URL,
        covers itemURL: URL
    ) -> Bool {
        var relationship = FileManager.URLRelationship.other
        do {
            try FileManager.default.getRelationship(
                &relationship,
                ofDirectoryAt: directoryURL,
                toItemAt: itemURL
            )
            return relationship != .other
        } catch {
            return false
        }
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
