import Foundation

enum DesktopSceneStorageKey {
    static let scene = "desktop.scene"
}

@MainActor
final class UserDefaultsDesktopSceneStore: DesktopSceneStoring {
    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumEncodedByteCount: Int

    init(
        userDefaults: UserDefaults = .standard,
        maximumEncodedByteCount: Int =
            DesktopScenePolicy.maximumEncodedByteCount
    ) {
        precondition(
            maximumEncodedByteCount > 0
                && maximumEncodedByteCount < Int.max
        )
        self.userDefaults = userDefaults
        self.maximumEncodedByteCount = maximumEncodedByteCount
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func load() throws -> DesktopScene? {
        guard let data = userDefaults.data(
            forKey: DesktopSceneStorageKey.scene
        ) else {
            return nil
        }
        try validateByteCount(data.count)
        let scene = try decoder.decode(DesktopScene.self, from: data)
        guard scene.isValid else {
            throw DesktopSceneStoreError.invalidScene
        }
        return scene
    }

    func save(_ scene: DesktopScene) throws {
        guard scene.isValid else {
            throw DesktopSceneStoreError.invalidScene
        }
        let data = try encoder.encode(scene)
        try validateByteCount(data.count)
        userDefaults.set(data, forKey: DesktopSceneStorageKey.scene)
    }

    func clear() throws {
        userDefaults.removeObject(forKey: DesktopSceneStorageKey.scene)
    }

    private func validateByteCount(_ byteCount: Int) throws {
        guard byteCount <= maximumEncodedByteCount else {
            throw DesktopSceneStoreError.dataTooLarge(
                maximumByteCount: maximumEncodedByteCount,
                observedByteCount: byteCount
            )
        }
    }
}
