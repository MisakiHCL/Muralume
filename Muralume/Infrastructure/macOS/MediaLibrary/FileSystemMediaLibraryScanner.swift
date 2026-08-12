import Foundation

struct FileSystemMediaSourceInspection: Sendable {
    let canonicalURL: @Sendable (URL) -> URL
    let resourceIdentifier: @Sendable (URL) -> NSObject?

    static let live = FileSystemMediaSourceInspection(
        canonicalURL: { url in
            url.standardizedFileURL.resolvingSymlinksInPath()
        },
        resourceIdentifier: { url in
            try? url.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier as? NSObject
        }
    )
}

struct FileSystemMediaLibraryScanLimits: Sendable {
    static let production = FileSystemMediaLibraryScanLimits(
        maximumDuration: .seconds(120),
        maximumEstimatedWorkingSetBytes: 128 * 1_024 * 1_024
    )

    let maximumDuration: Duration
    let maximumEstimatedWorkingSetBytes: Int
}

struct FileSystemMediaLibraryScanner: MediaLibraryScanning {
    private let sourceInspection: FileSystemMediaSourceInspection
    private let scanLimits: FileSystemMediaLibraryScanLimits

    init(
        sourceInspection: FileSystemMediaSourceInspection = .live,
        scanLimits: FileSystemMediaLibraryScanLimits = .production
    ) {
        self.sourceInspection = sourceInspection
        self.scanLimits = scanLimits
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        let sources = rootURLs.map { url in
            MediaSource(
                url: url,
                kind: Self.sourceKindHint(at: url) ?? .folder
            )
        }
        return try scanSynchronously(sources: sources)
    }

    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot {
        try scanSynchronously(sources: sources)
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

    private func scanSynchronously(
        sources: [MediaSource]
    ) throws -> MediaLibrarySnapshot {
        let fileManager = FileManager.default
        var budget = FileSystemMediaLibraryScanBudget(limits: scanLimits)
        let normalizedSources = try normalizedUniqueSources(
            sources,
            budget: &budget
        )
        var roots: [MediaLibraryRoot] = []
        var items: [LibraryMediaItem] = []
        var itemIndicesByID: [LibraryMediaItem.ID: Int] = [:]
        var incompleteRootPaths: Set<String> = []
        var firstRootError: MediaLibraryScanError?

        for source in normalizedSources {
            try Task.checkCancellation()
            try budget.checkpoint()
            var scannedRootPath: String?
            let rootMemoryCheckpoint = budget.estimatedWorkingSetBytes
            do {
                let root = try Self.inspectRoot(
                    source,
                    fileManager: fileManager
                )
                scannedRootPath = root.id.standardizedPath
                let isComplete = try Self.scan(
                    root: root,
                    fileManager: fileManager,
                    budget: &budget,
                    onItem: { item in
                        if let existingIndex = itemIndicesByID[item.id] {
                            if items[existingIndex].kind == .folder {
                                return
                            }
                            items[existingIndex] = item
                            return
                        }
                        itemIndicesByID[item.id] = items.endIndex
                        items.append(item)
                    }
                )
                roots.append(root)
                if !isComplete {
                    incompleteRootPaths.insert(root.id.standardizedPath)
                }
            } catch let error as MediaLibraryScanError {
                if error.isResourceLimitExceeded {
                    roots.removeAll(keepingCapacity: false)
                    items.removeAll(keepingCapacity: false)
                    itemIndicesByID.removeAll(keepingCapacity: false)
                    incompleteRootPaths.removeAll(keepingCapacity: false)
                    throw error
                }
                // Items are streamed into the final array to avoid a second
                // full item collection per root. A root-level failure is
                // uncommon, so rebuild the compact ID index only on failure.
                if let scannedRootPath {
                    items.removeAll {
                        $0.id.rootPath == scannedRootPath
                    }
                    itemIndicesByID.removeAll(keepingCapacity: true)
                    for (index, item) in items.enumerated() {
                        itemIndicesByID[item.id] = index
                    }
                    budget.restoreMemory(to: rootMemoryCheckpoint)
                }
                if firstRootError == nil {
                    firstRootError = error
                }
            }
        }

        if roots.isEmpty, let firstRootError {
            throw firstRootError
        }

        // The ID index is no longer needed. Release it before sorting so peak
        // scan memory is the final item array plus the sort's own workspace.
        itemIndicesByID = [:]
        do {
            try budget.checkpoint()
            roots.sort(by: Self.rootPathPrecedes)
            items.sort(by: Self.itemPathPrecedes)
            try budget.checkpoint()
        } catch {
            roots.removeAll(keepingCapacity: false)
            items.removeAll(keepingCapacity: false)
            incompleteRootPaths.removeAll(keepingCapacity: false)
            throw error
        }
        return MediaLibrarySnapshot(
            roots: roots,
            items: items,
            incompleteRootPaths: incompleteRootPaths
        )
    }

    private func normalizedUniqueSources(
        _ sources: [MediaSource],
        budget: inout FileSystemMediaLibraryScanBudget
    ) throws -> [MediaSource] {
        var sortedSources: [MediaSource] = []
        sortedSources.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            try budget.checkpoint()
            sortedSources.append(
                MediaSource(
                    url: source.url.standardizedFileURL,
                    kind: source.kind
                )
            )
        }
        sortedSources.sort(by: Self.sourcePrecedes)
        guard sortedSources.count > 1 else {
            return sortedSources
        }

        var acceptedSources: [MediaSource] = []
        acceptedSources.reserveCapacity(sortedSources.count)
        var acceptedCanonicalPaths: Set<String> = []
        acceptedCanonicalPaths.reserveCapacity(sortedSources.count)
        var acceptedResourceIdentifiers: Set<NSObject> = []
        acceptedResourceIdentifiers.reserveCapacity(sortedSources.count)
        var acceptedFolderPaths: Set<String> = []
        var acceptedFolderResourceIdentifiers: Set<NSObject> = []
        var inspectedAncestorPaths: Set<String> = []
        var ancestorResourceIdentifiersByPath: [String: NSObject] = [:]

        for source in sortedSources {
            try Task.checkCancellation()
            try budget.checkpoint()
            let canonicalURL = sourceInspection
                .canonicalURL(source.url)
                .standardizedFileURL
            try Task.checkCancellation()
            let resourceIdentifier = sourceInspection.resourceIdentifier(
                canonicalURL
            )
            let canonicalPath = canonicalURL.path

            if acceptedCanonicalPaths.contains(canonicalPath)
                || resourceIdentifier.map(
                    acceptedResourceIdentifiers.contains
                ) == true {
                continue
            }
            if try isCoveredByAcceptedFolder(
                    canonicalURL,
                    acceptedFolderPaths: acceptedFolderPaths,
                    acceptedFolderResourceIdentifiers:
                        acceptedFolderResourceIdentifiers,
                    inspectedAncestorPaths: &inspectedAncestorPaths,
                    ancestorResourceIdentifiersByPath:
                        &ancestorResourceIdentifiersByPath,
                    budget: &budget
                ) {
                continue
            }

            acceptedSources.append(source)
            acceptedCanonicalPaths.insert(canonicalPath)
            if let resourceIdentifier {
                acceptedResourceIdentifiers.insert(resourceIdentifier)
            }
            if source.kind == .folder {
                acceptedFolderPaths.insert(canonicalPath)
                if let resourceIdentifier {
                    acceptedFolderResourceIdentifiers.insert(
                        resourceIdentifier
                    )
                }
            }
        }
        return acceptedSources
    }

    private func isCoveredByAcceptedFolder(
        _ canonicalURL: URL,
        acceptedFolderPaths: Set<String>,
        acceptedFolderResourceIdentifiers: Set<NSObject>,
        inspectedAncestorPaths: inout Set<String>,
        ancestorResourceIdentifiersByPath: inout [String: NSObject],
        budget: inout FileSystemMediaLibraryScanBudget
    ) throws -> Bool {
        guard !acceptedFolderPaths.isEmpty else {
            return false
        }

        var ancestorURL = canonicalURL.deletingLastPathComponent()
        while true {
            try Task.checkCancellation()
            try budget.checkpoint()
            let ancestorPath = ancestorURL.path
            if acceptedFolderPaths.contains(ancestorPath) {
                return true
            }
            if !acceptedFolderResourceIdentifiers.isEmpty {
                let ancestorIdentifier: NSObject?
                if inspectedAncestorPaths.contains(ancestorPath) {
                    ancestorIdentifier = ancestorResourceIdentifiersByPath[
                        ancestorPath
                    ]
                } else {
                    inspectedAncestorPaths.insert(ancestorPath)
                    ancestorIdentifier = sourceInspection.resourceIdentifier(
                        ancestorURL
                    )
                    if let ancestorIdentifier {
                        ancestorResourceIdentifiersByPath[ancestorPath] =
                            ancestorIdentifier
                    }
                }
                if let ancestorIdentifier,
                   acceptedFolderResourceIdentifiers.contains(
                        ancestorIdentifier
                   ) {
                    return true
                }
            }
            guard ancestorPath != "/" else {
                return false
            }
            let parentURL = ancestorURL.deletingLastPathComponent()
            guard parentURL.path != ancestorPath else {
                return false
            }
            ancestorURL = parentURL
        }
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
        fileManager: FileManager,
        budget: inout FileSystemMediaLibraryScanBudget,
        onItem: (LibraryMediaItem) -> Void
    ) throws -> Bool {
        if root.kind == .file {
            let item = try inspectFile(root: root)
            try budget.reserveMemory(for: item)
            onItem(item)
            return true
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

        let rootPathComponents = root.url.standardizedFileURL.pathComponents

        while true {
            try Task.checkCancellation()
            try budget.checkpoint()
            guard let fileURL = autoreleasepool(
                invoking: { enumerator.nextObject() as? URL }
            ) else {
                break
            }
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
                    underRootPathComponents: rootPathComponents
                )
            } catch {
                rootFailureRecorder.record(fileURL)
                continue
            }
            let item = LibraryMediaItem(
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
            try budget.reserveMemory(for: item)
            onItem(item)
        }

        if let failedURL = rootFailureRecorder.failedRootURL {
            throw MediaLibraryScanError.enumerationFailed(
                rootURL: root.url,
                failedURL: failedURL
            )
        }

        return !rootFailureRecorder.didEncounterFailure
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
        underRootPathComponents rootPathComponents: [String]
    ) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.starts(with: rootPathComponents) else {
            throw MediaLibraryScanError.resourceAccessFailed(fileURL)
        }

        return fileComponents
            .dropFirst(rootPathComponents.count)
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

}

private struct FileSystemMediaLibraryScanBudget {
    private enum MemoryEstimate {
        // Covers value storage, array/dictionary buckets and sorting workspace.
        static let fixedBytesPerItem = 1_024
        // Paths are retained in URLs, IDs and display fields more than once.
        static let duplicatedTextStorageMultiplier = 4
    }

    private let limits: FileSystemMediaLibraryScanLimits
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private(set) var estimatedWorkingSetBytes = 0

    init(limits: FileSystemMediaLibraryScanLimits) {
        self.limits = limits
        startedAt = clock.now
    }

    func checkpoint() throws {
        guard startedAt.duration(to: clock.now)
                < limits.maximumDuration else {
            throw MediaLibraryScanError.timeLimitExceeded
        }
    }

    mutating func reserveMemory(for item: LibraryMediaItem) throws {
        try checkpoint()
        let textBytes = item.id.rootPath.utf8.count
            + item.id.relativePath.utf8.count
            + item.id.standardizedMediaPath.utf8.count
            + item.rootName.utf8.count
            + item.url.path.utf8.count
            + item.displayName.utf8.count
            + item.relativePath.utf8.count
            + item.relativeDirectory.utf8.count
        let (duplicatedTextBytes, textOverflow) = textBytes
            .multipliedReportingOverflow(
                by: MemoryEstimate.duplicatedTextStorageMultiplier
            )
        let (itemBytes, itemOverflow) = duplicatedTextBytes
            .addingReportingOverflow(MemoryEstimate.fixedBytesPerItem)
        guard !textOverflow,
              !itemOverflow,
              estimatedWorkingSetBytes
                <= limits.maximumEstimatedWorkingSetBytes,
              limits.maximumEstimatedWorkingSetBytes
                - estimatedWorkingSetBytes >= itemBytes else {
            throw MediaLibraryScanError.memoryLimitExceeded
        }
        estimatedWorkingSetBytes += itemBytes
    }

    mutating func restoreMemory(to checkpoint: Int) {
        estimatedWorkingSetBytes = checkpoint
    }
}

private extension MediaLibraryScanError {
    var isResourceLimitExceeded: Bool {
        switch self {
        case .timeLimitExceeded, .memoryLimitExceeded:
            true
        default:
            false
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
