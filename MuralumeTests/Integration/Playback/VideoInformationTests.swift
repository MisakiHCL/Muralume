import XCTest
@testable import Muralume

final class VideoInformationTests: XCTestCase {
    func testLoadsTechnicalInformationFromVideoFixture() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "landscape-20s-h264",
                withExtension: "mp4"
            )
        )
        let information = try await AVAssetVideoInformationLoader()
            .information(
                for: ResolvedMediaSource(
                    url: url,
                    displayName: "landscape-20s-h264.mp4"
                )
            )

        XCTAssertEqual(information.container, "MPEG-4")
        XCTAssertEqual(information.videoCodecs, ["H.264 / AVC"])
        XCTAssertEqual(
            information.resolution,
            VideoResolution(width: 320, height: 180)
        )
        XCTAssertEqual(
            information.resolution?.aspectRatio,
            VideoAspectRatio(width: 16, height: 9)
        )
        XCTAssertEqual(
            try XCTUnwrap(information.duration),
            20,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(information.frameRate),
            15,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(information.videoBitRate),
            0
        )
        XCTAssertEqual(information.dynamicRange, .unknown)
        XCTAssertNil(information.colorSpace)
        XCTAssertEqual(information.audioCodecs, [])
        XCTAssertEqual(information.audioTrackCount, 0)
        XCTAssertEqual(information.subtitleTrackCount, 0)
        XCTAssertEqual(information.fileSize, 158_219)
    }

    func testAppliesPreferredTransformToPortraitResolution() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "portrait-20s-h264",
                withExtension: "mp4"
            )
        )
        let information = try await AVAssetVideoInformationLoader()
            .information(
                for: ResolvedMediaSource(
                    url: url,
                    displayName: "portrait-20s-h264.mp4"
                )
            )

        XCTAssertEqual(
            information.resolution,
            VideoResolution(width: 180, height: 320)
        )
        XCTAssertEqual(
            information.resolution?.aspectRatio,
            VideoAspectRatio(width: 9, height: 16)
        )
    }

    func testCountsAudioAndSubtitleTracksAndDeduplicatesAudioCodec() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "alternate-tracks-5s",
                withExtension: "mp4"
            )
        )
        let information = try await AVAssetVideoInformationLoader()
            .information(
                for: ResolvedMediaSource(
                    url: url,
                    displayName: "alternate-tracks-5s.mp4"
                )
            )

        XCTAssertEqual(information.audioCodecs, ["AAC"])
        XCTAssertEqual(information.audioTrackCount, 2)
        XCTAssertEqual(information.subtitleTrackCount, 2)
    }

    func testClassifiesHDRAndCommonColorSpaces() {
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.dynamicRange(
                videoCodecIdentifiers: ["hvc1"],
                transferFunction: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.dynamicRange(
                videoCodecIdentifiers: ["avc1"],
                transferFunction: "ITU_R_709_2"
            ),
            .sdr
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.dynamicRange(
                videoCodecIdentifiers: ["dvh1"],
                transferFunction: nil
            ),
            .dolbyVision
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.dynamicRange(
                videoCodecIdentifiers: ["hvc1"],
                transferFunction: "SMPTE_ST_2084_PQ"
            ),
            .hdr10
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.dynamicRange(
                videoCodecIdentifiers: ["hvc1"],
                transferFunction: "ITU_R_2100_HLG"
            ),
            .hlg
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.colorSpace(
                colorPrimaries: "ITU_R_2020",
                yCbCrMatrix: nil
            ),
            "BT.2020"
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.colorSpace(
                colorPrimaries: "P3_D65",
                yCbCrMatrix: nil
            ),
            "Display P3"
        )
        XCTAssertEqual(
            VideoInformationMetadataInterpreter.colorSpace(
                colorPrimaries: "ITU_R_709_2",
                yCbCrMatrix: nil
            ),
            "BT.709"
        )
    }
}
