import Combine
import Foundation

@MainActor
final class ExternalSubtitleController: ObservableObject {
    private struct Request {
        enum Work {
            case discover(preferredLanguages: [String])
            case parse(
                URL, origin: ExternalSubtitleOrigin,
                reportsFailure: Bool, persistsAssociation: Bool,
                discoversFallbackOnFailure: Bool
            )
        }

        let generation: UInt64
        let mediaURL: URL
        let work: Work
        let activate: () -> Void
    }

    private enum WorkResult: Sendable {
        case discovered(URL?)
        case parsed(SubtitleTimeline, SecurityScopedResourceLease)
        case failed(any Error)
    }

    @Published private(set) var track: ExternalSubtitleTrack?
    @Published private(set) var cueText: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: ExternalSubtitleLoadFailure?

    private let engine: any PlaybackEngine
    private let parser: (any SubtitleFileParsing)?
    private let discovery: (any ExternalSubtitleDiscovering)?
    private let associationStore:
        (any ExternalSubtitleAssociationStoring)?
    private var cursor: SubtitleTimelineCursor?
    private var isTimeDeliverySuspended = false
    // Cancellation does not imply that a synchronous file operation exited.
    // Keep its slot until it really returns; only the latest request waits.
    private var worker: Task<Void, Never>?
    private var activeWork: Task<WorkResult, Never>?
    private var pendingRequest: Request?
    private var loadGeneration: UInt64 = 0
    private var activeSecurityScope: SecurityScopedResourceLease?
    private var currentMediaURL: URL?

    init(
        engine: any PlaybackEngine,
        parser: (any SubtitleFileParsing)? = nil,
        discovery: (any ExternalSubtitleDiscovering)? = nil,
        associationStore:
            (any ExternalSubtitleAssociationStoring)? = nil
    ) {
        self.engine = engine
        self.parser = parser
        self.discovery = discovery
        self.associationStore = associationStore
    }

    deinit {
        worker?.cancel()
        activeWork?.cancel()
    }

    func prepare(
        for mediaURL: URL,
        activate: @escaping () -> Void
    ) {
        reset()
        currentMediaURL = mediaURL
        guard parser != nil else {
            return
        }

        let rememberedURL = associationStore?.subtitleURL(for: mediaURL)
        if let rememberedURL {
            startLoad(
                rememberedURL,
                origin: .remembered,
                for: mediaURL,
                reportsFailure: false,
                persistsAssociation: false,
                discoversFallbackOnFailure: true,
                activate: activate
            )
        } else {
            startDiscovery(for: mediaURL, activate: activate)
        }
    }

    func loadUserSelected(
        _ subtitleURL: URL,
        for mediaURL: URL,
        activate: @escaping () -> Void
    ) {
        guard currentMediaURL?.standardizedFileURL
                == mediaURL.standardizedFileURL else {
            return
        }
        startLoad(
            subtitleURL,
            origin: .userSelected,
            for: mediaURL,
            reportsFailure: true,
            persistsAssociation: true,
            discoversFallbackOnFailure: false,
            activate: activate
        )
    }

    func clear(removeRememberedAssociation: Bool) {
        loadGeneration &+= 1
        pendingRequest = nil
        activeWork?.cancel()
        engine.setExternalSubtitleTimeHandler(nil)
        cursor = nil
        track = nil
        cueText = nil
        isLoading = false
        failure = nil
        activeSecurityScope = nil
        if removeRememberedAssociation, let currentMediaURL {
            associationStore?.removeSubtitleURL(for: currentMediaURL)
        }
    }

    func reset() {
        clear(removeRememberedAssociation: false)
        currentMediaURL = nil
        isTimeDeliverySuspended = false
    }

    private func startDiscovery(
        for mediaURL: URL,
        activate: @escaping () -> Void
    ) {
        guard discovery != nil else {
            return
        }
        loadGeneration &+= 1
        enqueue(Request(
            generation: loadGeneration,
            mediaURL: mediaURL,
            work: .discover(preferredLanguages: Locale.preferredLanguages),
            activate: activate
        ))
    }

    private func startLoad(
        _ subtitleURL: URL,
        origin: ExternalSubtitleOrigin,
        for mediaURL: URL,
        reportsFailure: Bool,
        persistsAssociation: Bool,
        discoversFallbackOnFailure: Bool,
        activate: @escaping () -> Void
    ) {
        guard parser != nil else {
            return
        }
        loadGeneration &+= 1
        enqueue(Request(
            generation: loadGeneration,
            mediaURL: mediaURL,
            work: .parse(
                subtitleURL, origin: origin,
                reportsFailure: reportsFailure,
                persistsAssociation: persistsAssociation,
                discoversFallbackOnFailure: discoversFallbackOnFailure
            ),
            activate: activate
        ))
    }

    private func enqueue(_ request: Request) {
        activeWork?.cancel()
        pendingRequest = request
        isLoading = true
        failure = nil
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled,
                  let request = self?.takePendingRequest(),
                  let task = self?.beginWork(for: request) {
                let result = await task.value
                self?.finishWork(
                    result, for: request, wasCancelled: task.isCancelled
                )
            }
            self?.worker = nil
        }
    }

    private func takePendingRequest() -> Request? {
        defer { pendingRequest = nil }
        return pendingRequest
    }

    private func beginWork(for request: Request) -> Task<WorkResult, Never> {
        let task: Task<WorkResult, Never>
        switch request.work {
        case let .discover(preferredLanguages):
            let discovery = discovery
            let mediaURL = request.mediaURL
            task = Task.detached(priority: .utility) {
                // The actual operation owns access even after the controller
                // clears or replaces the request while a file read is blocked.
                let lease = SecurityScopedResourceLease(url: mediaURL)
                return withExtendedLifetime(lease) {
                    guard !Task.isCancelled else { return .discovered(nil) }
                    return .discovered(discovery?.discover(
                        for: mediaURL,
                        preferredLanguageCodes: preferredLanguages
                    ))
                }
            }
        case let .parse(subtitleURL, _, _, _, _):
            let parser = parser
            task = Task.detached(priority: .utility) {
                let lease = SecurityScopedResourceLease(url: subtitleURL)
                do {
                    try Task.checkCancellation()
                    guard let parser else {
                        throw ExternalSubtitleLoadFailure.cannotRead
                    }
                    let timeline = try parser.parse(subtitleURL)
                    try Task.checkCancellation()
                    return .parsed(timeline, lease)
                } catch {
                    return .failed(error)
                }
            }
        }
        activeWork = task
        return task
    }

    private func finishWork(
        _ result: WorkResult, for request: Request, wasCancelled: Bool
    ) {
        activeWork = nil
        guard !wasCancelled,
              request.generation == loadGeneration,
              currentMediaURL?.standardizedFileURL
                == request.mediaURL.standardizedFileURL else { return }
        isLoading = false
        switch (request.work, result) {
        case let (.discover, .discovered(subtitleURL)):
            if let subtitleURL {
                startLoad(
                    subtitleURL, origin: .discovered, for: request.mediaURL,
                    reportsFailure: false, persistsAssociation: false,
                    discoversFallbackOnFailure: false, activate: request.activate
                )
            }
        case let (
            .parse(subtitleURL, origin, _, persistsAssociation, _),
            .parsed(timeline, lease)
        ):
            activeSecurityScope = lease
            cursor = SubtitleTimelineCursor(timeline: timeline)
            track = ExternalSubtitleTrack(
                url: subtitleURL,
                displayName: subtitleURL.lastPathComponent,
                origin: origin
            )
            cueText = nil
            failure = nil
            if persistsAssociation {
                associationStore?.save(
                    subtitleURL: subtitleURL, for: request.mediaURL
                )
            }
            request.activate()
            installTimeHandler()
        case let (
            .parse(_, origin, reportsFailure, _, discoversFallbackOnFailure),
            .failed(error)
        ):
            guard !(error is CancellationError) else { return }
            if origin == .remembered {
                associationStore?.removeSubtitleURL(for: request.mediaURL)
            }
            if reportsFailure { failure = mapFailure(error) }
            if discoversFallbackOnFailure {
                startDiscovery(for: request.mediaURL, activate: request.activate)
            }
        default:
            break
        }
    }

    func setTimeDeliverySuspended(_ suspended: Bool) {
        guard isTimeDeliverySuspended != suspended else { return }
        isTimeDeliverySuspended = suspended
        if suspended {
            engine.setExternalSubtitleTimeHandler(nil)
        } else if track != nil {
            installTimeHandler()
        }
    }

    private func installTimeHandler() {
        guard !isTimeDeliverySuspended else { return }
        engine.setExternalSubtitleTimeHandler { [weak self] time in
            guard let self else {
                return
            }
            let nextCueText = cursor?.text(at: time)
            if cueText != nextCueText {
                cueText = nextCueText
            }
        }
    }

    private func mapFailure(_ error: any Error) -> ExternalSubtitleLoadFailure {
        if let failure = error as? ExternalSubtitleLoadFailure {
            return failure
        }
        return .cannotRead
    }
}

private final class SecurityScopedResourceLease: @unchecked Sendable {
    private let url: URL
    private let isAccessing: Bool

    init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
