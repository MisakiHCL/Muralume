import AVFoundation
import CoreImage
import QuartzCore
import XCTest

@testable import Muralume

@MainActor
final class DesktopClickRippleTests: XCTestCase {
    func testSharedSurfaceReinforcesAlignedWavesAndCancelsOpposingSlopes() throws {
        let video = CGRect(x: 0, y: 0, width: 640, height: 360)
        let origin = CGPoint(x: 180.5, y: 180.5)
        let time = 0.36
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let ramp = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: video.width, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1)
        ])?.outputImage?.cropped(to: video))
        var field = DesktopWaterField()
        field.disturb(.click, at: origin, in: video, time: 0)
        let single = try XCTUnwrap(field.frame(in: video, at: time))
        let strip = CGRect(x: origin.x + 0.5, y: origin.y - 0.5, width: 150, height: 1)
        // A horizontal intensity ramp encodes the sampled source x coordinate.
        // Measure the refraction actually applied by Core Image, in video points.
        func sampledPositions(_ image: CIImage) -> [Float] {
            var rgba = [Float](repeating: 0, count: Int(strip.width) * 4)
            context.render(image, toBitmap: &rgba, rowBytes: rgba.count * 4,
                           bounds: strip, format: .RGBAf, colorSpace: nil)
            return stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] * Float(video.width) }
        }
        let undisturbed = sampledPositions(ramp)
        func displacements(_ frame: DesktopWaterField.Frame) throws -> [Float] {
            let filter = DesktopClickRipple.filter(for: frame)
            filter.inputImage = ramp
            let output = try XCTUnwrap(filter.outputImage)
            return zip(sampledPositions(output), undisturbed).map { $0 - $1 }
        }
        let singleSlopes = try displacements(single)
        let interior = single.region.insetBy(dx: 4, dy: 4)
        let index = try XCTUnwrap(singleSlopes.indices.filter {
            interior.contains(CGPoint(x: strip.minX + CGFloat($0) + 0.5, y: origin.y))
        }.max { abs(singleSlopes[$0]) < abs(singleSlopes[$1]) })
        // Neutral samples at the active patch border must not bend the video into a rectangle.
        for column in singleSlopes.indices {
            let x = strip.minX + CGFloat(column) + 0.5
            if x >= single.region.maxX - 3 && x < single.region.maxX {
                XCTAssertLessThan(abs(singleSlopes[column]), 1)
            }
        }
        let amplitude = abs(singleSlopes[index])
        XCTAssertGreaterThan(amplitude, 1.5)

        var aligned = DesktopWaterField()
        aligned.disturb(.click, at: origin, in: video, time: 0)
        aligned.disturb(.click, at: origin, in: video, time: 0)
        let combined = try XCTUnwrap(aligned.frame(in: video, at: time))
        XCTAssertGreaterThan(abs(try displacements(combined)[index]), amplitude * 1.4)

        let offset = strip.minX + CGFloat(index) + 0.5 - origin.x
        let symmetric = CGPoint(x: origin.x + 2 * offset, y: origin.y)
        field.disturb(.click, at: symmetric, in: video, time: 0)
        let opposed = try XCTUnwrap(field.frame(in: video, at: time))
        XCTAssertLessThan(abs(try displacements(opposed)[index]), amplitude * 0.25)
    }

    func testClickAndPointerWakeJointlyRefractDecodedVideoAndLeaveFarPixelsStill() async throws {
        let asset = AVURLAsset(url: try TestMediaFixture.h264URL(for: Self.self))
        let generator = AVAssetImageGenerator(asset: asset)
        let (decoded, _) = try await generator.image(at: CMTime(value: 1, timescale: 1))
        let image = CIImage(cgImage: decoded).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        let video = image.extent
        let click = CGPoint(x: video.midX - 80, y: video.midY + 12)
        let move = CGPoint(x: click.x + 74, y: click.y + 6)
        let time = 0.35
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func bytes(_ picture: CIImage) -> [UInt8] {
            let rowBytes = Int(video.width) * 4
            var pixels = [UInt8](repeating: 0, count: rowBytes * Int(video.height))
            context.render(picture, toBitmap: &pixels, rowBytes: rowBytes, bounds: video,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixels
        }
        func refract(clicking: Bool, moving: Bool) throws -> [UInt8] {
            var field = DesktopWaterField()
            if clicking { field.disturb(.click, at: click, in: video, time: 0) }
            if moving { field.disturb(.movement, at: move, in: video, time: 0.17) }
            let map = try XCTUnwrap(field.frame(in: video, at: time))
            let filter = DesktopClickRipple.filter(for: map)
            filter.inputImage = image
            let distorted = try XCTUnwrap(filter.outputImage)
            let mask = CIImage(cgImage: map.activityMask)
            let size = mask.extent.size
            let transform = CGAffineTransform(a: map.region.width / size.width, b: 0,
                                              c: 0, d: map.region.height / size.height,
                                              tx: map.region.minX, ty: map.region.minY)
            let composite = distorted.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask.transformed(by: transform)
            ])
            return bytes(composite)
        }

        let original = bytes(image)
        let singleClick = try refract(clicking: true, moving: false)
        let singleMove = try refract(clicking: false, moving: true)
        let combined = try refract(clicking: true, moving: true)
        var overlap = 0
        var unexpected = 0
        for y in 0..<Int(video.height) {
            for x in 0..<Int(video.width) {
                let i = (y * Int(video.width) + x) * 4
                func changed(_ first: [UInt8], _ second: [UInt8]) -> Bool {
                    (0..<3).contains { abs(Int(first[i + $0]) - Int(second[i + $0])) > 3 }
                }
                if changed(singleClick, original), changed(singleMove, original),
                   changed(combined, singleClick), changed(combined, singleMove) { overlap += 1 }
                if x > Int(video.maxX) - 40, changed(combined, original) { unexpected += 1 }
            }
        }
        XCTAssertGreaterThan(overlap, 6)
        XCTAssertEqual(unexpected, 0)
    }

    func testClickAndMovementUseOneBackdropAndPreservePlaybackThroughPauseAndExpiry() async throws {
        let player = try await makePlayingVideo()
        let item = try XCTUnwrap(player.currentItem)
        let parent = CALayer()
        let video = CGRect(x: 48, y: 32, width: 480, height: 240)
        parent.bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let water = DesktopClickRipple()
        defer { water.stop(); player.pause() }
        let point = CGPoint(x: video.midX, y: video.midY)
        let start = player.currentTime().seconds
        water.show(.click, at: point, in: video, on: parent, player: player)
        try await Task.sleep(for: .milliseconds(80))
        let layer = try XCTUnwrap(parent.sublayers?.first)
        XCTAssertEqual(layer.name, DesktopClickRipple.layerName)
        water.show(.movement, at: CGPoint(x: point.x + 30, y: point.y), in: video, on: parent, player: player)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(parent.sublayers?.count, 1)
        XCTAssertTrue(parent.sublayers?.first === layer)
        XCTAssertTrue(video.contains(layer.frame))
        XCTAssertEqual(layer.backgroundFilters?.count, 1)
        XCTAssertNotNil(layer.mask?.contents)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
        XCTAssertGreaterThan(player.currentTime().seconds, start)
        XCTAssertTrue(item.outputs.isEmpty)

        player.pause()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(layer.superlayer)
        water.show(.click, at: point, in: video, on: parent, player: player)
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
        player.play()
        let playingDeadline = ContinuousClock.now + .seconds(3)
        while player.timeControlStatus != .playing && ContinuousClock.now < playingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        water.show(.movement, at: point, in: video, on: parent, player: player)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(parent.sublayers?.count, 1)
        let deadline = ContinuousClock.now + .seconds(3)
        while parent.sublayers?.isEmpty == false && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
        XCTAssertGreaterThan(player.currentTime().seconds, start)
        XCTAssertTrue(item.outputs.isEmpty)
    }

    func testFieldClipsToVisibleVideoAndGoesIdle() throws {
        var field = DesktopWaterField()
        let letterbox = CGRect(x: 20, y: 160, width: 400, height: 140)
        let outside = CGPoint(x: 80, y: 140)
        field.disturb(.click, at: outside, in: letterbox, time: 0)
        XCTAssertNil(field.frame(in: letterbox, at: 0.2))
        let inside = CGPoint(x: 22, y: 164)
        field.disturb(.click, at: inside, in: letterbox, time: 0.2)
        let frame = try XCTUnwrap(field.frame(in: letterbox, at: 0.4))
        XCTAssertTrue(letterbox.contains(frame.region))
        XCTAssertTrue(frame.region.contains(inside))
        XCTAssertNil(field.frame(in: letterbox, at: 3))
    }

    private func makePlayingVideo() async throws -> AVPlayer {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.isMuted = true
        // A reset to the start of the item is visible from a nonzero initial time.
        _ = await player.seek(
            to: CMTime(seconds: 3, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
              (player.timeControlStatus != .playing || player.currentTime().seconds < 3.2)
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.timeControlStatus, .playing)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 3)
        return player
    }
}
