import Foundation

/// Session observations only. A restored source has no successful-refresh date
/// until this process has completed an authoritative scan of that source.
enum MediaLibrarySourceHealthStatus: Equatable, Sendable {
    case notScanned
    case scanning
    case ready
    case unavailable
    case incomplete
    case failed
}

enum MediaLibrarySourceHealthIssue: Equatable, Hashable, Sendable {
    case authorizationRequired
    case permissionDenied
    case temporarilyUnavailable
    case sourceMissing
    case timeLimitExceeded
    case memoryLimitExceeded
    case unknown

    /// Do not infer an offline volume or a missing file from a failed bookmark
    /// or an opaque filesystem error. Only explicit permission errors qualify.
    static func filesystemError(_ error: any Error) -> Self {
        let error = error as NSError
        if (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoPermissionError
                || error.code == NSFileWriteNoPermissionError))
            || (error.domain == NSPOSIXErrorDomain
                && (error.code == Int(EACCES) || error.code == Int(EPERM))) {
            return .permissionDenied
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== error {
            // Inspect one underlying error only; user-supplied error chains
            // must not introduce unbounded recursive work.
            if underlying.domain == NSPOSIXErrorDomain,
               underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
                return .permissionDenied
            }
        }
        return .unknown
    }
}

struct MediaLibrarySourceHealth: Equatable, Sendable {
    let status: MediaLibrarySourceHealthStatus
    let issue: MediaLibrarySourceHealthIssue?
    let lastSuccessfulRefresh: Date?

    init(
        status: MediaLibrarySourceHealthStatus = .notScanned,
        issue: MediaLibrarySourceHealthIssue? = nil,
        lastSuccessfulRefresh: Date? = nil
    ) {
        self.status = status
        self.issue = issue
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
    }
}

struct MediaLibrarySourceScanDiagnostic: Equatable, Sendable {
    enum Coverage: Equatable, Sendable { case unavailable, incomplete }
    let coverage: Coverage
    let issue: MediaLibrarySourceHealthIssue
}

/// Pure, bounded state transitions. The coordinator calls these only after
/// validating its scan generation. Keys never outlive an active/stored source.
enum MediaLibrarySourceHealthReducer {
    static func reconcile(
        _ previous: [MediaLibraryRoot.ID: MediaLibrarySourceHealth],
        active: [MediaSource], unavailable: [UnavailableMediaSource]
    ) -> [MediaLibraryRoot.ID: MediaLibrarySourceHealth] {
        var result: [MediaLibraryRoot.ID: MediaLibrarySourceHealth] = [:]
        for source in unavailable {
            let id = MediaLibraryRoot.ID(
                standardizedPath: source.lastKnownURL.standardizedFileURL.path
            )
            result[id] = MediaLibrarySourceHealth(
                status: .unavailable, issue: source.issue ?? .unknown,
                lastSuccessfulRefresh: previous[id]?.lastSuccessfulRefresh
            )
        }
        for source in active {
            let id = MediaLibraryRoot.ID(standardizedPath: source.id.standardizedPath)
            result[id] = previous[id] ?? MediaLibrarySourceHealth()
        }
        return result
    }

    static func scanning(
        _ previous: [MediaLibraryRoot.ID: MediaLibrarySourceHealth],
        sources: [MediaSource]
    ) -> [MediaLibraryRoot.ID: MediaLibrarySourceHealth] {
        var result = previous
        for source in sources {
            let id = MediaLibraryRoot.ID(standardizedPath: source.id.standardizedPath)
            result[id] = MediaLibrarySourceHealth(
                status: .scanning, lastSuccessfulRefresh: previous[id]?.lastSuccessfulRefresh
            )
        }
        return result
    }

    static func completed(
        _ previous: [MediaLibraryRoot.ID: MediaLibrarySourceHealth],
        snapshot: MediaLibrarySnapshot, sources: [MediaSource], now: Date
    ) -> [MediaLibraryRoot.ID: MediaLibrarySourceHealth] {
        var result = previous
        let scannedIDs = Set(snapshot.roots.map(\.id))
        for source in sources {
            let id = MediaLibraryRoot.ID(standardizedPath: source.id.standardizedPath)
            let previousDate = previous[id]?.lastSuccessfulRefresh
            if let diagnostic = snapshot.sourceDiagnostics[id] {
                result[id] = MediaLibrarySourceHealth(
                    status: diagnostic.coverage == .incomplete ? .incomplete : .unavailable,
                    issue: diagnostic.issue, lastSuccessfulRefresh: previousDate
                )
            } else if snapshot.incompleteRootPaths.contains(id.standardizedPath) {
                result[id] = MediaLibrarySourceHealth(
                    status: .incomplete, issue: .unknown, lastSuccessfulRefresh: previousDate
                )
            } else if scannedIDs.contains(id) {
                result[id] = MediaLibrarySourceHealth(status: .ready, lastSuccessfulRefresh: now)
            } else {
                result[id] = MediaLibrarySourceHealth(
                    status: .unavailable, issue: .unknown, lastSuccessfulRefresh: previousDate
                )
            }
        }
        return result
    }

    static func failed(
        _ previous: [MediaLibraryRoot.ID: MediaLibrarySourceHealth],
        sources: [MediaSource], issue: MediaLibrarySourceHealthIssue
    ) -> [MediaLibraryRoot.ID: MediaLibrarySourceHealth] {
        var result = previous
        for source in sources {
            let id = MediaLibraryRoot.ID(standardizedPath: source.id.standardizedPath)
            result[id] = MediaLibrarySourceHealth(
                status: issue == .temporarilyUnavailable || issue == .permissionDenied
                    || issue == .authorizationRequired ? .unavailable : .failed,
                issue: issue, lastSuccessfulRefresh: previous[id]?.lastSuccessfulRefresh
            )
        }
        return result
    }
}

extension MediaLibraryScanError {
    var sourceHealthIssue: MediaLibrarySourceHealthIssue {
        switch self {
        case .permissionDenied: .permissionDenied
        case .rootUnavailable, .cannotEnumerateRoot: .temporarilyUnavailable
        case .timeLimitExceeded: .timeLimitExceeded
        case .memoryLimitExceeded: .memoryLimitExceeded
        default: .unknown
        }
    }
}
