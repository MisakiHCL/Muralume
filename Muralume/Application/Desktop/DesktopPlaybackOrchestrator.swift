import Combine

private enum DesktopPlaybackOrchestrationPolicy {
    static let initialReadinessTimeout: Duration = .seconds(8)
    static let readinessPollInterval: Duration = .milliseconds(10)
}

@MainActor
final class DesktopPlaybackOrchestrator: ObservableObject {
    typealias EngineFactory = @MainActor () -> any PlaybackEngine
    typealias SourceResolver = @MainActor (
        LibraryMediaItem.ID
    ) -> ResolvedMediaSource?

    @Published private(set) var displayStates: [
        DesktopDisplayID: DesktopLoopPlaybackState
    ] = [:]
    @Published private(set) var displayFailures: [
        DesktopDisplayID: PlaybackFailure
    ] = [:]

    var playbackStateDidChangeHandler: (() -> Void)?

    var activeDisplayIDs: Set<DesktopDisplayID> {
        Set(nodes.keys)
    }

    /// Includes nodes that have been detached but whose asynchronous load is
    /// still draining, so security-scope owners never close access too early.
    var activeMediaItemIDs: Set<LibraryMediaItem.ID> {
        Set(nodes.values.map(\.itemID))
            .union(pendingDrains.values.map(\.itemID))
    }

    var failedDisplayCount: Int {
        candidateDisplayIDs.reduce(into: 0) { count, displayID in
            if displayFailures[displayID] != nil {
                count += 1
            }
        }
    }

    /// A failure is terminal only after every currently connected candidate
    /// has finished loading and none can still render. A disconnected setup
    /// intentionally has no terminal failure so hot-plug recovery remains
    /// possible.
    var terminalFailure: PlaybackFailure? {
        let displayIDs = candidateDisplayIDs
        guard !displayIDs.isEmpty else {
            return nil
        }

        var failures: [PlaybackFailure] = []
        for displayID in displayIDs {
            switch displayStates[displayID] {
            case .playing, .paused:
                return nil
            case .loading, .idle, .terminating, nil:
                return nil
            case .failed(let failure):
                failures.append(failure)
            }
        }
        guard failures.count == displayIDs.count else {
            return nil
        }
        return Self.aggregateFailure(failures)
    }

    private struct ActiveNode {
        let itemID: LibraryMediaItem.ID
        let surfaceIdentity: ObjectIdentifier
        let node: DesktopLoopPlaybackNode
    }

    private struct PendingDrain {
        let itemID: LibraryMediaItem.ID
        let task: Task<Void, Never>
    }

    private enum InitialReadinessStatus {
        case ready
        case pending
        case failed(PlaybackFailure)
    }

    private let engineFactory: EngineFactory
    private let initialReadinessTimeout: Duration?
    private var sourceResolver: SourceResolver?
    private var assignmentsByDisplayID: [
        DesktopDisplayID: DesktopDisplayAssignment
    ] = [:]
    private var surfacesByDisplayID: [
        DesktopDisplayID: any PlaybackRenderSurface
    ] = [:]
    private var nodes: [DesktopDisplayID: ActiveNode] = [:]
    private var playbackIntent: PlaybackIntent = .playing
    private var rate = PlaybackPolicy.defaultRate
    private var suspensionReasons: Set<PlaybackSuspensionReason> = []
    private var displaySuspensionReasons: [
        DesktopDisplayID: Set<PlaybackSuspensionReason>
    ] = [:]
    private var suppressedMediaItemIDs: Set<LibraryMediaItem.ID> = []
    private var pendingDrains: [UInt64: PendingDrain] = [:]
    private var nextDrainID: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var isStarted = false
    private var isShutDown = false
    private var hasCompletedInitialStart = false

    init(
        initialReadinessTimeout: Duration? =
            DesktopPlaybackOrchestrationPolicy.initialReadinessTimeout,
        engineFactory: @escaping EngineFactory
    ) {
        self.initialReadinessTimeout = initialReadinessTimeout
        self.engineFactory = engineFactory
    }

    func start(
        assignments: [DesktopDisplayAssignment],
        surfaces: [DesktopDisplayID: any PlaybackRenderSurface],
        sourceResolver: @escaping SourceResolver
    ) async throws {
        guard !isShutDown else {
            throw PlaybackEngineError.superseded
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        self.sourceResolver = sourceResolver
        assignmentsByDisplayID = Self.index(assignments)
        surfacesByDisplayID = surfaces
        suppressedMediaItemIDs.removeAll()
        isStarted = true
        hasCompletedInitialStart = false
        reconcilePlaybackNodes()

        let candidateDisplayIDs: Set<DesktopDisplayID> = Set(
            assignments.compactMap { assignment in
            guard assignment.isEnabled,
                  assignment.mediaItemID != nil,
                  surfaces[assignment.displayID] != nil else {
                return nil
            }
            return assignment.displayID
        })
        guard !candidateDisplayIDs.isEmpty else {
            throw PlaybackEngineError.cannotOpen
        }
        try await waitForInitialReadiness(
            displayIDs: candidateDisplayIDs,
            generation: generation
        )
        hasCompletedInitialStart = true
    }

    func setAssignments(_ assignments: [DesktopDisplayAssignment]) {
        guard !isShutDown else {
            return
        }
        assignmentsByDisplayID = Self.index(assignments)
        guard isStarted else {
            return
        }
        reconcilePlaybackNodes()
    }

    func addSurface(
        _ surface: any PlaybackRenderSurface,
        for displayID: DesktopDisplayID
    ) {
        guard !isShutDown else {
            return
        }
        surfacesByDisplayID[displayID] = surface
        guard isStarted else {
            return
        }
        reconcilePlaybackNode(for: displayID)
    }

    func removeSurface(for displayID: DesktopDisplayID) {
        guard !isShutDown else {
            return
        }
        surfacesByDisplayID[displayID] = nil
        displaySuspensionReasons[displayID] = nil
        removeNode(for: displayID)
    }

    func refreshSources() {
        guard isStarted, !isShutDown else {
            return
        }
        reconcilePlaybackNodes()
    }

    func pauseAll() {
        setPlaybackIntent(.paused)
    }

    func resumeAll() {
        setPlaybackIntent(.playing)
    }

    func setPlaybackIntent(_ intent: PlaybackIntent) {
        guard !isShutDown, playbackIntent != intent else {
            return
        }
        playbackIntent = intent
        nodes.values.forEach {
            $0.node.setPlaybackIntent(intent)
        }
    }

    func setRate(_ rate: PlaybackRate) {
        guard !isShutDown, self.rate != rate else {
            return
        }
        self.rate = rate
        nodes.values.forEach {
            $0.node.setRate(rate)
        }
    }

    func setSuspended(
        _ suspended: Bool,
        for reason: PlaybackSuspensionReason
    ) {
        guard !isShutDown, reason.scope != .playerOnly else {
            return
        }
        let didChange: Bool
        if suspended {
            didChange = suspensionReasons.insert(reason).inserted
        } else {
            didChange = suspensionReasons.remove(reason) != nil
        }
        guard didChange else {
            return
        }
        nodes.values.forEach {
            $0.node.setSuspended(suspended, for: reason)
        }
    }

    func setSuspended(
        _ suspended: Bool,
        for reason: PlaybackSuspensionReason,
        displayID: DesktopDisplayID
    ) {
        guard !isShutDown, reason.scope != .playerOnly else {
            return
        }
        var reasons = displaySuspensionReasons[displayID] ?? []
        let didChange: Bool
        if suspended {
            didChange = reasons.insert(reason).inserted
        } else {
            didChange = reasons.remove(reason) != nil
        }
        guard didChange else {
            return
        }
        if reasons.isEmpty {
            displaySuspensionReasons[displayID] = nil
        } else {
            displaySuspensionReasons[displayID] = reasons
        }
        nodes[displayID]?.node.setSuspended(suspended, for: reason)
    }

    func stop() {
        guard !isShutDown else {
            return
        }
        lifecycleGeneration &+= 1
        isStarted = false
        hasCompletedInitialStart = false
        displaySuspensionReasons.removeAll()
        removeAllNodes()
    }

    func shutdown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        lifecycleGeneration &+= 1
        isStarted = false
        hasCompletedInitialStart = false
        removeAllNodes()
        assignmentsByDisplayID.removeAll()
        surfacesByDisplayID.removeAll()
        sourceResolver = nil
        suspensionReasons.removeAll()
        displaySuspensionReasons.removeAll()
        suppressedMediaItemIDs.removeAll()
        playbackStateDidChangeHandler = nil
    }

    /// Stops matching nodes immediately and then waits for their cancelled
    /// asset loads and surface attachments to fully unwind. Passing `nil`
    /// drains every node; a set preserves unrelated displays.
    func stopAndDrain(
        itemIDs: Set<LibraryMediaItem.ID>? = nil
    ) async {
        if let itemIDs {
            suppressedMediaItemIDs.formUnion(itemIDs)
            let displayIDs = nodes.compactMap { displayID, activeNode in
                itemIDs.contains(activeNode.itemID) ? displayID : nil
            }
            if !displayIDs.isEmpty {
                lifecycleGeneration &+= 1
            }
            for displayID in displayIDs {
                removeNode(for: displayID)
            }
        } else if !isShutDown {
            stop()
        }

        let drains = pendingDrains.values.filter { pendingDrain in
            itemIDs.map { $0.contains(pendingDrain.itemID) } ?? true
        }.map(\.task)
        for drain in drains {
            await drain.value
        }
    }

    private func reconcilePlaybackNodes() {
        let knownDisplayIDs = Set(assignmentsByDisplayID.keys)
            .union(surfacesByDisplayID.keys)
            .union(nodes.keys)
        for displayID in knownDisplayIDs.sorted() {
            reconcilePlaybackNode(for: displayID)
        }
    }

    private func reconcilePlaybackNode(for displayID: DesktopDisplayID) {
        guard isStarted,
              let assignment = assignmentsByDisplayID[displayID],
              assignment.isEnabled,
              let itemID = assignment.mediaItemID,
              !suppressedMediaItemIDs.contains(itemID),
              let surface = surfacesByDisplayID[displayID] else {
            removeNode(for: displayID)
            return
        }

        let surfaceIdentity = ObjectIdentifier(surface)
        if let activeNode = nodes[displayID],
           activeNode.itemID == itemID,
           activeNode.surfaceIdentity == surfaceIdentity {
            if case .failed = activeNode.node.state {
                // Explicit reconciliation is also the retry mechanism after
                // an offline or temporarily unreadable source returns.
            } else {
                return
            }
        }
        removeNode(for: displayID)

        guard let source = sourceResolver?(itemID) else {
            publish(.failed(.cannotOpen), for: displayID)
            return
        }

        let node = DesktopLoopPlaybackNode(
            engine: engineFactory(),
            initialRate: rate,
            initialIntent: playbackIntent
        )
        node.stateDidChangeHandler = { [weak self, weak node] state in
            guard let self,
                  let node,
                  nodes[displayID]?.node === node else {
                return
            }
            publish(state, for: displayID)
        }
        let initialSuspensionReasons = suspensionReasons.union(
            displaySuspensionReasons[displayID] ?? []
        )
        for reason in initialSuspensionReasons {
            node.setSuspended(true, for: reason)
        }
        nodes[displayID] = ActiveNode(
            itemID: itemID,
            surfaceIdentity: surfaceIdentity,
            node: node
        )
        publish(.loading, for: displayID)
        node.start(
            source: source,
            surface: surface,
            readinessPolicy: hasCompletedInitialStart
                ? .deferred
                : .required
        )
    }

    private func removeNode(for displayID: DesktopDisplayID) {
        guard let activeNode = nodes.removeValue(forKey: displayID) else {
            displayStates[displayID] = nil
            displayFailures[displayID] = nil
            playbackStateDidChangeHandler?()
            return
        }
        activeNode.node.stateDidChangeHandler = nil
        activeNode.node.shutdown()
        scheduleDrain(for: activeNode)
        displayStates[displayID] = nil
        displayFailures[displayID] = nil
        playbackStateDidChangeHandler?()
    }

    private func removeAllNodes() {
        let activeNodes = Array(nodes.values)
        nodes.removeAll()
        activeNodes.forEach { activeNode in
            activeNode.node.stateDidChangeHandler = nil
            activeNode.node.shutdown()
            scheduleDrain(for: activeNode)
        }
        displayStates.removeAll()
        displayFailures.removeAll()
        playbackStateDidChangeHandler?()
    }

    private func publish(
        _ state: DesktopLoopPlaybackState,
        for displayID: DesktopDisplayID
    ) {
        displayStates[displayID] = state
        if case let .failed(failure) = state {
            displayFailures[displayID] = failure
        } else {
            displayFailures[displayID] = nil
        }
        playbackStateDidChangeHandler?()
    }

    private var candidateDisplayIDs: Set<DesktopDisplayID> {
        Set(
            assignmentsByDisplayID.compactMap { displayID, assignment in
                guard assignment.isEnabled,
                      let mediaItemID = assignment.mediaItemID,
                      !suppressedMediaItemIDs.contains(mediaItemID),
                      surfacesByDisplayID[displayID] != nil else {
                    return nil
                }
                return displayID
            }
        )
    }

    private func waitForInitialReadiness(
        displayIDs: Set<DesktopDisplayID>,
        generation: UInt64
    ) async throws {
        let clock = ContinuousClock()
        let deadline = initialReadinessTimeout.map {
            clock.now.advanced(by: $0)
        }

        while true {
            try Task.checkCancellation()
            guard lifecycleGeneration == generation, isStarted else {
                throw PlaybackEngineError.superseded
            }

            switch initialReadinessStatus(for: displayIDs) {
            case .ready:
                return
            case .failed(let failure):
                throw Self.engineError(for: failure)
            case .pending:
                break
            }

            await Task.yield()
            if let deadline {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw PlaybackEngineError.surfaceTimeout
                }
                try await Task.sleep(
                    for: min(
                        remaining,
                        DesktopPlaybackOrchestrationPolicy
                            .readinessPollInterval
                    )
                )
            } else {
                try await Task.sleep(
                    for: DesktopPlaybackOrchestrationPolicy
                        .readinessPollInterval
                )
            }
        }
    }

    private func initialReadinessStatus(
        for displayIDs: Set<DesktopDisplayID>
    ) -> InitialReadinessStatus {
        var failures: [PlaybackFailure] = []
        var hasPendingDisplay = false
        for displayID in displayIDs {
            switch displayStates[displayID] {
            case .playing, .paused:
                return .ready
            case .loading:
                hasPendingDisplay = true
            case .failed(let failure):
                failures.append(failure)
            case .idle, .terminating, nil:
                failures.append(.cannotOpen)
            }
        }
        if hasPendingDisplay {
            return .pending
        }
        return .failed(Self.aggregateFailure(failures))
    }

    private func scheduleDrain(for activeNode: ActiveNode) {
        nextDrainID &+= 1
        let drainID = nextDrainID
        let node = activeNode.node
        let drainTask = Task { @MainActor [weak self, node] in
            await node.stopAndDrain()
            self?.pendingDrains[drainID] = nil
        }
        pendingDrains[drainID] = PendingDrain(
            itemID: activeNode.itemID,
            task: drainTask
        )
    }

    private static func aggregateFailure(
        _ failures: [PlaybackFailure]
    ) -> PlaybackFailure {
        if failures.contains(.surfaceTimeout) {
            return .surfaceTimeout
        }
        if !failures.isEmpty, failures.allSatisfy({ $0 == .unsupported }) {
            return .unsupported
        }
        return .cannotOpen
    }

    private static func engineError(
        for failure: PlaybackFailure
    ) -> PlaybackEngineError {
        switch failure {
        case .unsupported:
            .unsupported
        case .cannotOpen:
            .cannotOpen
        case .surfaceTimeout:
            .surfaceTimeout
        }
    }

    private static func index(
        _ assignments: [DesktopDisplayAssignment]
    ) -> [DesktopDisplayID: DesktopDisplayAssignment] {
        assignments.reduce(into: [:]) { result, assignment in
            result[assignment.displayID] = assignment
        }
    }
}
