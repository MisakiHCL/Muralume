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

@MainActor
protocol DesktopHosting: AnyObject {
    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface
    func setVideoContentMode(_ contentMode: DesktopVideoContentMode)
    func setEnergyConstrained(_ isEnergyConstrained: Bool)
    func reveal()
    func reassertDesktopPlacement()
    func close()
}
