import Foundation

struct VideoResolution: Equatable, Sendable {
    let width: Int
    let height: Int

    var aspectRatio: VideoAspectRatio? {
        guard width > 0, height > 0 else {
            return nil
        }
        let divisor = Self.greatestCommonDivisor(width, height)
        return VideoAspectRatio(
            width: width / divisor,
            height: height / divisor
        )
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }
}

struct VideoAspectRatio: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum VideoDynamicRange: Equatable, Sendable {
    case unknown
    case sdr
    case hdr10
    case hlg
    case dolbyVision
}

struct VideoInformation: Equatable, Sendable {
    let container: String?
    let videoCodecs: [String]
    let resolution: VideoResolution?
    let duration: TimeInterval?
    let frameRate: Double?
    let videoBitRate: Double?
    let dynamicRange: VideoDynamicRange
    let colorSpace: String?
    let audioCodecs: [String]
    let audioTrackCount: Int
    let subtitleTrackCount: Int
    let fileSize: Int64?
}

protocol VideoInformationLoading: Sendable {
    func information(
        for source: ResolvedMediaSource
    ) async throws -> VideoInformation
}
