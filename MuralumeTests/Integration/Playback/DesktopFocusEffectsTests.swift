import AVFoundation
import CoreImage.CIFilterBuiltins
import QuartzCore
import XCTest

@testable import Muralume

@MainActor
final class DesktopFocusEffectsTests: XCTestCase {
    func testMagnifierTracksPointerAndRestoresHoverMagnificationOnRelease() async throws {
        let effects = DesktopFocusEffects()
        defer { effects.stop() }
        let parent = CALayer()
        let video = CGRect(x: 0, y: 20, width: 500, height: 360)
        let first = CGPoint(x: 11.5, y: 38.5)
        let next = CGPoint(x: 215.5, y: 208.5)
        let ramp = CIFilter.linearGradient()
        ramp.point0 = .zero
        ramp.point1 = CGPoint(x: 512, y: 0)
        ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
        ramp.color1 = CIColor(red: 1, green: 1, blue: 1)
        let context = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: NSNull()])
        func sourceX(at point: CGPoint, through lens: CALayer) throws -> CGFloat {
            var image = try XCTUnwrap(ramp.outputImage?.cropped(to: video))
            let filters = try XCTUnwrap(lens.backgroundFilters as? [CIFilter])
            for filter in filters {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = try XCTUnwrap(filter.outputImage)
            }
            var rgba = [Float](repeating: 0, count: 4)
            let pixel = CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)
            context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: nil)
            return CGFloat(rgba[0]) * 512
        }
        effects.hover(at: first, in: video, on: parent)
        let lens = try XCTUnwrap(parent.sublayers?.first)
        let mask = try XCTUnwrap(lens.mask)
        XCTAssertEqual(lens.opacity, 1)
        XCTAssertTrue(video.contains(lens.frame))
        let firstDetail = CGPoint(x: first.x + 6, y: first.y)
        XCTAssertEqual(6 / (try sourceX(at: firstDetail, through: lens) - first.x), 1.8, accuracy: 0.06)
        effects.hover(at: next, in: video, on: parent)
        XCTAssertTrue(parent.sublayers?.first === lens)
        XCTAssertTrue(lens.mask === mask)
        XCTAssertEqual(lens.frame.midX, next.x)
        XCTAssertEqual(lens.frame.midY, next.y)
        XCTAssertEqual(try sourceX(at: firstDetail, through: lens), firstDetail.x, accuracy: 0.04)
        let radius = lens.bounds.width / 2
        XCTAssertGreaterThan(radius, video.height * 0.30)
        let hoverFrame = lens.frame
        for pressed in [false, true, false] {
            effects.hover(at: next, in: video, on: parent, pressed: pressed)
            XCTAssertTrue(parent.sublayers?.first === lens)
            XCTAssertEqual(lens.frame, hoverFrame)
            let centerDetail = CGPoint(x: next.x + 6, y: next.y)
            let centerScale = 6 / (try sourceX(at: centerDetail, through: lens) - next.x)
            XCTAssertEqual(centerScale, pressed ? 2.6 : 1.8, accuracy: 0.06)
            let expected = pressed ? [1.93, 1.23, 1.06, 1.00] : [1.50, 1.14, 1.04, 1.00]
            for (fraction, scale) in zip([0.25, 0.5, 0.75, 0.95], expected) {
                let offset = (radius * fraction).rounded()
                let point = CGPoint(x: next.x + offset, y: next.y)
                let source = try sourceX(at: point, through: lens)
                XCTAssertEqual(offset / (source - next.x), scale, accuracy: 0.07)
            }
        }
        let nextDetail = CGPoint(x: next.x + 6, y: next.y)
        try await Task.sleep(for: .milliseconds(360))
        XCTAssertTrue(parent.sublayers?.first === lens)
        XCTAssertEqual(6 / (try sourceX(at: nextDetail, through: lens) - next.x), 1.8, accuracy: 0.06)
        effects.leave()
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
    }

    func testMarqueeMaskFeathersEachEdgeAndKeepsTheCenterOpaque() throws {
        for (width, height) in [(140, 70), (8, 12)] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let mask = DesktopFocusEffects.selectionMask(in: bounds)
            var pixels = [UInt8](repeating: 0, count: width * height)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ))
                mask.render(in: context)
            }
            func sample(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }
            XCTAssertEqual(sample(width / 2, height / 2), 255)
            XCTAssertLessThan(sample(0, 0), sample(0, height / 2))
            for edge in [0, width - 1] { XCTAssertLessThan(sample(edge, height / 2), 100) }
            for edge in [0, height - 1] { XCTAssertLessThan(sample(width / 2, edge), 100) }
            if width == 140 {
                XCTAssertEqual(sample(7, height / 2), 125, accuracy: 5)
                XCTAssertEqual(sample(width / 2, 7), 125, accuracy: 5)
            }
        }
    }

    func testFreezeCropUsesTheVisibleSourceRegionAndAccountsForTopDownPixels() throws {
        let size = CGSize(width: 400, height: 200)
        var bytes = [UInt8](repeating: 0, count: 400 * 200 * 4)
        for y in 0..<200 {
            for x in 0..<400 {
                let sample = (y * 400 + x) * 4
                bytes[sample] = UInt8(x / 2)
                bytes[sample + 1] = UInt8(y)
                bytes[sample + 3] = 255
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let data = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400 * 4,
                                          space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // A 2:1 source covers a square. Its central 200 columns are visible.
        let square = CGRect(x: 24, y: 36, width: 200, height: 200)
        let selection = CGRect(x: 44, y: 198, width: 80, height: 24)
        let (crop, frame) = try XCTUnwrap(DesktopFocusEffects.crop(image, from: square, to: selection))
        XCTAssertEqual(frame, selection)
        XCTAssertEqual(crop.width, 80)
        XCTAssertEqual(crop.height, 24)
        // Both native axes matter at the corners of a wide marquee.
        for x in [0, crop.width - 1] {
            for y in [0, crop.height - 1] {
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(CIImage(cgImage: crop), toBitmap: &rgba, rowBytes: 4,
                               bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: space)
                XCTAssertEqual(Int(rgba[0]), (120 + x) / 2, accuracy: 1)
                XCTAssertEqual(Int(rgba[1]), 37 - y, accuracy: 1)
                XCTAssertEqual(rgba[3], 255)
            }
        }
    }

    func testMarqueeFreezesOnlyTheLatestRectangleWhileVideoContinuesThenExpires() async throws {
        let effects = DesktopFocusEffects()
        let player = AVPlayer(url: try TestMediaFixture.h264URL(for: Self.self))
        defer { effects.stop(); player.pause() }
        player.isMuted = true
        player.play()
        let startup = ContinuousClock.now + .seconds(4)
        while player.timeControlStatus != .playing, ContinuousClock.now < startup {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(player.timeControlStatus, .playing)
        let parent = CALayer()
        let displayed = CGRect(x: 0, y: 20, width: 448, height: 252)
        let selection = CGRect(x: 12, y: 180, width: 240, height: 66)
        let start = player.currentTime().seconds
        effects.freeze(in: CGRect(x: 300, y: 78, width: 110, height: 66), displayedRect: displayed,
                       on: parent, player: player)
        effects.freeze(in: selection, displayedRect: displayed, on: parent, player: player)
        let deadline = ContinuousClock.now + .milliseconds(500)
        while parent.sublayers?.isEmpty ?? true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let patch = try XCTUnwrap(parent.sublayers?.first)
        XCTAssertEqual(patch.frame, selection)
        let mask = try XCTUnwrap(patch.mask)
        XCTAssertEqual(mask.frame, patch.bounds)
        let content = try XCTUnwrap(patch.sublayers?.first)
        XCTAssertTrue(content.frame.contains(patch.bounds))
        effects.leave()
        let image = try XCTUnwrap(content.contents as AnyObject?)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(image === content.contents as AnyObject?)
        XCTAssertEqual(parent.sublayers?.count, 1)
        XCTAssertGreaterThan(player.currentTime().seconds, start)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
        try await Task.sleep(for: .milliseconds(720))
        XCTAssertTrue(patch.superlayer === parent)
        try await Task.sleep(for: .milliseconds(820))
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
    }
}
