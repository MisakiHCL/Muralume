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
    static let latency: CFTimeInterval = 1
    static let sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    static let creationFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes
    )
}

private final class FSEventsCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func replaceHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.handler = handler
        }
    }

    func disable() {
        lock.withLock {
            handler = nil
        }
    }

    func emit() {
        let currentHandler = lock.withLock { handler }
        currentHandler?()
    }
}

private let mediaLibraryFSEventsCallback: FSEventStreamCallback = {
    _, contextInfo, eventCount, _, _, _ in
    guard eventCount > 0, let contextInfo else {
        return
    }
    let callbackBox = Unmanaged<FSEventsCallbackBox>
        .fromOpaque(contextInfo)
        .takeUnretainedValue()
    callbackBox.emit()
}

private let mediaLibraryFSEventsContextRetain: CFAllocatorRetainCallBack = {
    contextInfo in
    guard let contextInfo else {
        return nil
    }
    _ = Unmanaged<FSEventsCallbackBox>.fromOpaque(contextInfo).retain()
    return contextInfo
}

private let mediaLibraryFSEventsContextRelease: CFAllocatorReleaseCallBack = {
    contextInfo in
    guard let contextInfo else {
        return
    }
    Unmanaged<FSEventsCallbackBox>.fromOpaque(contextInfo).release()
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
    private let callbackQueue = DispatchQueue(
        label: "com.muralume.media-library-folder-monitor"
    )

    /// Access is serialized by `@MainActor`; unsafe non-isolation is limited to
    /// final teardown because Core Services' opaque pointer is not Sendable.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var callbackBox: FSEventsCallbackBox?
    private var activeFolderURLs: [URL] = []

    init(
        inspectVolume: @escaping VolumeInspection =
            FSEventsMediaLibraryChangeMonitor.inspectVolume
    ) {
        self.inspectVolume = inspectVolume
    }

    deinit {
        callbackBox?.disable()
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        callbackQueue.sync {}
        FSEventStreamRelease(stream)
    }

    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) -> Bool {
        let normalizedURLs = MediaLibraryFolderRootNormalizer.normalized(
            folderURLs
        )
        if normalizedURLs == activeFolderURLs, let callbackBox {
            callbackBox.replaceHandler(onChange)
            return true
        }

        stopStream()
        guard !normalizedURLs.isEmpty else {
            return true
        }

        let callbackBox = FSEventsCallbackBox(handler: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: mediaLibraryFSEventsContextRetain,
            release: mediaLibraryFSEventsContextRelease,
            copyDescription: nil
        )
        let paths = normalizedURLs.map(\.path) as CFArray
        guard let stream = FSEventStreamCreate(
            nil,
            mediaLibraryFSEventsCallback,
            &context,
            paths,
            FSEventsMediaLibraryChangePolicy.sinceWhen,
            FSEventsMediaLibraryChangePolicy.latency,
            FSEventsMediaLibraryChangePolicy.creationFlags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        guard FSEventStreamStart(stream) else {
            callbackBox.disable()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        self.stream = stream
        self.callbackBox = callbackBox
        activeFolderURLs = normalizedURLs
        return true
    }

    func stop() {
        stopStream()
    }

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

    private func stopStream() {
        guard let stream else {
            activeFolderURLs = []
            callbackBox = nil
            return
        }

        callbackBox?.disable()
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        callbackQueue.sync {}
        FSEventStreamRelease(stream)

        self.stream = nil
        callbackBox = nil
        activeFolderURLs = []
    }
}
