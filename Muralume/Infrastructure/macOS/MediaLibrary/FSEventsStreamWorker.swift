import Foundation

/// Every method, including teardown, is called only on the native worker queue.
protocol FSEventsStreamDriving: AnyObject, Sendable {
    func start() -> Bool
    func invalidate()
}

typealias FSEventsStreamFactory = @Sendable (
    [URL], @escaping @Sendable () -> Void
) -> (any FSEventsStreamDriving)?

struct FSEventsSecurityScopeAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

final class FSEventsCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }

    func disable() { lock.withLock { handler = nil } }

    func emit() {
        let callback = lock.withLock { self.handler }
        callback?()
    }
}

/// Native I/O keeps its own grant until destruction completes. Pending work
/// retains the original scoped URLs but performs no I/O until it owns a lease.
private final class FSEventsScopeLease {
    private let access: FSEventsSecurityScopeAccess
    private var grantedURLs: [URL] = []

    init(urls: [URL], access: FSEventsSecurityScopeAccess) {
        self.access = access
        for url in urls where access.start(url) { grantedURLs.append(url) }
    }

    deinit { grantedURLs.forEach(access.stop) }
}

final class FSEventsInstallationRequest: @unchecked Sendable {
    let id = UUID()
    let urls: [URL]
    let callbackGate: FSEventsCallbackGate
    private let lock = NSLock()
    private var valid = true
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: (any DispatchSourceTimer)?

    init(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        self.urls = urls
        callbackGate = FSEventsCallbackGate(onChange)
    }

    var isValid: Bool { lock.withLock { valid } }

    func attach(_ continuation: CheckedContinuation<Bool, Never>) {
        let completed = lock.withLock { () -> Bool? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(returning: completed) }
    }

    func finish(_ installed: Bool) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<Bool, Never>?, (any DispatchSourceTimer)?, Bool)? in
            guard result == nil else { return nil }
            let outcome = installed && valid
            result = outcome
            let completion = (continuation, timer, outcome)
            continuation = nil
            timer = nil
            return completion
        }
        guard let (continuation, timer, outcome) = completion else { return }
        timer?.cancel()
        continuation?.resume(returning: outcome)
    }

    func invalidate() {
        lock.withLock { valid = false }
        callbackGate.disable()
        finish(false)
    }

    /// A timer cancellation can race a handler that is already running. Only
    /// an unfinished installation may expire; success must remain installed.
    @discardableResult
    func expireIfPending() -> Bool {
        let expired = lock.withLock {
            guard result == nil else { return false }
            valid = false
            return true
        }
        guard expired else { return false }
        callbackGate.disable()
        finish(false)
        return true
    }

    func startDeadline(
        nanoseconds: UInt64, onTimeout: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))))
        timer.setEventHandler(handler: onTimeout)
        let shouldStart = lock.withLock {
            guard result == nil else { return false }
            self.timer = timer
            return true
        }
        if !shouldStart { timer.cancel() }
        // Even a cancelled suspended source must be resumed before release.
        timer.resume()
    }
}

/// One real native worker and one replaceable pending request. A timed-out C
/// call still owns this worker; retries never create another queue or thread.
final class FSEventsStreamWorker: @unchecked Sendable {
    private struct Installation {
        let request: FSEventsInstallationRequest
        let stream: any FSEventsStreamDriving
        let scope: FSEventsScopeLease
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.muralume.media-library-native-monitor", qos: .utility)
    private let factory: FSEventsStreamFactory
    private let scopeAccess: FSEventsSecurityScopeAccess
    private let timeoutNanoseconds: UInt64
    private var latest: FSEventsInstallationRequest?
    private var pending: FSEventsInstallationRequest?
    private var isDraining = false
    // This field belongs exclusively to queue. No caller or deinit touches it.
    private var installation: Installation?

    init(
        factory: @escaping FSEventsStreamFactory,
        scopeAccess: FSEventsSecurityScopeAccess,
        timeoutNanoseconds: UInt64
    ) {
        self.factory = factory
        self.scopeAccess = scopeAccess
        self.timeoutNanoseconds = max(timeoutNanoseconds, 1)
    }

    func update(
        urls: [URL], onChange: @escaping @Sendable () -> Void
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = FSEventsInstallationRequest(urls: urls, onChange: onChange)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.attach(continuation)
                submit(request)
                request.startDeadline(nanoseconds: timeoutNanoseconds) {
                    [weak self, weak request] in
                    guard let request, request.expireIfPending() else { return }
                    self?.cancel(requestID: request.id)
                }
            }
        } onCancel: {
            request.invalidate()
            self.cancel(requestID: request.id)
        }
    }

    func stop() {
        let previous = lock.withLock { () -> FSEventsInstallationRequest? in
            let previous = latest
            latest = nil
            pending = nil
            scheduleDrainLocked()
            return previous
        }
        previous?.invalidate()
    }

    private func submit(_ request: FSEventsInstallationRequest) {
        let previous = lock.withLock { () -> FSEventsInstallationRequest? in
            guard request.isValid else { return nil }
            let previous = latest
            latest = request
            pending = request
            scheduleDrainLocked()
            return previous
        }
        previous?.invalidate()
    }

    private func cancel(requestID: UUID) {
        lock.withLock {
            guard latest?.id == requestID else { return }
            latest = nil
            pending = nil
            scheduleDrainLocked()
        }
    }

    private func scheduleDrainLocked() {
        guard !isDraining else { return }
        isDraining = true
        queue.async { self.drain() }
    }

    private func isCurrent(_ request: FSEventsInstallationRequest) -> Bool {
        lock.withLock { latest?.id == request.id } && request.isValid
    }

    private func drain() {
        while true {
            let request = lock.withLock { () -> FSEventsInstallationRequest? in
                let request = pending
                pending = nil
                return request
            }
            if let request {
                destroyInstallation()
                install(request)
                continue
            }
            if let installation, !isCurrent(installation.request) {
                destroyInstallation()
                continue
            }
            let finished = lock.withLock {
                guard pending == nil else { return false }
                // Stop can arrive after the check above and must still destroy
                // the old stream before this drain relinquishes its work slot.
                if let installation, latest?.id != installation.request.id {
                    return false
                }
                isDraining = false
                return true
            }
            if finished { return }
        }
    }

    private func install(_ request: FSEventsInstallationRequest) {
        guard isCurrent(request) else {
            request.invalidate()
            return
        }
        let scope = FSEventsScopeLease(urls: request.urls, access: scopeAccess)
        guard isCurrent(request) else { request.invalidate(); return }
        guard !request.urls.isEmpty else {
            request.finish(true)
            return
        }
        guard let stream = factory(request.urls, { request.callbackGate.emit() }) else {
            request.callbackGate.disable()
            request.finish(false)
            return
        }
        guard isCurrent(request), stream.start(), isCurrent(request) else {
            request.callbackGate.disable()
            stream.invalidate()
            withExtendedLifetime(scope) {}
            request.finish(false)
            return
        }
        installation = Installation(request: request, stream: stream, scope: scope)
        request.finish(true)
    }

    private func destroyInstallation() {
        guard let installed = installation else { return }
        installation = nil
        installed.request.callbackGate.disable()
        installed.stream.invalidate()
        // Scope release follows all native stop/invalidate/queue-drain/release.
        withExtendedLifetime(installed.scope) {}
    }
}
