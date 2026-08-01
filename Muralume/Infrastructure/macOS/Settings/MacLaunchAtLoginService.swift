import Foundation
import ServiceManagement

enum MacApplicationInstallLocation: Equatable {
    case applications
    case mountedVolume
    case other
}

struct MacApplicationInstallLocationResolver {
    private static let systemApplicationsDirectory = URL(
        fileURLWithPath: "/Applications",
        isDirectory: true
    )
    private static let mountedVolumesDirectory = URL(
        fileURLWithPath: "/Volumes",
        isDirectory: true
    )

    static func resolve(
        bundleURL: URL
    ) -> MacApplicationInstallLocation {
        let resolvedBundleURL = normalized(bundleURL)

        if isDescendant(
            resolvedBundleURL,
            of: normalized(mountedVolumesDirectory)
        ) {
            return .mountedVolume
        }
        if isDescendant(
            resolvedBundleURL,
            of: normalized(systemApplicationsDirectory)
        ) {
            return .applications
        }
        return .other
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isDescendant(
        _ candidate: URL,
        of directory: URL
    ) -> Bool {
        let candidateComponents = candidate.pathComponents
        let directoryComponents = directory.pathComponents
        guard candidateComponents.count > directoryComponents.count else {
            return false
        }
        return candidateComponents.prefix(directoryComponents.count)
            .elementsEqual(directoryComponents)
    }
}

@MainActor
final class MacLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: SMAppService
    private let bundleURL: URL

    init(
        service: SMAppService = .mainApp,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.service = service
        self.bundleURL = bundleURL
    }

    var status: LaunchAtLoginStatus {
        Self.map(
            systemStatus: service.status,
            installLocation: MacApplicationInstallLocationResolver.resolve(
                bundleURL: bundleURL
            )
        )
    }

    static func map(
        systemStatus: SMAppService.Status,
        installLocation: MacApplicationInstallLocation
    ) -> LaunchAtLoginStatus {
        switch systemStatus {
        case .notRegistered:
            unregisteredStatus(for: installLocation)
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            // On macOS 26, a main app with no Background Task Management
            // record can report notFound before its first registration. The
            // register call, not this status query, is the capability check.
            unregisteredStatus(for: installLocation)
        @unknown default:
            .unavailable(.systemService)
        }
    }

    private static func unregisteredStatus(
        for installLocation: MacApplicationInstallLocation
    ) -> LaunchAtLoginStatus {
        switch installLocation {
        case .applications:
            .disabled
        case .mountedVolume:
            .unavailable(.diskImage)
        case .other:
            .unavailable(.outsideApplications)
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
