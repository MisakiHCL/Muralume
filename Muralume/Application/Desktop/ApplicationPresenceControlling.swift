enum ApplicationPresenceMode: Equatable, Sendable {
    case standard
    case menuBarOnly
}

@MainActor
protocol ApplicationPresenceControlling: AnyObject {
    @discardableResult
    func setMode(_ mode: ApplicationPresenceMode) -> Bool
}
