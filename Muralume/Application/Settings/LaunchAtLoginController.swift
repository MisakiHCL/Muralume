import Combine

enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginFailure: Equatable, Sendable {
    case enableFailed
    case disableFailed
}

enum DynamicDesktopStartupFailure: Equatable, Sendable {
    case selectMediaFirst
    case presetUnavailable
    case enableFailed
    case disableFailed
    case automaticallyDisabled
    case manualDisableRequired
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var operationFailure: LaunchAtLoginFailure?
    @Published private(set) var isUpdating = false

    var isEffective: Bool {
        status == .enabled
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        status = service.status
    }

    func refresh() {
        status = service.status
        if operationFailure == .enableFailed,
           status == .enabled || status == .requiresApproval {
            operationFailure = nil
        } else if operationFailure == .disableFailed,
                  status == .disabled {
            operationFailure = nil
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isUpdating else {
            return
        }
        if isEnabled, isRequested {
            return
        }
        if !isEnabled, status == .disabled {
            return
        }

        isUpdating = true
        operationFailure = nil
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // The operating system status is authoritative even when an
            // idempotent registration call reports an error.
            status = service.status
            if isEnabled, status != .enabled,
               status != .requiresApproval {
                operationFailure = .enableFailed
            } else if !isEnabled, status != .disabled {
                operationFailure = .disableFailed
            }
            isUpdating = false
            return
        }

        status = service.status
        if isEnabled, status != .enabled,
           status != .requiresApproval {
            operationFailure = .enableFailed
        } else if !isEnabled, status != .disabled {
            operationFailure = .disableFailed
        }
        isUpdating = false
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

@MainActor
final class DynamicDesktopStartupController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var failure: DynamicDesktopStartupFailure?
    @Published private(set) var isUpdating = false

    var isEffective: Bool {
        status == .enabled
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    private let launchAtLogin: LaunchAtLoginController
    private let desktopPreset: DesktopPresetController
    private var updateTask: Task<Void, Never>?
    private var hasPendingAutomaticDisable = false
    private var isShuttingDown = false
    private var isAutomaticDisableFrozen = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        launchAtLogin: LaunchAtLoginController,
        desktopPreset: DesktopPresetController
    ) {
        self.launchAtLogin = launchAtLogin
        self.desktopPreset = desktopPreset
        status = launchAtLogin.status

        launchAtLogin.$status
            .removeDuplicates()
            .sink { [weak self, weak desktopPreset] status in
                guard let self else {
                    return
                }
                self.status = status
                self.reconcileFailure(with: status)
                desktopPreset?.setAutomaticRestorePrepared(
                    status == .enabled || status == .requiresApproval
                )
            }
            .store(in: &cancellables)

        desktopPreset.$persistenceFailure
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.handlePresetPersistenceFailure()
            }
            .store(in: &cancellables)

        desktopPreset.$automaticRestoreInvalidation
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.handlePresetInvalidation()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        launchAtLogin.refresh()
        status = launchAtLogin.status
        reconcileFailure(with: status)
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isShuttingDown,
              !isUpdating,
              isEnabled != isRequested else {
            return
        }

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else {
                return
            }
            if isEnabled {
                await enable()
            } else {
                disable()
            }
            updateTask = nil
        }
    }

    func openSystemSettings() {
        launchAtLogin.openSystemSettings()
    }

    func prepareForShutdown() async {
        isShuttingDown = true
        let currentTask = updateTask
        currentTask?.cancel()
        updateTask = nil
        await currentTask?.value
        processPendingAutomaticDisable()
    }

    func freezeAfterPresetFinalization() {
        isAutomaticDisableFrozen = true
        hasPendingAutomaticDisable = false
    }

    private func enable() async {
        isUpdating = true
        failure = nil

        switch await desktopPreset.prepareAutomaticRestore() {
        case .prepared:
            break
        case .noActiveQueue:
            failure = .selectMediaFirst
            isUpdating = false
            return
        case .persistenceFailed:
            failure = .presetUnavailable
            isUpdating = false
            return
        }

        guard !Task.isCancelled else {
            isUpdating = false
            return
        }
        launchAtLogin.setEnabled(true)
        status = launchAtLogin.status
        if status != .enabled && status != .requiresApproval {
            await desktopPreset.discardPreparedAutomaticRestore()
            failure = .enableFailed
        }
        isUpdating = false
        processPendingAutomaticDisable()
    }

    private func disable() {
        isUpdating = true
        failure = nil
        launchAtLogin.setEnabled(false)
        status = launchAtLogin.status
        if status != .disabled {
            failure = .disableFailed
        }
        isUpdating = false
        processPendingAutomaticDisable()
    }

    private func handlePresetPersistenceFailure() {
        guard isRequested else {
            return
        }

        requestAutomaticDisable()
    }

    private func handlePresetInvalidation() {
        guard isRequested else {
            return
        }

        requestAutomaticDisable()
    }

    private func requestAutomaticDisable() {
        guard !isAutomaticDisableFrozen,
              failure != .manualDisableRequired else {
            return
        }
        hasPendingAutomaticDisable = true
        processPendingAutomaticDisable()
    }

    private func processPendingAutomaticDisable() {
        guard hasPendingAutomaticDisable,
              !isUpdating,
              !isAutomaticDisableFrozen else {
            return
        }
        guard isRequested else {
            hasPendingAutomaticDisable = false
            return
        }

        hasPendingAutomaticDisable = false
        isUpdating = true
        launchAtLogin.setEnabled(false)
        status = launchAtLogin.status
        failure = status == .disabled
            ? .automaticallyDisabled
            : .manualDisableRequired
        isUpdating = false
    }

    private func reconcileFailure(with status: LaunchAtLoginStatus) {
        switch (failure, status) {
        case (.enableFailed, .enabled),
             (.enableFailed, .requiresApproval),
             (.disableFailed, .disabled),
             (.manualDisableRequired, .disabled):
            failure = nil
        default:
            break
        }
    }
}
