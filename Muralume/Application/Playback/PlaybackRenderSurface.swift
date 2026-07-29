@MainActor
protocol PlaybackRenderSurface: AnyObject {
    var id: PlaybackSurfaceID { get }
    var isReadyForDisplay: Bool { get }
}
