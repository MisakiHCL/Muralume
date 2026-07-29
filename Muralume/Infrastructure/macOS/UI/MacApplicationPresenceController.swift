import AppKit

@MainActor
final class MacApplicationPresenceController: ApplicationPresenceControlling {
    private let application: NSApplication

    init(application: NSApplication = .shared) {
        self.application = application
    }

    @discardableResult
    func setMode(_ mode: ApplicationPresenceMode) -> Bool {
        let activationPolicy: NSApplication.ActivationPolicy = switch mode {
        case .standard:
            .regular
        case .menuBarOnly:
            .accessory
        }

        guard application.activationPolicy() != activationPolicy else {
            return true
        }
        return application.setActivationPolicy(activationPolicy)
    }
}
