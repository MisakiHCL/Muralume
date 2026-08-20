import Combine
import Foundation

@MainActor
final class ExternalSubtitleController: ObservableObject {
    @Published private(set) var track: ExternalSubtitleTrack?
    @Published private(set) var cueText: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: ExternalSubtitleLoadFailure?

    private let engine: any PlaybackEngine
    private let parser: (any SubtitleFileParsing)?
    private let discovery: (any ExternalSubtitleDiscovering)?
    private let associationStore:
        (any ExternalSubtitleAssociationStoring)?
    private var timeline: SubtitleTimeline?
    private var loadTask: Task<Void, Never>?
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
        loadTask?.cancel()
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
        loadTask?.cancel()
        loadTask = nil
        engine.setExternalSubtitleTimeHandler(nil)
        timeline = nil
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
    }

    private func startDiscovery(
        for mediaURL: URL,
        activate: @escaping () -> Void
    ) {
        guard let discovery else {
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        isLoading = true
        failure = nil
        let preferredLanguages = Locale.preferredLanguages
        let discoveryTask = Task.detached(priority: .utility) {
            discovery.discover(
                for: mediaURL,
                preferredLanguageCodes: preferredLanguages
            )
        }
        loadTask = Task { [weak self] in
            let discoveredURL = await withTaskCancellationHandler {
                await discoveryTask.value
            } onCancel: {
                discoveryTask.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  generation == loadGeneration,
                  let discoveredURL else {
                if let self,
                   generation == loadGeneration {
                    isLoading = false
                    loadTask = nil
                }
                return
            }
            startLoad(
                discoveredURL,
                origin: .discovered,
                for: mediaURL,
                reportsFailure: false,
                persistsAssociation: false,
                discoversFallbackOnFailure: false,
                activate: activate
            )
        }
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
        guard let parser else {
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        isLoading = true
        failure = nil

        let lease = SecurityScopedResourceLease(url: subtitleURL)
        let parserTask = Task.detached(priority: .utility) {
            try parser.parse(subtitleURL)
        }
        loadTask = Task { [weak self] in
            do {
                let parsedTimeline = try await withTaskCancellationHandler {
                    try await parserTask.value
                } onCancel: {
                    parserTask.cancel()
                }
                guard let self,
                      !Task.isCancelled,
                      generation == loadGeneration,
                      currentMediaURL?.standardizedFileURL
                        == mediaURL.standardizedFileURL else {
                    return
                }

                activeSecurityScope = lease
                timeline = parsedTimeline
                track = ExternalSubtitleTrack(
                    url: subtitleURL,
                    displayName: subtitleURL.lastPathComponent,
                    origin: origin
                )
                cueText = nil
                isLoading = false
                failure = nil
                if persistsAssociation {
                    associationStore?.save(
                        subtitleURL: subtitleURL,
                        for: mediaURL
                    )
                }
                activate()
                installTimeHandler()
                loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == loadGeneration else {
                    return
                }
                isLoading = false
                loadTask = nil
                if origin == .remembered {
                    associationStore?.removeSubtitleURL(for: mediaURL)
                }
                if reportsFailure {
                    failure = mapFailure(error)
                }
                if discoversFallbackOnFailure {
                    startDiscovery(for: mediaURL, activate: activate)
                }
            }
        }
    }

    private func installTimeHandler() {
        engine.setExternalSubtitleTimeHandler { [weak self] time in
            guard let self else {
                return
            }
            let nextCueText = timeline?.text(at: time)
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

@MainActor
private final class SecurityScopedResourceLease {
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
