import Combine

enum DefaultVideoPlayerStatus: Equatable, Sendable {
    case none
    case partial
    case all
}

enum DefaultVideoPlayerFailure: Equatable, Sendable {
    case setDefaultFailed
}

@MainActor
protocol DefaultVideoPlayerServicing: AnyObject {
    var status: DefaultVideoPlayerStatus { get }
    func setAsDefault() async throws
}

@MainActor
final class DefaultVideoPlayerController: ObservableObject {
    @Published private(set) var status: DefaultVideoPlayerStatus
    @Published private(set) var operationFailure: DefaultVideoPlayerFailure?
    @Published private(set) var isUpdating = false

    var isDefault: Bool {
        status == .all
    }

    private let service: any DefaultVideoPlayerServicing

    init(service: any DefaultVideoPlayerServicing) {
        self.service = service
        status = service.status
    }

    func refresh() {
        status = service.status
        if status == .all {
            operationFailure = nil
        }
    }

    func setAsDefault() async {
        guard !isUpdating, status != .all else {
            return
        }

        isUpdating = true
        operationFailure = nil
        defer {
            isUpdating = false
        }

        do {
            try await service.setAsDefault()
        } catch {
            operationFailure = .setDefaultFailed
        }

        // Launch Services is authoritative: a request can partially succeed,
        // or another app can take an association while this call is pending.
        status = service.status
        if status == .all {
            operationFailure = nil
        } else if operationFailure == nil {
            operationFailure = .setDefaultFailed
        }
    }
}
