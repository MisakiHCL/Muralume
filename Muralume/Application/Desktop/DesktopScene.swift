import Foundation

enum DesktopScenePolicy {
    static let maximumAssignmentCount = 64
    static let maximumDisplayIDByteCount = 512
    static let maximumEncodedByteCount = 256 * 1_024
}

enum DesktopSceneMode: String, Codable, CaseIterable, Equatable, Sendable {
    case synchronized
    case perDisplay
}

struct DesktopDisplayID:
    RawRepresentable,
    Codable,
    Hashable,
    Comparable,
    Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isValid: Bool {
        !rawValue.isEmpty
            && rawValue.utf8.count
                <= DesktopScenePolicy.maximumDisplayIDByteCount
    }
}

struct DesktopRuntimeDisplayID:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DesktopDisplayDescriptor: Equatable, Sendable, Identifiable {
    let id: DesktopDisplayID
    let runtimeID: DesktopRuntimeDisplayID
    let localizedName: String
    let frame: CGRect
    let isMain: Bool
    let isBuiltIn: Bool
    let isConnected: Bool

    init(
        id: DesktopDisplayID,
        runtimeID: DesktopRuntimeDisplayID,
        localizedName: String,
        frame: CGRect,
        isMain: Bool,
        isBuiltIn: Bool,
        isConnected: Bool = true
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.localizedName = localizedName
        self.frame = frame
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.isConnected = isConnected
    }
}

struct DesktopDisplayAssignment:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    Identifiable {
    var displayID: DesktopDisplayID
    var isEnabled: Bool
    var contentMode: DesktopVideoContentMode
    var mediaItemID: LibraryMediaItem.ID?

    var id: DesktopDisplayID {
        displayID
    }

    init(
        displayID: DesktopDisplayID,
        isEnabled: Bool,
        contentMode: DesktopVideoContentMode,
        mediaItemID: LibraryMediaItem.ID? = nil
    ) {
        self.displayID = displayID
        self.isEnabled = isEnabled
        self.contentMode = contentMode
        self.mediaItemID = mediaItemID
    }
}

struct DesktopScene: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var mode: DesktopSceneMode
    var appliesToAllConnectedDisplays: Bool
    var defaultContentMode: DesktopVideoContentMode
    var assignments: [DesktopDisplayAssignment]

    init(
        mode: DesktopSceneMode,
        appliesToAllConnectedDisplays: Bool,
        defaultContentMode: DesktopVideoContentMode,
        assignments: [DesktopDisplayAssignment]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.mode = mode
        self.appliesToAllConnectedDisplays =
            mode == .synchronized && appliesToAllConnectedDisplays
        self.defaultContentMode = defaultContentMode
        self.assignments = assignments
    }

    static func legacy(
        contentMode: DesktopVideoContentMode = .defaultValue
    ) -> DesktopScene {
        DesktopScene(
            mode: .synchronized,
            appliesToAllConnectedDisplays: true,
            defaultContentMode: contentMode,
            assignments: []
        )
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              assignments.count <= DesktopScenePolicy.maximumAssignmentCount,
              mode == .synchronized || !appliesToAllConnectedDisplays else {
            return false
        }

        var displayIDs: Set<DesktopDisplayID> = []
        for assignment in assignments {
            guard assignment.displayID.isValid,
                  displayIDs.insert(assignment.displayID).inserted else {
                return false
            }
            if mode == .perDisplay,
               assignment.isEnabled,
               assignment.mediaItemID == nil {
                return false
            }
        }
        return true
    }

    func assignment(
        for displayID: DesktopDisplayID
    ) -> DesktopDisplayAssignment? {
        assignments.first { $0.displayID == displayID }
    }
}

enum DesktopSceneStoreError: Error, Equatable, Sendable {
    case invalidScene
    case dataTooLarge(maximumByteCount: Int, observedByteCount: Int)
}

@MainActor
protocol DesktopSceneStoring: AnyObject {
    func load() throws -> DesktopScene?
    func save(_ scene: DesktopScene) throws
    func clear() throws
}
