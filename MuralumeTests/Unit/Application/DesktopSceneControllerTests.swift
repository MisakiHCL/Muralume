import XCTest
@testable import Muralume

@MainActor
final class DesktopSceneControllerTests: XCTestCase {
    func testMissingSceneMigratesToSynchronizedAllConnectedDisplays() {
        let topology = TestDesktopDisplayTopology(
            displays: [
                makeDisplay(id: "main", runtimeID: 1, isMain: true),
                makeDisplay(id: "external", runtimeID: 2)
            ]
        )
        let store = TestDesktopSceneStore()
        let controller = DesktopSceneController(
            store: store,
            topology: topology,
            legacyContentMode: .contain
        )
        defer { controller.shutdown() }

        XCTAssertEqual(controller.committedScene.mode, .synchronized)
        XCTAssertTrue(
            controller.committedScene.appliesToAllConnectedDisplays
        )
        XCTAssertEqual(
            controller.committedScene.defaultContentMode,
            .contain
        )
        XCTAssertEqual(controller.enabledDisplayCount, 2)
        XCTAssertTrue(store.savedScenes.isEmpty)
        XCTAssertEqual(
            controller.selectedDisplayID,
            DesktopDisplayID(rawValue: "main")
        )
    }

    func testSyncAllAutomaticallyEnablesNewDisplay() {
        let first = makeDisplay(id: "first", runtimeID: 1, isMain: true)
        let second = makeDisplay(id: "second", runtimeID: 2)
        let topology = TestDesktopDisplayTopology(displays: [first])
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(),
            topology: topology
        )
        defer { controller.shutdown() }

        topology.emit([first, second])

        XCTAssertEqual(controller.enabledDisplayCount, 2)
        XCTAssertTrue(
            controller.committedScene.assignment(for: second.id)?.isEnabled
                == true
        )
    }

    func testConfiguredSynchronizedSceneLeavesNewDisplayDisabled() {
        let first = makeDisplay(id: "first", runtimeID: 1, isMain: true)
        let second = makeDisplay(id: "second", runtimeID: 2)
        let third = makeDisplay(id: "third", runtimeID: 3)
        let topology = TestDesktopDisplayTopology(
            displays: [first, second]
        )
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(),
            topology: topology
        )
        defer { controller.shutdown() }

        controller.beginEditing()
        controller.setEnabled(false, for: second.id)
        XCTAssertTrue(controller.commit())
        XCTAssertFalse(
            controller.committedScene.appliesToAllConnectedDisplays
        )

        topology.emit([first, second, third])

        XCTAssertFalse(
            controller.committedScene.assignment(for: third.id)?.isEnabled
                == true
        )
        XCTAssertEqual(controller.enabledDisplayCount, 1)
    }

    func testPerDisplaySceneRequiresMediaForEveryEnabledDisplay() {
        let first = makeDisplay(id: "first", runtimeID: 1, isMain: true)
        let second = makeDisplay(id: "second", runtimeID: 2)
        let topology = TestDesktopDisplayTopology(
            displays: [first, second]
        )
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(),
            topology: topology
        )
        defer { controller.shutdown() }

        controller.beginEditing()
        controller.setMode(.perDisplay)
        XCTAssertFalse(controller.canApply)

        controller.setMediaItem(makeMediaID("first.mp4"), for: first.id)
        XCTAssertFalse(controller.canApply)

        controller.setMediaItem(makeMediaID("second.mp4"), for: second.id)
        XCTAssertTrue(controller.canApply)
        XCTAssertTrue(controller.commit())
        XCTAssertEqual(controller.committedScene.mode, .perDisplay)
        XCTAssertFalse(
            controller.committedScene.appliesToAllConnectedDisplays
        )
    }

    func testPerDisplayModeDisablesDisconnectedAssignmentWithoutMedia() {
        let connected = makeDisplay(
            id: "connected",
            runtimeID: 1,
            isMain: true
        )
        let disconnectedID = DesktopDisplayID(rawValue: "disconnected")
        let storedScene = DesktopScene(
            mode: .synchronized,
            appliesToAllConnectedDisplays: true,
            defaultContentMode: .cover,
            assignments: [
                DesktopDisplayAssignment(
                    displayID: connected.id,
                    isEnabled: true,
                    contentMode: .cover
                ),
                DesktopDisplayAssignment(
                    displayID: disconnectedID,
                    isEnabled: true,
                    contentMode: .cover
                )
            ]
        )
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(scene: storedScene),
            topology: TestDesktopDisplayTopology(displays: [connected])
        )
        defer { controller.shutdown() }

        controller.beginEditing()
        controller.setMode(.perDisplay)

        XCTAssertTrue(
            controller.scene.assignment(for: connected.id)?.isEnabled
                == true
        )
        XCTAssertFalse(
            controller.scene.assignment(for: disconnectedID)?.isEnabled
                == true
        )
    }

    func testReconnectWithNewRuntimeIDPreservesAssignment() {
        let original = makeDisplay(
            id: "stable-display",
            runtimeID: 10,
            isMain: true
        )
        let topology = TestDesktopDisplayTopology(displays: [original])
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(),
            topology: topology
        )
        defer { controller.shutdown() }

        let mediaID = makeMediaID("assigned.mp4")
        controller.beginEditing()
        controller.setMode(.perDisplay)
        controller.setMediaItem(mediaID, for: original.id)
        XCTAssertTrue(controller.commit())

        topology.emit([])
        XCTAssertEqual(controller.committedScene.assignments.count, 1)

        let reconnected = makeDisplay(
            id: "stable-display",
            runtimeID: 99,
            isMain: true
        )
        topology.emit([reconnected])

        XCTAssertEqual(
            controller.committedScene.assignment(for: reconnected.id)?
                .mediaItemID,
            mediaID
        )
        XCTAssertEqual(
            controller.connectedDisplays.first?.runtimeID.rawValue,
            99
        )
    }

    func testCancelEditingDiscardsDraftChanges() {
        let display = makeDisplay(id: "main", runtimeID: 1, isMain: true)
        let controller = DesktopSceneController(
            store: TestDesktopSceneStore(),
            topology: TestDesktopDisplayTopology(displays: [display])
        )
        defer { controller.shutdown() }
        let committed = controller.committedScene

        controller.beginEditing()
        controller.setEnabled(false, for: display.id)
        controller.cancelEditing()

        XCTAssertNil(controller.draft)
        XCTAssertEqual(controller.committedScene, committed)
    }

    func testApplySynchronizedToAllCommitsAndPreservesMediaAssignments() {
        let first = makeDisplay(id: "first", runtimeID: 1, isMain: true)
        let second = makeDisplay(id: "second", runtimeID: 2)
        let firstMedia = makeMediaID("first.mp4")
        let secondMedia = makeMediaID("second.mp4")
        let storedScene = DesktopScene(
            mode: .perDisplay,
            appliesToAllConnectedDisplays: false,
            defaultContentMode: .contain,
            assignments: [
                DesktopDisplayAssignment(
                    displayID: first.id,
                    isEnabled: true,
                    contentMode: .contain,
                    mediaItemID: firstMedia
                ),
                DesktopDisplayAssignment(
                    displayID: second.id,
                    isEnabled: false,
                    contentMode: .cover,
                    mediaItemID: secondMedia
                )
            ]
        )
        let store = TestDesktopSceneStore(scene: storedScene)
        let controller = DesktopSceneController(
            store: store,
            topology: TestDesktopDisplayTopology(
                displays: [first, second]
            )
        )
        defer { controller.shutdown() }

        XCTAssertTrue(
            controller.applySynchronizedToAll(contentMode: .cover)
        )

        XCTAssertEqual(controller.committedScene.mode, .synchronized)
        XCTAssertTrue(
            controller.committedScene.appliesToAllConnectedDisplays
        )
        XCTAssertEqual(controller.enabledDisplayCount, 2)
        XCTAssertEqual(
            controller.committedScene.assignment(for: first.id)?.mediaItemID,
            firstMedia
        )
        XCTAssertEqual(
            controller.committedScene.assignment(for: second.id)?.mediaItemID,
            secondMedia
        )
        XCTAssertTrue(
            controller.committedScene.assignments.allSatisfy {
                $0.contentMode == .cover
            }
        )
        XCTAssertEqual(store.savedScenes.last, controller.committedScene)
    }

    func testLegacyContentModeDoesNotOverrideCustomizedScene() {
        let display = makeDisplay(id: "main", runtimeID: 1, isMain: true)
        let store = TestDesktopSceneStore()
        let controller = DesktopSceneController(
            store: store,
            topology: TestDesktopDisplayTopology(displays: [display]),
            legacyContentMode: .contain
        )
        defer { controller.shutdown() }

        controller.applyLegacyContentModeIfNeeded(.cover)
        XCTAssertEqual(
            controller.committedScene.defaultContentMode,
            .cover
        )
        XCTAssertTrue(store.savedScenes.isEmpty)

        XCTAssertTrue(
            controller.applySynchronizedToAll(contentMode: .contain)
        )
        controller.applyLegacyContentModeIfNeeded(.blurredBackground)

        XCTAssertEqual(
            controller.committedScene.defaultContentMode,
            .contain
        )
    }

    private func makeDisplay(
        id: String,
        runtimeID: UInt32,
        isMain: Bool = false
    ) -> DesktopDisplayDescriptor {
        DesktopDisplayDescriptor(
            id: DesktopDisplayID(rawValue: id),
            runtimeID: DesktopRuntimeDisplayID(rawValue: runtimeID),
            localizedName: id,
            frame: CGRect(
                x: CGFloat(runtimeID) * 100,
                y: 0,
                width: 100,
                height: 100
            ),
            isMain: isMain,
            isBuiltIn: isMain
        )
    }

    private func makeMediaID(_ relativePath: String) -> LibraryMediaItem.ID {
        LibraryMediaItem.ID(
            rootPath: "/tmp/DesktopSceneTests",
            relativePath: relativePath
        )
    }
}

@MainActor
final class DesktopSceneStoreTests: XCTestCase {
    private enum TestStorage {
        static let suiteName = "com.muralume.tests.desktop-scene"
    }

    func testStoreRoundTripsAndClearsScene() throws {
        try withStore { store, _ in
            let scene = makeValidPerDisplayScene()

            try store.save(scene)
            XCTAssertEqual(try store.load(), scene)

            try store.clear()
            XCTAssertNil(try store.load())
        }
    }

    func testStoreRejectsInvalidSceneWithoutReplacingLastKnownGood()
        throws {
        try withStore { store, defaults in
            let validScene = makeValidPerDisplayScene()
            try store.save(validScene)
            let lastKnownGood = try XCTUnwrap(
                defaults.data(forKey: DesktopSceneStorageKey.scene)
            )

            let duplicateID = DesktopDisplayID(rawValue: "duplicate")
            let invalidScene = DesktopScene(
                mode: .synchronized,
                appliesToAllConnectedDisplays: false,
                defaultContentMode: .cover,
                assignments: [
                    DesktopDisplayAssignment(
                        displayID: duplicateID,
                        isEnabled: true,
                        contentMode: .cover
                    ),
                    DesktopDisplayAssignment(
                        displayID: duplicateID,
                        isEnabled: false,
                        contentMode: .contain
                    )
                ]
            )

            XCTAssertThrowsError(try store.save(invalidScene)) { error in
                XCTAssertEqual(
                    error as? DesktopSceneStoreError,
                    .invalidScene
                )
            }
            XCTAssertEqual(
                defaults.data(forKey: DesktopSceneStorageKey.scene),
                lastKnownGood
            )
        }
    }

    func testStoreRejectsOversizedData() throws {
        try withDefaults { defaults in
            let store = UserDefaultsDesktopSceneStore(
                userDefaults: defaults,
                maximumEncodedByteCount: 32
            )

            XCTAssertThrowsError(
                try store.save(.legacy(contentMode: .cover))
            ) { error in
                guard let sceneError = error as? DesktopSceneStoreError,
                      case let .dataTooLarge(maximum, observed) =
                        sceneError else {
                    return XCTFail("Expected dataTooLarge, received \(error)")
                }
                XCTAssertEqual(maximum, 32)
                XCTAssertGreaterThan(observed, maximum)
            }
            XCTAssertNil(defaults.data(forKey: DesktopSceneStorageKey.scene))
        }
    }

    func testStoreRejectsCorruptPersistedData() throws {
        try withStore { store, defaults in
            defaults.set(
                Data("not-json".utf8),
                forKey: DesktopSceneStorageKey.scene
            )

            XCTAssertThrowsError(try store.load())
        }
    }

    private func makeValidPerDisplayScene() -> DesktopScene {
        DesktopScene(
            mode: .perDisplay,
            appliesToAllConnectedDisplays: false,
            defaultContentMode: .blurredBackground,
            assignments: [
                DesktopDisplayAssignment(
                    displayID: DesktopDisplayID(rawValue: "display"),
                    isEnabled: true,
                    contentMode: .contain,
                    mediaItemID: LibraryMediaItem.ID(
                        rootPath: "/tmp/DesktopSceneStoreTests",
                        relativePath: "video.mp4"
                    )
                )
            ]
        )
    }

    private func withStore(
        _ test: (
            UserDefaultsDesktopSceneStore,
            UserDefaults
        ) throws -> Void
    ) throws {
        try withDefaults { defaults in
            try test(
                UserDefaultsDesktopSceneStore(userDefaults: defaults),
                defaults
            )
        }
    }

    private func withDefaults(
        _ test: (UserDefaults) throws -> Void
    ) throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: TestStorage.suiteName)
        )
        defaults.removePersistentDomain(forName: TestStorage.suiteName)
        defer {
            defaults.removePersistentDomain(forName: TestStorage.suiteName)
        }
        try test(defaults)
    }
}

@MainActor
private final class TestDesktopSceneStore: DesktopSceneStoring {
    var storedScene: DesktopScene?
    var shouldFailSave = false
    private(set) var savedScenes: [DesktopScene] = []

    init(scene: DesktopScene? = nil) {
        storedScene = scene
    }

    func load() throws -> DesktopScene? {
        storedScene
    }

    func save(_ scene: DesktopScene) throws {
        if shouldFailSave {
            throw TestDesktopSceneStoreError.saveFailed
        }
        storedScene = scene
        savedScenes.append(scene)
    }

    func clear() throws {
        storedScene = nil
    }
}

private enum TestDesktopSceneStoreError: Error {
    case saveFailed
}

@MainActor
private final class TestDesktopDisplayTopology:
    DesktopDisplayTopologyProviding {
    var displaysDidChangeHandler:
        (([DesktopDisplayDescriptor]) -> Void)?
    private var displays: [DesktopDisplayDescriptor]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var identifyCount = 0

    init(displays: [DesktopDisplayDescriptor]) {
        self.displays = displays
    }

    func currentDisplays() -> [DesktopDisplayDescriptor] {
        displays
    }

    func startMonitoring() {
        startCount += 1
    }

    func stopMonitoring() {
        stopCount += 1
    }

    func identifyDisplays() {
        identifyCount += 1
    }

    func emit(_ displays: [DesktopDisplayDescriptor]) {
        self.displays = displays
        displaysDidChangeHandler?(displays)
    }
}
