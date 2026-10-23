import Foundation

/// Owns at most one parser plus the latest pending selection. Timelines belong
/// to this playback session, are never shared across users/files, and are
/// released on selection change, stop or load. The parser has a 4 MiB budget.
@MainActor
final class EmbeddedSubtitlePlaybackController {
    private struct Request {
        let id: PlaybackMediaOptionID
        let mediaGeneration: UInt64
        let sourceURL: URL
        let language: String
        let selectableLanguages: [String]
    }

    private let parser: any EmbeddedSubtitleParsing
    private let timelineHandler: (SubtitleTimeline?) -> Void
    private var requestedID: PlaybackMediaOptionID?
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var parsing: Task<EmbeddedSubtitlePreparation, Error>?
    private var validation: (mediaGeneration: UInt64, isEligible: Bool)?
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        parser: any EmbeddedSubtitleParsing,
        timelineHandler: @escaping (SubtitleTimeline?) -> Void
    ) {
        self.parser = parser
        self.timelineHandler = timelineHandler
    }

    func request(
        id: PlaybackMediaOptionID, sourceURL: URL, language: String,
        selectableLanguages: [String], mediaGeneration: UInt64 = 0
    ) {
        guard requestedID != id else { return }
        requestedID = id
        parsing?.cancel()
        pending = Request(
            id: id, mediaGeneration: mediaGeneration, sourceURL: sourceURL, language: language,
            selectableLanguages: selectableLanguages
        )
        timelineHandler(nil)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await runPendingRequests()
            worker = nil
            let waiters = drainWaiters.values
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func cancel(invalidateValidation: Bool = false) {
        if invalidateValidation { validation = nil }
        requestedID = nil
        pending = nil
        parsing?.cancel()
        timelineHandler(nil)
    }

    /// Cancellation actively interrupts AVFoundation reads. A stalled device
    /// cannot block shutdown forever; the worker owns its own security scope
    /// and compatibility alias until its actual read has finished.
    func drain(timeout: Duration = .seconds(2)) async {
        guard worker != nil else { return }
        await withCheckedContinuation { continuation in
            let id = UUID()
            drainWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.drainWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func runPendingRequests() async {
        while let request = pending {
            pending = nil
            let parser = parser
            let knownEligibility = validation.flatMap {
                $0.mediaGeneration == request.mediaGeneration ? $0.isEligible : nil
            }
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let access = request.sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if access { request.sourceURL.stopAccessingSecurityScopedResource() }
                }
                let lease = try MediaPlaybackURLLease(sourceURL: request.sourceURL)
                defer { lease.invalidate() }
                guard let knownEligibility else {
                    return try await parser.prepare(
                        lease.url, languageIdentifier: request.language,
                        selectableLanguages: request.selectableLanguages
                    )
                }
                guard knownEligibility else {
                    return EmbeddedSubtitlePreparation(isEligible: false, timeline: nil)
                }
                let timeline = try await parser.parse(
                    lease.url, languageIdentifier: request.language,
                    selectableLanguages: request.selectableLanguages
                )
                return EmbeddedSubtitlePreparation(isEligible: true, timeline: timeline)
            }
            parsing = task
            let result: EmbeddedSubtitlePreparation?
            do { result = try await task.value }
            catch is CancellationError { result = nil }
            catch { result = EmbeddedSubtitlePreparation(isEligible: false, timeline: nil) }
            parsing = nil
            guard !task.isCancelled, let result else { continue }
            validation = (request.mediaGeneration, result.isEligible)
            if requestedID == request.id { timelineHandler(result.timeline) }
        }
    }
}
