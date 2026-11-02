import Foundation
@testable import Muralume

/// Keeps deterministic library tests independent of native filesystem events.
@MainActor
final class DisabledMediaLibraryChangeMonitor: MediaLibraryChangeMonitoring {
    @discardableResult
    func update(
        folderURLs: [URL],
        onChange: @escaping @Sendable () -> Void
    ) async -> Bool {
        true
    }

    func stop() {}
}
