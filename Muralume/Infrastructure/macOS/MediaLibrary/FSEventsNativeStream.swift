import CoreServices
import Foundation

private let nativeFSEventsCallback: FSEventStreamCallback = {
    _, contextInfo, eventCount, _, _, _ in
    guard eventCount > 0, let contextInfo else { return }
    Unmanaged<FSEventsCallbackGate>.fromOpaque(contextInfo)
        .takeUnretainedValue().emit()
}

private let nativeFSEventsContextRetain: CFAllocatorRetainCallBack = { info in
    guard let info else { return nil }
    _ = Unmanaged<FSEventsCallbackGate>.fromOpaque(info).retain()
    return info
}

private let nativeFSEventsContextRelease: CFAllocatorReleaseCallBack = { info in
    guard let info else { return }
    Unmanaged<FSEventsCallbackGate>.fromOpaque(info).release()
}

/// Opaque Core Services ownership never escapes the serial native worker.
final class FSEventsNativeStream: FSEventsStreamDriving, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let gate: FSEventsCallbackGate
    private let callbackQueue: DispatchQueue
    private var started = false

    static func factory() -> FSEventsStreamFactory {
        let callbacks = DispatchQueue(label: "com.muralume.media-library-folder-events")
        return { urls, onChange in
            FSEventsNativeStream(urls: urls, onChange: onChange, callbackQueue: callbacks)
        }
    }

    private init?(
        urls: [URL], onChange: @escaping @Sendable () -> Void,
        callbackQueue: DispatchQueue
    ) {
        gate = FSEventsCallbackGate(onChange)
        self.callbackQueue = callbackQueue
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(gate).toOpaque(),
            retain: nativeFSEventsContextRetain,
            release: nativeFSEventsContextRelease,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil, nativeFSEventsCallback, &context, urls.map(\.path) as CFArray,
            FSEventsMediaLibraryChangePolicy.sinceWhen,
            FSEventsMediaLibraryChangePolicy.latency,
            FSEventsMediaLibraryChangePolicy.creationFlags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
    }

    func start() -> Bool {
        guard let stream else { return false }
        started = FSEventStreamStart(stream)
        return started
    }

    func invalidate() {
        gate.disable()
        guard let stream else { return }
        self.stream = nil
        if started { FSEventStreamStop(stream) }
        FSEventStreamInvalidate(stream)
        // The event queue is separate from the native ownership queue.
        callbackQueue.sync {}
        FSEventStreamRelease(stream)
    }
}
