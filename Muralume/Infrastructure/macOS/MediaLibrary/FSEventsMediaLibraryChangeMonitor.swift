import CoreServices
import Darwin
import Foundation

struct MediaLibraryReconciliationVolume: Sendable {
    let isLocal: Bool?
    let isInternal: Bool?
    let isRemovable: Bool?
    let isEjectable: Bool?
    let isUbiquitous: Bool?
    let fileSystemType: String?

    var allowsExtendedReconciliation: Bool {
        isLocal == true && isInternal == true
            && isRemovable == false && isEjectable == false
            // Foundation omits this value for ordinary local directories.
            && isUbiquitous != true
            && (fileSystemType == "apfs" || fileSystemType == "hfs")
    }
}

enum FSEventsMediaLibraryChangePolicy {
    static let installationTimeoutNanoseconds: UInt64 = 2_000_000_000
    static let latency: CFTimeInterval = 1
    static let sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    static let creationFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes
    )
}

@MainActor
final class FSEventsMediaLibraryChangeMonitor:
    MediaLibraryChangeMonitoring {
    typealias VolumeInspection = @Sendable (URL) -> MediaLibraryReconciliationVolume?

    // A blocked volume lookup retains its real slot after caller cancellation.
    private let volumeInspectionPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1,
        maximumQueuedWorkCount: 1
    )
    private let inspectVolume: VolumeInspection
    private let worker: FSEventsStreamWorker

    init(
        inspectVolume: @escaping VolumeInspection =
            FSEventsMediaLibraryChangeMonitor.inspectVolume,
        streamFactory: FSEventsStreamFactory? = nil,
        scopeAccess: FSEventsSecurityScopeAccess = .live,
        installationTimeoutNanoseconds: UInt64 =
            FSEventsMediaLibraryChangePolicy.installationTimeoutNanoseconds
    ) {
        self.inspectVolume = inspectVolume
        worker = FSEventsStreamWorker(
            factory: streamFactory ?? FSEventsNativeStream.factory(),
            scopeAccess: scopeAccess,
            timeoutNanoseconds: installationTimeoutNanoseconds
        )
    }

    deinit { worker.stop() }

    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) async -> Bool {
        guard folderURLs.count <= MediaImportPolicy.maximumActiveSourceCount else {
            worker.stop()
            return false
        }
        // Normalize comparison paths without replacing the original URL's
        // security-scope token. The worker acquires its own grant before I/O.
        var originalURLsByPath: [String: URL] = [:]
        for url in folderURLs where url.isFileURL {
            originalURLsByPath[url.standardizedFileURL.path] = url
        }
        let paths = originalURLsByPath.keys.sorted()
        let urls = paths.compactMap { originalURLsByPath[$0] }
        return await worker.update(urls: urls, onChange: onChange)
    }

    func stop() { worker.stop() }

    func reconciliationCadence(
        for folderURLs: [URL]
    ) async -> MediaLibraryReconciliationCadence {
        guard !folderURLs.isEmpty,
              folderURLs.count <= MediaImportPolicy.maximumActiveSourceCount else {
            return .standard
        }
        let inspectVolume = inspectVolume
        return (try? await volumeInspectionPool.run {
            for url in folderURLs {
                try Task.checkCancellation()
                let allowsExtended = autoreleasepool {
                    // Root removal may cancel the caller before blocked I/O
                    // returns. Keep this reader's own scope until it exits.
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasScope { url.stopAccessingSecurityScopedResource() }
                    }
                    return inspectVolume(url)?.allowsExtendedReconciliation == true
                }
                try Task.checkCancellation()
                guard allowsExtended else { return .standard }
            }
            return .extended
        }) ?? .standard
    }

    private nonisolated static func inspectVolume(
        at url: URL
    ) -> MediaLibraryReconciliationVolume? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .isUbiquitousItemKey
        ]) else { return nil }
        var fileSystem = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { statfs($0, &fileSystem) } ?? -1
        }
        let fileSystemType: String? = result == 0
            ? withUnsafePointer(to: &fileSystem.f_fstypename) { name in
                name.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                    String(cString: $0)
                }
            }
            : nil
        return MediaLibraryReconciliationVolume(
            isLocal: values.volumeIsLocal,
            isInternal: values.volumeIsInternal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable,
            isUbiquitous: values.isUbiquitousItem,
            fileSystemType: fileSystemType
        )
    }
}
