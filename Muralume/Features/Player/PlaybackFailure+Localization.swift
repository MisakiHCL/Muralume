extension PlaybackFailure {
    var localizedKey: String {
        switch self {
        case .unsupported:
            "media.error.unsupported"
        case .cannotOpen:
            "media.error.open"
        case .surfaceTimeout:
            "media.error.surface"
        }
    }
}

extension DesktopSessionFailure {
    var localizedKey: String {
        switch self {
        case let .playback(failure):
            failure.localizedKey
        case .statusMenuUnavailable:
            "desktop.error.statusMenu"
        }
    }
}
