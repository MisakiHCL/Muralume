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

private final class RestorePreparationBridge: @unchecked Sendable {
    private enum State {
        case pending
        case completed(MediaSourceRestorePreparation)
        case cancelled
        case delivered
    }

    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<
        MediaSourceRestorePreparation,
        Never
    >?
    private var preparationTask: Task<Void, Never>?

    func install(
        preparationTask: Task<Void, Never>
    ) {
        let shouldCancel: Bool
        lock.lock()
        shouldCancel = if case .cancelled = state { true } else { false }
        if case .pending = state {
            self.preparationTask = preparationTask
        }
        lock.unlock()

        if shouldCancel {
            preparationTask.cancel()
        }
    }

    func value() async -> MediaSourceRestorePreparation {
        await withCheckedContinuation { continuation in
            let immediatelyAvailableResult: MediaSourceRestorePreparation?
            lock.lock()
            switch state {
            case .pending:
                self.continuation = continuation
                immediatelyAvailableResult = nil
            case let .completed(result):
                state = .delivered
                immediatelyAvailableResult = result
            case .cancelled:
                immediatelyAvailableResult = .unavailable
            case .delivered:
                assertionFailure("Restore preparation result delivered twice")
                immediatelyAvailableResult = .unavailable
            }
            lock.unlock()

            if let immediatelyAvailableResult {
                continuation.resume(returning: immediatelyAvailableResult)
            }
        }
    }

    func complete(with result: MediaSourceRestorePreparation) {
        let waitingContinuation: CheckedContinuation<
            MediaSourceRestorePreparation,
            Never
        >?
        lock.lock()
        preparationTask = nil
        switch state {
        case .pending:
            waitingContinuation = continuation
            continuation = nil
            state = waitingContinuation == nil ? .completed(result) : .delivered
        case .cancelled, .delivered:
            waitingContinuation = nil
        case .completed:
            assertionFailure("Restore preparation completed twice")
            waitingContinuation = nil
        }
        lock.unlock()

        // When cancellation won the race, `result` is released here. A
        // resolved result consequently closes its executor-owned scope.
        waitingContinuation?.resume(returning: result)
    }

    func cancel() {
        let waitingContinuation: CheckedContinuation<
            MediaSourceRestorePreparation,
            Never
        >?
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        taskToCancel = preparationTask
        preparationTask = nil
        switch state {
        case .pending:
            state = .cancelled
            waitingContinuation = continuation
            continuation = nil
        case .completed:
            // Releasing the completed result closes any unadopted scope.
            state = .cancelled
            waitingContinuation = nil
        case .cancelled, .delivered:
            waitingContinuation = nil
        }
        lock.unlock()

        taskToCancel?.cancel()
        waitingContinuation?.resume(returning: .unavailable)
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
        UserSelectedMediaRestoreExecutor { kind, bookmark in
            let bridge = RestorePreparationBridge()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else {
                    return .unavailable
                }
                let preparationTask = Task.detached(
                    priority: .userInitiated
                ) {
                    let result = synchronousPreparation(kind, bookmark)
                    bridge.complete(with: result)
                }
                bridge.install(preparationTask: preparationTask)
                return await bridge.value()
            } onCancel: {
                bridge.cancel()
            }
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
