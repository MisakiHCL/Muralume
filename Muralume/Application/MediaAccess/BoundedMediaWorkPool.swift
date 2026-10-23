import Foundation

/// Cancellation releases the caller promptly, but a running operation keeps
/// its slot until it actually returns, including non-cooperative file I/O.
final class BoundedMediaWorkPool: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private final class Work {
        let id: UUID
        let operation: @Sendable () async -> Void
        let cancelCaller: @Sendable () -> Void
        var task: Task<Void, Never>?
        var isCancelled = false

        init(
            id: UUID,
            operation: @escaping @Sendable () async -> Void,
            cancelCaller: @escaping @Sendable () -> Void
        ) {
            self.id = id
            self.operation = operation
            self.cancelCaller = cancelCaller
        }
    }

    private let lock = NSLock()
    private let maximumConcurrentWorkCount: Int
    private let maximumQueuedWorkCount: Int
    private var running: [UUID: Work] = [:]
    private var queued: [Work] = []

    init(maximumConcurrentWorkCount: Int, maximumQueuedWorkCount: Int = 256) {
        precondition(maximumConcurrentWorkCount > 0)
        precondition(maximumQueuedWorkCount > 0)
        self.maximumConcurrentWorkCount = maximumConcurrentWorkCount
        self.maximumQueuedWorkCount = maximumQueuedWorkCount
    }

    func run<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let id = UUID()
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let work = Work(
                    id: id,
                    operation: { [weak self] in
                        let result: Result<Output, Error>
                        do {
                            try Task.checkCancellation()
                            result = .success(try await operation())
                        } catch {
                            result = .failure(error)
                        }
                        self?.finish(id: id) {
                            continuation.resume(with: result)
                        }
                    },
                    cancelCaller: {
                        continuation.resume(throwing: CancellationError())
                    }
                )
                register(work, token: token)
            }
        } onCancel: {
            token.cancel()
            self.cancel(id: id)
        }
    }

    private func register(_ work: Work, token: CancellationToken) {
        lock.lock()
        guard !token.isCancelled, queued.count < maximumQueuedWorkCount else {
            lock.unlock()
            work.cancelCaller()
            return
        }
        queued.append(work)
        startQueuedWorkLocked()
        lock.unlock()
    }

    private func cancel(id: UUID) {
        lock.lock()
        let work: Work?
        if let index = queued.firstIndex(where: { $0.id == id }) {
            work = queued.remove(at: index)
        } else {
            work = running[id]
        }
        guard let work, !work.isCancelled else {
            lock.unlock()
            return
        }
        work.isCancelled = true
        let task = work.task
        lock.unlock()
        task?.cancel()
        work.cancelCaller()
    }

    private func finish(id: UUID, deliver: @Sendable () -> Void) {
        lock.lock()
        guard let work = running.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        work.task = nil
        let shouldDeliver = !work.isCancelled
        startQueuedWorkLocked()
        lock.unlock()
        if shouldDeliver { deliver() }
    }

    private func startQueuedWorkLocked() {
        while running.count < maximumConcurrentWorkCount, !queued.isEmpty {
            let work = queued.removeFirst()
            running[work.id] = work
            let operation = work.operation
            work.task = Task.detached(priority: .userInitiated) {
                await operation()
            }
        }
    }
}
