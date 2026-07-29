enum PlaybackSurfaceID: String, Equatable, Sendable {
    case player
    case desktop
}

enum PlaybackReadiness: Equatable, Sendable {
    case empty
    case loading
    case ready
    case failed(PlaybackFailure)
}

enum PlaybackFailure: Equatable, Sendable {
    case unsupported
    case cannotOpen
    case surfaceTimeout
}

enum PlaybackLoadResult: Equatable, Sendable {
    case loaded
    case mediaFailure(PlaybackFailure)
    case globalFailure(PlaybackFailure)
    case cancelled
}

enum PlaybackPresentation: Equatable, Sendable {
    case player
    case switching(generation: UInt64, destination: PlaybackSurfaceID)
    case desktop
    case terminating
}
