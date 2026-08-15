enum DesktopVideoContentMode: String, CaseIterable, Codable, Hashable, Sendable {
    case blurredBackground = "blurredBackground"
    case cover = "cover"
    case contain = "contain"

    static let defaultValue = DesktopVideoContentMode.blurredBackground

    var localizedKey: String {
        switch self {
        case .blurredBackground:
            "desktop.contentMode.blurredBackground"
        case .cover:
            "desktop.contentMode.cover"
        case .contain:
            "desktop.contentMode.contain"
        }
    }
}

protocol DesktopVideoContentModeStoring {
    func load() -> DesktopVideoContentMode
    func save(_ contentMode: DesktopVideoContentMode)
}

struct DesktopHostPreparation {
    let synchronizedSurface: any PlaybackRenderSurface
    let displaySurfaces: [
        DesktopDisplayID: any PlaybackRenderSurface
    ]
}

enum DesktopDisplaySurfaceEvent {
    case didAdd(
        displayID: DesktopDisplayID,
        surface: any PlaybackRenderSurface
    )
    case willRemove(displayID: DesktopDisplayID)
}

enum DesktopVisibilityState: Equatable, Sendable {
    case visible
    case occluded
}

enum SmartPausePolicy {
    static func globalSuspensionReasons(
        constraints: Set<SystemEnergyConstraintReason>,
        preferences: SmartPausePreferences
    ) -> Set<PlaybackSuspensionReason> {
        guard preferences.isEnabled else {
            return []
        }

        var reasons: Set<PlaybackSuspensionReason> = []
        if preferences.pauseInLowPowerMode,
           constraints.contains(.lowPowerMode) {
            reasons.insert(.desktopLowPowerMode)
        }
        if preferences.pauseOnLimitedPowerSource,
           constraints.contains(.limitedPowerSource) {
            reasons.insert(.desktopLimitedPowerSource)
        }
        if preferences.pauseUnderSustainedSystemLoad,
           constraints.contains(.sustainedSystemLoad) {
            reasons.insert(.desktopSustainedSystemLoad)
        }
        return reasons
    }
}

@MainActor
protocol DesktopHosting: AnyObject {
    var desktopOcclusionHandler: ((Bool) -> Void)? { get set }
    var desktopVisibilityHandler: (
        ([DesktopDisplayID: DesktopVisibilityState]) -> Void
    )? { get set }

    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface
    func prepare(scene: DesktopScene) -> DesktopHostPreparation
    func setVideoContentMode(_ contentMode: DesktopVideoContentMode)
    func setVideoContentMode(
        _ contentMode: DesktopVideoContentMode,
        for displayID: DesktopDisplayID
    )
    func setDisplaySurfaceEventHandler(
        _ handler: ((DesktopDisplaySurfaceEvent) -> Void)?
    )
    func setEnergyConstrained(_ isEnergyConstrained: Bool)
    func reveal()
    func reassertDesktopPlacement()
    func close()
}

extension DesktopHosting {
    func prepare(scene: DesktopScene) -> DesktopHostPreparation {
        DesktopHostPreparation(
            synchronizedSurface: prepare(
                contentMode: scene.defaultContentMode
            ),
            displaySurfaces: [:]
        )
    }

    func setVideoContentMode(
        _ contentMode: DesktopVideoContentMode,
        for _: DesktopDisplayID
    ) {
        setVideoContentMode(contentMode)
    }

    func setDisplaySurfaceEventHandler(
        _: ((DesktopDisplaySurfaceEvent) -> Void)?
    ) {}
}
