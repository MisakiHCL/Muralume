import Foundation

@MainActor
protocol VideoScreenshotControlling: AnyObject {
    func capture(
        source: ResolvedMediaSource,
        at time: TimeInterval
    )
    func cancel()
}
