import Foundation

enum MediaLibraryAutomaticRefreshPolicy {
    static let debounceNanoseconds: UInt64 = 1_000_000_000
    static let scanFailureRetryNanoseconds: UInt64 = 5_000_000_000
    static let installationRetryNanoseconds: UInt64 = 5_000_000_000
    static let installationRecoveryNanoseconds: UInt64 = 60_000_000_000
    /// FSEvents can start successfully but still omit notifications for some
    /// removable, network, cloud-placeholder, and FUSE-backed folders. A
    /// bounded authoritative rescan keeps an active library convergent without
    /// turning the normal one-second event path into continuous polling.
    static let reconciliationNanoseconds: UInt64 = 60_000_000_000
    static let maximumInstallationRetryCount = 3
}

struct MediaLibraryAutomaticRefreshSchedule: Equatable, Sendable {
    static let production = MediaLibraryAutomaticRefreshSchedule(
        debounceNanoseconds:
            MediaLibraryAutomaticRefreshPolicy.debounceNanoseconds,
        reconciliationNanoseconds:
            MediaLibraryAutomaticRefreshPolicy.reconciliationNanoseconds
    )

    let debounceNanoseconds: UInt64
    let reconciliationNanoseconds: UInt64
}

enum MediaLibraryFolderRootNormalizer {
    static func normalized(_ folderURLs: [URL]) -> [URL] {
        var uniqueURLsByPath: [String: URL] = [:]
        for folderURL in folderURLs where folderURL.isFileURL {
            let normalizedURL = folderURL.standardizedFileURL
            uniqueURLsByPath[normalizedURL.path] = normalizedURL
        }
        return uniqueURLsByPath.values.sorted {
            $0.path.compare($1.path) == .orderedAscending
        }
    }
}

@MainActor
protocol MediaLibraryChangeMonitoring: AnyObject {
    /// Returns whether monitoring is active for the requested roots. An empty
    /// roots list counts as successfully installed because no stream is needed.
    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) -> Bool
    func stop()
}

@MainActor
final class DisabledMediaLibraryChangeMonitor: MediaLibraryChangeMonitoring {
    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) -> Bool {
        true
    }

    func stop() {}
}

/// The narrow adapter needed by automatic refresh. The media library remains
/// responsible for deciding whether a refresh request can actually start.
@MainActor
protocol MediaLibraryAutomaticRefreshTarget: AnyObject {
    var automaticRefreshIsScanning: Bool { get }
    var automaticRefreshLastScanSucceeded: Bool { get }

    @discardableResult
    func requestAutomaticRefresh() -> Bool
}

extension MediaLibraryCoordinator {
    var automaticRefreshLastScanSucceeded: Bool {
        scanState == .ready
    }
}

/// Turns coarse file-system notifications into bounded media-library refreshes.
/// Publishers must pass their emitted scan state to `scanStateDidChange` so
/// will-set delivery cannot make the controller observe stale target state.
@MainActor
final class MediaLibraryAutomaticRefreshController {
    private struct ScanMarker {
        let generation: UInt64
        let dirtyRevisionAtStart: UInt64
    }

    private let monitor: any MediaLibraryChangeMonitoring
    private weak var target: (any MediaLibraryAutomaticRefreshTarget)?
    private let debounceNanoseconds: UInt64
    private let scanFailureRetryNanoseconds: UInt64
    private let installationRetryNanoseconds: UInt64
    private let installationRecoveryNanoseconds: UInt64
    private let reconciliationNanoseconds: UInt64
    private let maximumInstallationRetryCount: Int

    private var folderURLs: [URL] = []
    private var generation: UInt64 = 0
    private var dirtyRevision: UInt64 = 0
    private var coveredRevision: UInt64 = 0
    private var scanMarker: ScanMarker?
    private var refreshTask: Task<Void, Never>?
    private var installationRetryTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var isStarted = false
    private var wasScanning = false
    private var hasPendingRefreshRequest = false
    private var monitoringGapNeedsReconciliation = false

    init(
        monitor: any MediaLibraryChangeMonitoring,
        target: any MediaLibraryAutomaticRefreshTarget,
        debounceNanoseconds: UInt64 =
            MediaLibraryAutomaticRefreshPolicy.debounceNanoseconds,
        scanFailureRetryNanoseconds: UInt64 =
            MediaLibraryAutomaticRefreshPolicy.scanFailureRetryNanoseconds,
        installationRetryNanoseconds: UInt64 =
            MediaLibraryAutomaticRefreshPolicy.installationRetryNanoseconds,
        installationRecoveryNanoseconds: UInt64 =
            MediaLibraryAutomaticRefreshPolicy
                .installationRecoveryNanoseconds,
        reconciliationNanoseconds: UInt64 =
            MediaLibraryAutomaticRefreshPolicy.reconciliationNanoseconds,
        maximumInstallationRetryCount: Int =
            MediaLibraryAutomaticRefreshPolicy.maximumInstallationRetryCount
    ) {
        self.monitor = monitor
        self.target = target
        self.debounceNanoseconds = debounceNanoseconds
        self.scanFailureRetryNanoseconds = scanFailureRetryNanoseconds
        self.installationRetryNanoseconds = installationRetryNanoseconds
        self.installationRecoveryNanoseconds =
            installationRecoveryNanoseconds
        self.reconciliationNanoseconds = max(1, reconciliationNanoseconds)
        self.maximumInstallationRetryCount = max(
            0,
            maximumInstallationRetryCount
        )
    }

    func start(folderURLs: [URL]) {
        guard !isStarted else {
            update(folderURLs: folderURLs)
            return
        }

        isStarted = true
        wasScanning = target?.automaticRefreshIsScanning ?? false
        install(folderURLs: folderURLs, force: true)
        if wasScanning {
            scanMarker = ScanMarker(
                generation: generation,
                dirtyRevisionAtStart: dirtyRevision
            )
        }
    }

    func update(folderURLs: [URL]) {
        guard isStarted else {
            return
        }
        install(folderURLs: folderURLs, force: false)
    }

    func scanStateDidChange(
        isScanning: Bool,
        lastScanSucceeded: Bool
    ) {
        guard isStarted, target != nil else {
            return
        }

        if isScanning {
            observeScanningStartIfNeeded()
            return
        }

        guard wasScanning else {
            if !hasPendingRefreshRequest {
                scheduleRefreshIfNeeded()
            }
            scheduleReconciliationIfNeeded()
            return
        }

        wasScanning = false
        hasPendingRefreshRequest = false
        let scanSucceeded = lastScanSucceeded
        if scanSucceeded,
           let scanMarker,
           scanMarker.generation == generation {
            coveredRevision = max(
                coveredRevision,
                scanMarker.dirtyRevisionAtStart
            )
        }
        scanMarker = nil
        scheduleRefreshIfNeeded(
            delayNanoseconds: scanSucceeded
                ? debounceNanoseconds
                : scanFailureRetryNanoseconds
        )
        scheduleReconciliationIfNeeded()
    }

    /// Convenience for callers that are not observing a will-set publisher.
    /// Combine subscribers must pass the emitted state to the overload above
    /// instead of reading the target while `@Published` still stores its old
    /// value.
    func scanStateDidChange() {
        guard let target else {
            return
        }
        scanStateDidChange(
            isScanning: target.automaticRefreshIsScanning,
            lastScanSucceeded: target.automaticRefreshLastScanSucceeded
        )
    }

    func stop() {
        guard isStarted else {
            return
        }

        isStarted = false
        advanceGeneration()
        refreshTask?.cancel()
        refreshTask = nil
        installationRetryTask?.cancel()
        installationRetryTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        folderURLs = []
        dirtyRevision = 0
        coveredRevision = 0
        scanMarker = nil
        wasScanning = false
        hasPendingRefreshRequest = false
        monitoringGapNeedsReconciliation = false
        monitor.stop()
    }

    private func install(folderURLs: [URL], force: Bool) {
        let normalizedURLs = MediaLibraryFolderRootNormalizer.normalized(
            folderURLs
        )
        guard force || normalizedURLs != self.folderURLs else {
            return
        }

        advanceGeneration()
        refreshTask?.cancel()
        refreshTask = nil
        installationRetryTask?.cancel()
        installationRetryTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        self.folderURLs = normalizedURLs
        dirtyRevision = 0
        coveredRevision = 0
        scanMarker = nil
        hasPendingRefreshRequest = false
        monitoringGapNeedsReconciliation = false

        _ = attemptMonitorInstallation(
            generation: generation,
            retryNumber: 0
        )
        scheduleReconciliationIfNeeded()
    }

    @discardableResult
    private func attemptMonitorInstallation(
        generation installationGeneration: UInt64,
        retryNumber: Int
    ) -> Bool {
        guard isStarted,
              installationGeneration == generation else {
            return false
        }

        let installed = monitor.update(folderURLs: folderURLs) { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordChange(generation: installationGeneration)
            }
        }
        guard !installed else {
            installationRetryTask = nil
            if monitoringGapNeedsReconciliation {
                monitoringGapNeedsReconciliation = false
                recordChange(generation: installationGeneration)
            }
            return true
        }
        monitoringGapNeedsReconciliation = true

        scheduleMonitorInstallationRetry(
            generation: installationGeneration,
            retryNumber: retryNumber + 1
        )
        return false
    }

    private func scheduleMonitorInstallationRetry(
        generation retryGeneration: UInt64,
        retryNumber: Int
    ) {
        guard isStarted,
              retryGeneration == generation,
              !folderURLs.isEmpty else {
            installationRetryTask = nil
            return
        }
        let retryDelayNanoseconds: UInt64
        let nextRetryNumber: Int
        if retryNumber <= maximumInstallationRetryCount {
            retryDelayNanoseconds = installationRetryNanoseconds
            nextRetryNumber = retryNumber
        } else {
            // The stream stayed unavailable. Treat its whole retry window as
            // a possible coarse change, then keep a low-frequency recovery
            // cycle running so this process cannot lose monitoring forever.
            recordChange(generation: retryGeneration)
            retryDelayNanoseconds = installationRecoveryNanoseconds
            nextRetryNumber = 0
        }

        installationRetryTask?.cancel()
        installationRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: retryDelayNanoseconds
                )
            } catch {
                return
            }
            guard let self,
                  self.isStarted,
                  retryGeneration == self.generation else {
                return
            }
            self.installationRetryTask = nil
            _ = self.attemptMonitorInstallation(
                generation: retryGeneration,
                retryNumber: nextRetryNumber
            )
        }
    }

    private func recordChange(generation eventGeneration: UInt64) {
        guard isStarted,
              eventGeneration == generation,
              !folderURLs.isEmpty else {
            return
        }

        dirtyRevision &+= 1
        guard target != nil else {
            return
        }
        if wasScanning {
            observeScanningStartIfNeeded()
        } else if !hasPendingRefreshRequest {
            scheduleRefreshIfNeeded()
        }
    }

    private func observeScanningStartIfNeeded() {
        guard !wasScanning else {
            return
        }

        wasScanning = true
        refreshTask?.cancel()
        refreshTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        scanMarker = ScanMarker(
            generation: generation,
            dirtyRevisionAtStart: dirtyRevision
        )
    }

    private func scheduleReconciliationIfNeeded() {
        guard isStarted,
              !folderURLs.isEmpty,
              !wasScanning,
              target != nil,
              reconciliationTask == nil else {
            return
        }

        let scheduledGeneration = generation
        let delayNanoseconds = reconciliationNanoseconds
        reconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: delayNanoseconds
                )
            } catch {
                return
            }
            guard let self,
                  self.isStarted,
                  scheduledGeneration == self.generation else {
                return
            }
            self.reconciliationTask = nil
            self.recordChange(generation: scheduledGeneration)
            // If the target temporarily rejects this refresh, keep the
            // watchdog alive. An accepted scan cancels this replacement task
            // synchronously when its scanning state is published.
            self.scheduleReconciliationIfNeeded()
        }
    }

    private func scheduleRefreshIfNeeded(
        delayNanoseconds: UInt64? = nil
    ) {
        guard isStarted,
              !folderURLs.isEmpty,
              dirtyRevision > coveredRevision,
              !wasScanning,
              target != nil,
              !hasPendingRefreshRequest,
              refreshTask == nil else {
            return
        }

        // Anchor the coalescing window to the first uncovered change. A
        // trailing debounce can be postponed forever by a busy watched root,
        // and would also defeat the reconciliation watchdog's upper bound.
        let scheduledGeneration = generation
        let scheduledRevision = dirtyRevision
        let refreshDelayNanoseconds = delayNanoseconds
            ?? debounceNanoseconds
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: refreshDelayNanoseconds
                )
            } catch {
                return
            }
            self?.requestRefresh(
                generation: scheduledGeneration,
                revision: scheduledRevision
            )
        }
    }

    private func requestRefresh(generation: UInt64, revision: UInt64) {
        guard isStarted,
              generation == self.generation,
              revision <= dirtyRevision,
              dirtyRevision > coveredRevision,
              !folderURLs.isEmpty,
              let target else {
            return
        }
        refreshTask = nil

        if target.automaticRefreshIsScanning {
            observeScanningStartIfNeeded()
            return
        }

        hasPendingRefreshRequest = true
        let accepted = target.requestAutomaticRefresh()
        if target.automaticRefreshIsScanning {
            observeScanningStartIfNeeded()
        } else if !accepted {
            hasPendingRefreshRequest = false
        }
    }

    private func advanceGeneration() {
        generation &+= 1
    }
}
