import Foundation

@MainActor
struct SecurityScopedMediaAccess {
    struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    let makeBookmark: (URL) -> Data?
    let resolveBookmark: (Data) -> ResolvedBookmark?
    let startAccess: (URL) -> Bool
    let stopAccess: (URL) -> Void

    static let live = SecurityScopedMediaAccess(
        makeBookmark: { url in
            try? url.bookmarkData(
                options: [
                    .withSecurityScope,
                    .securityScopeAllowOnlyReadAccess
                ],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: { bookmark in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [
                    .withSecurityScope,
                    .withoutUI,
                    .withoutMounting
                ],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return ResolvedBookmark(url: url, isStale: isStale)
        },
        startAccess: { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccess: { url in
            url.stopAccessingSecurityScopedResource()
        }
    )
}

struct MediaSourceURLInspector {
    struct LinkResolution: Sendable {
        let targetURL: URL
        let didResolveLink: Bool
    }

    static func liveSourceKind(at url: URL) -> MediaSourceKind? {
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

    static func isSupported(kind: MediaSourceKind, url: URL) -> Bool {
        kind == .folder
            || MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                url.pathExtension.lowercased()
            )
    }

    static func linkResolution(for url: URL) -> LinkResolution {
        let values = try? url.resourceValues(
            forKeys: [.isAliasFileKey, .isSymbolicLinkKey]
        )
        let isAlias = values?.isAliasFile == true
        let isSymbolicLink = values?.isSymbolicLink == true
        let aliasResolvedURL = if isAlias {
            (
                try? URL(
                    resolvingAliasFileAt: url,
                    options: [.withoutUI, .withoutMounting]
                )
            ) ?? url
        } else {
            url
        }

        return LinkResolution(
            targetURL: aliasResolvedURL
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            didResolveLink: isAlias || isSymbolicLink
        )
    }

    static func resourceIdentifier(for url: URL) -> NSObject? {
        do {
            return try url.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier as? NSObject
        } catch {
            return nil
        }
    }
}

struct PreparedMediaSourceRestore: @unchecked Sendable {
    let resolvedURL: URL
    let linkResolution: MediaSourceURLInspector.LinkResolution
    let refreshedBookmark: Data?
    let resourceIdentifier: NSObject?
}

/// Owns the security scope opened while a bookmark is prepared off actor.
/// The scope is either transferred exactly once to `UserSelectedMediaSession`
/// or closed by this object, including when a task is cancelled or superseded.
final class ExecutorOwnedPreparedMediaSourceRestore: @unchecked Sendable {
    let restore: PreparedMediaSourceRestore

    private let lock = NSLock()
    private let stopAccess: @Sendable (URL) -> Void
    private var ownsScope = true

    init(
        restore: PreparedMediaSourceRestore,
        stopAccess: @escaping @Sendable (URL) -> Void
    ) {
        self.restore = restore
        self.stopAccess = stopAccess
    }

    deinit {
        closeScopeIfOwned()
    }

    func transferScopeToSession() {
        lock.lock()
        ownsScope = false
        lock.unlock()
    }

    func closeScopeIfOwned() {
        let shouldClose: Bool
        lock.lock()
        shouldClose = ownsScope
        ownsScope = false
        lock.unlock()

        if shouldClose {
            stopAccess(restore.resolvedURL)
        }
    }
}

enum MediaSourceRestorePreparation: @unchecked Sendable {
    case unavailable
    case resolved(ExecutorOwnedPreparedMediaSourceRestore)
}

/// Bounds synchronous bookmark work that may ignore Swift task cancellation.
/// A running worker remains charged against the hard limit until the resolver
/// actually returns. A later request for the same bookmark joins that worker,
/// while cancelled queued requests are removed before they can consume a slot.
private final class DetachedRestorePreparationCoordinator:
    @unchecked Sendable {
    private enum Policy {
        // One stalled volume must not prevent every other persisted source from
        // being inspected, while repeated retries must remain tightly bounded.
        static let maximumConcurrentPreparationCount = 2
    }

    private struct WorkKey: Hashable, Sendable {
        let kind: MediaSourceKind
        let bookmark: Data
    }

    private final class RequestToken: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelledStorage = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelledStorage
        }

        func cancel() {
            lock.lock()
            isCancelledStorage = true
            lock.unlock()
        }
    }

    private final class WorkItem {
        enum State: Equatable {
            case queued
            case running
        }

        let key: WorkKey
        var state: State = .queued
        var requestIDs: [ObjectIdentifier] = []
        var task: Task<Void, Never>?
        var didRequestCancellation = false

        init(key: WorkKey) {
            self.key = key
        }
    }

    private struct RequestRecord {
        let token: RequestToken
        var key: WorkKey?
        var isCancelled = false
        var continuation: CheckedContinuation<
            MediaSourceRestorePreparation,
            Never
        >?
        var completedResult: MediaSourceRestorePreparation?
    }

    private struct Delivery {
        let continuation: CheckedContinuation<
            MediaSourceRestorePreparation,
            Never
        >
        let result: MediaSourceRestorePreparation
    }

    private let lock = NSLock()
    private let synchronousPreparation: @Sendable (
        MediaSourceKind,
        Data
    ) -> MediaSourceRestorePreparation
    private var requests: [ObjectIdentifier: RequestRecord] = [:]
    private var workItemsByKey: [WorkKey: WorkItem] = [:]
    private var queuedWorkKeys: [WorkKey] = []
    private var runningPreparationCount = 0

    init(
        synchronousPreparation: @escaping @Sendable (
            MediaSourceKind,
            Data
        ) -> MediaSourceRestorePreparation
    ) {
        self.synchronousPreparation = synchronousPreparation
    }

    func prepare(
        kind: MediaSourceKind,
        bookmark: Data
    ) async -> MediaSourceRestorePreparation {
        let token = RequestToken()
        let requestID = ObjectIdentifier(token)
        let key = WorkKey(kind: kind, bookmark: bookmark)

        return await withTaskCancellationHandler {
            guard register(token, requestID: requestID, key: key) else {
                return .unavailable
            }
            return await value(for: requestID)
        } onCancel: {
            token.cancel()
            cancel(requestID: requestID)
        }
    }

    private func register(
        _ token: RequestToken,
        requestID: ObjectIdentifier,
        key: WorkKey
    ) -> Bool {
        lock.lock()
        guard !token.isCancelled else {
            lock.unlock()
            return false
        }

        requests[requestID] = RequestRecord(token: token, key: key)
        if let existingWorkItem = workItemsByKey[key] {
            existingWorkItem.requestIDs.append(requestID)
        } else {
            let workItem = WorkItem(key: key)
            workItem.requestIDs.append(requestID)
            workItemsByKey[key] = workItem
            queuedWorkKeys.append(key)
        }
        startQueuedWorkIfPossibleLocked()
        lock.unlock()
        return true
    }

    private func value(
        for requestID: ObjectIdentifier
    ) async -> MediaSourceRestorePreparation {
        await withCheckedContinuation { continuation in
            let immediateResult: MediaSourceRestorePreparation?
            lock.lock()
            guard var request = requests[requestID] else {
                lock.unlock()
                continuation.resume(returning: .unavailable)
                return
            }

            if request.isCancelled {
                requests[requestID] = nil
                immediateResult = .unavailable
            } else if let completedResult = request.completedResult {
                requests[requestID] = nil
                immediateResult = completedResult
            } else {
                request.continuation = continuation
                requests[requestID] = request
                immediateResult = nil
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    private func cancel(requestID: ObjectIdentifier) {
        let waitingContinuation: CheckedContinuation<
            MediaSourceRestorePreparation,
            Never
        >?
        var completedResultToRelease: MediaSourceRestorePreparation?

        lock.lock()
        guard var request = requests[requestID] else {
            lock.unlock()
            return
        }
        request.isCancelled = true
        completedResultToRelease = request.completedResult
        request.completedResult = nil

        if let key = request.key,
           let workItem = workItemsByKey[key] {
            workItem.requestIDs.removeAll { $0 == requestID }
            if workItem.requestIDs.isEmpty {
                switch workItem.state {
                case .queued:
                    removeQueuedWorkItemLocked(workItem)
                case .running:
                    // Cancellation is still useful for cooperative resolvers,
                    // but this worker remains charged until it really returns.
                    workItem.didRequestCancellation = true
                    workItem.task?.cancel()
                }
            }
        }
        request.key = nil

        waitingContinuation = request.continuation
        request.continuation = nil
        if waitingContinuation == nil {
            // `value(for:)` has not installed its continuation yet. Preserve a
            // small tombstone so it can observe cancellation and return.
            requests[requestID] = request
        } else {
            requests[requestID] = nil
        }
        startQueuedWorkIfPossibleLocked()
        lock.unlock()

        _ = completedResultToRelease
        waitingContinuation?.resume(returning: .unavailable)
    }

    private func complete(
        workKey: WorkKey,
        workItemID: ObjectIdentifier,
        result: MediaSourceRestorePreparation
    ) {
        var deliveries: [Delivery] = []

        lock.lock()
        guard let workItem = workItemsByKey[workKey],
              ObjectIdentifier(workItem) == workItemID,
              workItem.state == .running else {
            lock.unlock()
            return
        }

        workItem.task = nil
        runningPreparationCount -= 1
        workItem.requestIDs.removeAll { requestID in
            guard let request = requests[requestID] else {
                return true
            }
            return request.isCancelled
        }

        switch result {
        case .unavailable:
            if workItem.didRequestCancellation,
               !workItem.requestIDs.isEmpty {
                // A retry may have joined after the previous caller cancelled
                // this worker. Do not publish inherited cancellation as a real
                // bookmark failure; give the remaining callers a fresh run.
                workItem.state = .queued
                queuedWorkKeys.append(workItem.key)
            } else {
                let requestIDs = workItem.requestIDs
                removeWorkItemLocked(workItem)
                for requestID in requestIDs {
                    if let delivery = completeRequestLocked(
                        requestID,
                        with: .unavailable
                    ) {
                        deliveries.append(delivery)
                    }
                }
            }
        case .resolved:
            if let requestID = workItem.requestIDs.first {
                workItem.requestIDs.removeFirst()
                if let delivery = completeRequestLocked(
                    requestID,
                    with: result
                ) {
                    deliveries.append(delivery)
                }
            }

            if workItem.requestIDs.isEmpty {
                removeWorkItemLocked(workItem)
            } else {
                workItem.state = .queued
                queuedWorkKeys.append(workItem.key)
            }
        }

        startQueuedWorkIfPossibleLocked()
        lock.unlock()

        for delivery in deliveries {
            delivery.continuation.resume(returning: delivery.result)
        }
    }

    private func completeRequestLocked(
        _ requestID: ObjectIdentifier,
        with result: MediaSourceRestorePreparation
    ) -> Delivery? {
        guard var request = requests[requestID],
              !request.isCancelled else {
            return nil
        }
        request.key = nil
        if let continuation = request.continuation {
            requests[requestID] = nil
            return Delivery(continuation: continuation, result: result)
        }
        request.completedResult = result
        requests[requestID] = request
        return nil
    }

    private func startQueuedWorkIfPossibleLocked() {
        while runningPreparationCount
                < Policy.maximumConcurrentPreparationCount,
              !queuedWorkKeys.isEmpty {
            let key = queuedWorkKeys.removeFirst()
            guard let workItem = workItemsByKey[key],
                  workItem.state == .queued,
                  !workItem.requestIDs.isEmpty else {
                continue
            }

            workItem.state = .running
            workItem.didRequestCancellation = false
            runningPreparationCount += 1
            let workItemID = ObjectIdentifier(workItem)
            let synchronousPreparation = synchronousPreparation
            workItem.task = Task.detached(priority: .userInitiated) {
                [weak self] in
                let result = synchronousPreparation(key.kind, key.bookmark)
                self?.complete(
                    workKey: key,
                    workItemID: workItemID,
                    result: result
                )
            }
        }
    }

    private func removeQueuedWorkItemLocked(_ workItem: WorkItem) {
        queuedWorkKeys.removeAll { $0 == workItem.key }
        removeWorkItemLocked(workItem)
    }

    private func removeWorkItemLocked(_ workItem: WorkItem) {
        guard workItemsByKey[workItem.key] === workItem else {
            return
        }
        workItemsByKey[workItem.key] = nil
    }
}

/// Resolves persisted security-scoped bookmarks away from the main actor.
/// Every resolved result retains its scope until the session explicitly adopts
/// it; dropping or rejecting the result closes the scope automatically.
struct UserSelectedMediaRestoreExecutor: Sendable {
    typealias Prepare = @Sendable (
        MediaSourceKind,
        Data
    ) async -> MediaSourceRestorePreparation

    static let live = detached(prepare: Self.prepareSynchronously)

    private let prepareOperation: Prepare

    init(prepare: @escaping Prepare) {
        prepareOperation = prepare
    }

    func prepare(
        kind: MediaSourceKind,
        bookmark: Data
    ) async -> MediaSourceRestorePreparation {
        await prepareOperation(kind, bookmark)
    }

    /// Runs a synchronous resolver away from the caller while allowing the
    /// caller to return promptly if cancellation wins the race. Kept internal
    /// so cancellation semantics can be exercised with a non-cooperative test
    /// resolver without manufacturing real sandbox bookmarks.
    static func detached(
        prepare synchronousPreparation: @escaping @Sendable (
            MediaSourceKind,
            Data
        ) -> MediaSourceRestorePreparation
    ) -> UserSelectedMediaRestoreExecutor {
        let coordinator = DetachedRestorePreparationCoordinator(
            synchronousPreparation: synchronousPreparation
        )
        return UserSelectedMediaRestoreExecutor { kind, bookmark in
            await coordinator.prepare(kind: kind, bookmark: bookmark)
        }
    }

    private static func prepareSynchronously(
        kind: MediaSourceKind,
        bookmark: Data
    ) -> MediaSourceRestorePreparation {
        guard !Task.isCancelled else {
            return .unavailable
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [
                .withSecurityScope,
                .withoutUI,
                .withoutMounting
            ],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !Task.isCancelled,
        resolvedURL.startAccessingSecurityScopedResource() else {
            return .unavailable
        }
        var executorOwnsScope = true
        defer {
            if executorOwnsScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        guard !Task.isCancelled else {
            return .unavailable
        }

        let linkResolution = MediaSourceURLInspector.linkResolution(
            for: resolvedURL
        )
        guard !Task.isCancelled,
        MediaSourceURLInspector.liveSourceKind(
            at: linkResolution.targetURL
        ) == kind,
        MediaSourceURLInspector.isSupported(
            kind: kind,
            url: linkResolution.targetURL
        ) else {
            return .unavailable
        }

        let refreshedBookmark = try? resolvedURL.bookmarkData(
            options: [
                .withSecurityScope,
                .securityScopeAllowOnlyReadAccess
            ],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let boundedRefreshedBookmark = refreshedBookmark.flatMap { bookmark in
            bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount
                ? bookmark
                : nil
        }
        guard !Task.isCancelled else {
            return .unavailable
        }

        let preparedRestore = ExecutorOwnedPreparedMediaSourceRestore(
            restore: PreparedMediaSourceRestore(
                resolvedURL: resolvedURL,
                linkResolution: linkResolution,
                refreshedBookmark: boundedRefreshedBookmark,
                resourceIdentifier: MediaSourceURLInspector.resourceIdentifier(
                    for: linkResolution.targetURL.standardizedFileURL
                )
            ),
            stopAccess: { url in
                url.stopAccessingSecurityScopedResource()
            }
        )
        executorOwnsScope = false
        return .resolved(preparedRestore)
    }
}
