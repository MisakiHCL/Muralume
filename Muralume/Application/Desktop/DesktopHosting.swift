enum DesktopVideoContentMode: String, CaseIterable, Codable, Hashable, Sendable {
    case cover
    case contain

    static let defaultValue = DesktopVideoContentMode.cover

    var localizedKey: String {
        switch self {
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
    func reveal()
    func reassertDesktopPlacement()
    func close()
}
