import Combine
import Foundation

enum DesktopScenePersistenceFailure: Equatable, Sendable {
    case loadFailed
    case saveFailed
}

@MainActor
final class DesktopSceneController: ObservableObject {
    @Published private(set) var committedScene: DesktopScene
    @Published private(set) var draft: DesktopScene?
    @Published private(set) var connectedDisplays:
        [DesktopDisplayDescriptor] = []
    @Published private(set) var selectedDisplayID: DesktopDisplayID?
    @Published private(set) var persistenceFailure:
        DesktopScenePersistenceFailure?

    var scene: DesktopScene {
        draft ?? committedScene
    }

    var isEditing: Bool {
        draft != nil
    }

    var enabledDisplayCount: Int {
        let connectedIDs = Set(connectedDisplays.map(\.id))
        return scene.assignments.lazy.filter {
            $0.isEnabled && connectedIDs.contains($0.displayID)
        }.count
    }

    var canApply: Bool {
        guard let draft,
              draft.isValid,
              enabledDisplayCount > 0 else {
            return false
        }
        return true
    }

    var selectedAssignment: DesktopDisplayAssignment? {
        guard let selectedDisplayID else {
            return nil
        }
        return scene.assignment(for: selectedDisplayID)
    }

    private let store: any DesktopSceneStoring
    private let topology: any DesktopDisplayTopologyProviding
    private var isLegacyUncustomizedScene: Bool

    init(
        store: any DesktopSceneStoring,
        topology: any DesktopDisplayTopologyProviding,
        legacyContentMode: DesktopVideoContentMode = .defaultValue
    ) {
        self.store = store
        self.topology = topology

        do {
            if let storedScene = try store.load(), storedScene.isValid {
                committedScene = Self.normalized(storedScene)
                isLegacyUncustomizedScene = false
                persistenceFailure = nil
            } else {
                committedScene = .legacy(contentMode: legacyContentMode)
                isLegacyUncustomizedScene = true
                persistenceFailure = nil
            }
        } catch {
            committedScene = .legacy(contentMode: legacyContentMode)
            isLegacyUncustomizedScene = true
            persistenceFailure = .loadFailed
        }

        topology.displaysDidChangeHandler = { [weak self] displays in
            self?.reconcileTopology(displays)
        }
        topology.startMonitoring()
        reconcileTopology(topology.currentDisplays())
    }

    func beginEditing() {
        guard draft == nil else {
            return
        }
        draft = committedScene
        chooseSelectionIfNeeded()
    }

    func cancelEditing() {
        guard draft != nil else {
            return
        }
        draft = nil
        chooseSelectionIfNeeded()
    }

    func select(_ displayID: DesktopDisplayID) {
        guard connectedDisplays.contains(where: { $0.id == displayID }) else {
            return
        }
        selectedDisplayID = displayID
    }

    func setMode(_ mode: DesktopSceneMode) {
        updateDraft { scene in
            scene.mode = mode
            switch mode {
            case .synchronized:
                scene.appliesToAllConnectedDisplays =
                    allConnectedDisplaysAreEnabled(in: scene)
            case .perDisplay:
                scene.appliesToAllConnectedDisplays = false
                let connectedIDs = Set(connectedDisplays.map(\.id))
                for index in scene.assignments.indices
                    where !connectedIDs.contains(
                        scene.assignments[index].displayID
                    )
                        && scene.assignments[index].mediaItemID == nil {
                    // Synchronized scenes do not need per-display media. An
                    // invisible assignment left enabled by "all displays"
                    // must not make the independent draft uncommittable.
                    scene.assignments[index].isEnabled = false
                }
            }
        }
    }

    func setEnabled(
        _ isEnabled: Bool,
        for displayID: DesktopDisplayID
    ) {
        updateAssignment(for: displayID) { assignment in
            assignment.isEnabled = isEnabled
        }
        updateDraft { scene in
            guard scene.mode == .synchronized else {
                scene.appliesToAllConnectedDisplays = false
                return
            }
            scene.appliesToAllConnectedDisplays =
                allConnectedDisplaysAreEnabled(in: scene)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        guard let selectedDisplayID else {
            return
        }
        setEnabled(isEnabled, for: selectedDisplayID)
    }

    func setContentMode(
        _ contentMode: DesktopVideoContentMode,
        for displayID: DesktopDisplayID
    ) {
        updateAssignment(for: displayID) { assignment in
            assignment.contentMode = contentMode
        }
    }

    func setContentMode(_ contentMode: DesktopVideoContentMode) {
        guard let selectedDisplayID else {
            return
        }
        setContentMode(contentMode, for: selectedDisplayID)
    }

    func setMediaItem(
        _ mediaItemID: LibraryMediaItem.ID?,
        for displayID: DesktopDisplayID
    ) {
        updateAssignment(for: displayID) { assignment in
            assignment.mediaItemID = mediaItemID
        }
    }

    func setMediaItem(_ mediaItemID: LibraryMediaItem.ID?) {
        guard let selectedDisplayID else {
            return
        }
        setMediaItem(mediaItemID, for: selectedDisplayID)
    }

    func setDefaultContentMode(
        _ contentMode: DesktopVideoContentMode
    ) {
        updateDraft { scene in
            scene.defaultContentMode = contentMode
            guard scene.mode == .synchronized else {
                return
            }
            let connectedIDs = Set(connectedDisplays.map(\.id))
            for index in scene.assignments.indices
                where scene.assignments[index].isEnabled
                    && connectedIDs.contains(
                        scene.assignments[index].displayID
                    ) {
                scene.assignments[index].contentMode = contentMode
            }
        }
    }

    @discardableResult
    func applySynchronizedToAll(
        contentMode: DesktopVideoContentMode? = nil
    ) -> Bool {
        var nextScene = mergingMissingAssignments(
            into: committedScene,
            for: connectedDisplays
        )
        nextScene.mode = .synchronized
        nextScene.appliesToAllConnectedDisplays = true
        if let contentMode {
            nextScene.defaultContentMode = contentMode
        }
        let connectedIDs = Set(connectedDisplays.map(\.id))
        for index in nextScene.assignments.indices {
            guard connectedIDs.contains(
                nextScene.assignments[index].displayID
            ) else {
                continue
            }
            nextScene.assignments[index].isEnabled = true
            if let contentMode {
                nextScene.assignments[index].contentMode = contentMode
            }
        }
        return commitImmediately(
            nextScene,
            marksCustomized: true
        )
    }

    func updateSynchronizedContentMode(
        _ contentMode: DesktopVideoContentMode
    ) {
        guard committedScene.mode == .synchronized else {
            return
        }
        var nextScene = committedScene
        nextScene.defaultContentMode = contentMode
        let connectedIDs = Set(connectedDisplays.map(\.id))
        for index in nextScene.assignments.indices
            where nextScene.assignments[index].isEnabled
                && connectedIDs.contains(
                    nextScene.assignments[index].displayID
                ) {
            nextScene.assignments[index].contentMode = contentMode
        }
        _ = commitImmediately(
            nextScene,
            marksCustomized: true
        )
    }

    func applyLegacyContentModeIfNeeded(
        _ contentMode: DesktopVideoContentMode
    ) {
        guard isLegacyUncustomizedScene,
              committedScene.mode == .synchronized,
              committedScene.appliesToAllConnectedDisplays else {
            return
        }
        var nextScene = committedScene
        nextScene.defaultContentMode = contentMode
        for index in nextScene.assignments.indices
            where nextScene.assignments[index].isEnabled {
            nextScene.assignments[index].contentMode = contentMode
        }
        committedScene = Self.normalized(nextScene)
        draft = nil
    }

    @discardableResult
    func commit() -> Bool {
        guard let draft, canApply else {
            return false
        }
        let normalizedDraft = Self.normalized(draft)
        do {
            try store.save(normalizedDraft)
        } catch {
            persistenceFailure = .saveFailed
            return false
        }

        committedScene = normalizedDraft
        self.draft = nil
        isLegacyUncustomizedScene = false
        persistenceFailure = nil
        chooseSelectionIfNeeded()
        return true
    }

    func reconcileTopology(_ descriptors: [DesktopDisplayDescriptor]) {
        connectedDisplays = Self.normalizedConnectedDisplays(descriptors)

        let previousCommitted = committedScene
        committedScene = mergingMissingAssignments(
            into: committedScene,
            for: connectedDisplays
        )
        if committedScene != previousCommitted,
           !isLegacyUncustomizedScene {
            persistReconciledScene()
        }

        if let currentDraft = draft {
            draft = mergingMissingAssignments(
                into: currentDraft,
                for: connectedDisplays
            )
        }
        chooseSelectionIfNeeded()
    }

    func identifyDisplays() {
        topology.identifyDisplays()
    }

    func shutdown() {
        topology.displaysDidChangeHandler = nil
        topology.stopMonitoring()
    }

    private func updateDraft(
        _ update: (inout DesktopScene) -> Void
    ) {
        guard var draft else {
            return
        }
        update(&draft)
        self.draft = Self.normalized(draft)
    }

    private func updateAssignment(
        for displayID: DesktopDisplayID,
        _ update: (inout DesktopDisplayAssignment) -> Void
    ) {
        guard connectedDisplays.contains(where: { $0.id == displayID }) else {
            return
        }
        updateDraft { scene in
            guard let index = scene.assignments.firstIndex(where: {
                $0.displayID == displayID
            }) else {
                return
            }
            update(&scene.assignments[index])
        }
    }

    private func allConnectedDisplaysAreEnabled(
        in scene: DesktopScene
    ) -> Bool {
        !connectedDisplays.isEmpty
            && connectedDisplays.allSatisfy { descriptor in
                scene.assignment(for: descriptor.id)?.isEnabled == true
            }
    }

    private func mergingMissingAssignments(
        into original: DesktopScene,
        for displays: [DesktopDisplayDescriptor]
    ) -> DesktopScene {
        var scene = original
        let shouldEnableNewDisplays = scene.mode == .synchronized
            && scene.appliesToAllConnectedDisplays

        for display in displays {
            if let index = scene.assignments.firstIndex(where: {
                $0.displayID == display.id
            }) {
                if shouldEnableNewDisplays {
                    scene.assignments[index].isEnabled = true
                }
                continue
            }
            guard scene.assignments.count
                    < DesktopScenePolicy.maximumAssignmentCount else {
                break
            }
            scene.assignments.append(
                DesktopDisplayAssignment(
                    displayID: display.id,
                    isEnabled: shouldEnableNewDisplays,
                    contentMode: scene.defaultContentMode
                )
            )
        }
        return Self.normalized(scene)
    }

    private func persistReconciledScene() {
        do {
            try store.save(committedScene)
            persistenceFailure = nil
        } catch {
            persistenceFailure = .saveFailed
        }
    }

    @discardableResult
    private func commitImmediately(
        _ scene: DesktopScene,
        marksCustomized: Bool
    ) -> Bool {
        let normalizedScene = Self.normalized(scene)
        guard normalizedScene.isValid,
              hasEnabledConnectedDisplay(in: normalizedScene) else {
            return false
        }
        do {
            try store.save(normalizedScene)
        } catch {
            persistenceFailure = .saveFailed
            return false
        }
        committedScene = normalizedScene
        draft = nil
        if marksCustomized {
            isLegacyUncustomizedScene = false
        }
        persistenceFailure = nil
        chooseSelectionIfNeeded()
        return true
    }

    private func hasEnabledConnectedDisplay(
        in scene: DesktopScene
    ) -> Bool {
        let connectedIDs = Set(connectedDisplays.map(\.id))
        return scene.assignments.contains {
            $0.isEnabled && connectedIDs.contains($0.displayID)
        }
    }

    private func chooseSelectionIfNeeded() {
        if let selectedDisplayID,
           connectedDisplays.contains(where: { $0.id == selectedDisplayID }) {
            return
        }
        selectedDisplayID = connectedDisplays.first(where: \.isMain)?.id
            ?? connectedDisplays.first?.id
    }

    private static func normalized(_ scene: DesktopScene) -> DesktopScene {
        var normalizedScene = scene
        if normalizedScene.mode == .perDisplay {
            normalizedScene.appliesToAllConnectedDisplays = false
        }
        normalizedScene.assignments.sort {
            $0.displayID < $1.displayID
        }
        return normalizedScene
    }

    private static func normalizedConnectedDisplays(
        _ displays: [DesktopDisplayDescriptor]
    ) -> [DesktopDisplayDescriptor] {
        var descriptorsByID: [
            DesktopDisplayID: DesktopDisplayDescriptor
        ] = [:]
        for display in displays where display.isConnected {
            descriptorsByID[display.id] = display
        }
        return descriptorsByID.values.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            if lhs.frame.minY != rhs.frame.minY {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.id < rhs.id
        }
    }
}
