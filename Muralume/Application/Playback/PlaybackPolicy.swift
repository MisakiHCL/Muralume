import Foundation

enum PlaybackPolicy {
    static let progressUpdateInterval: TimeInterval = 0.25
    static let itemReadyTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let surfaceReadyTimeoutNanoseconds: UInt64 = 1_500_000_000
    static let surfacePollIntervalNanoseconds: UInt64 = 16_000_000
    static let seekStepSeconds: TimeInterval = 10
    static let defaultRate = PlaybackRate(rawValue: 1)
    static let supportedRates: [PlaybackRate] = [
        PlaybackRate(rawValue: 0.5),
        PlaybackRate(rawValue: 0.75),
        PlaybackRate(rawValue: 1),
        PlaybackRate(rawValue: 1.25),
        PlaybackRate(rawValue: 1.5),
        PlaybackRate(rawValue: 2)
    ]
}
