import AVFoundation
import CoreImage
import Metal
import QuartzCore
import XCTest

@testable import Muralume

@MainActor
final class DesktopColorEffectsTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])

    func testSampledHueUsesTheVisibleCropAndNoHueForNeutralPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 100, y: 100, width: 100, height: 100))
        let gray = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let pattern = gray.composited(over: green.composited(over: red))
        let image = pattern
        let square = CGRect(x: 16, y: 32, width: 200, height: 200)
        func hue(_ x: Int, _ y: Int) -> Float? {
            DesktopColorEffects.sampleHue(in: image, at: CGPoint(x: x, y: y), displayedRect: square,
                                          presentation: bounds.size, context: context)
        }
        XCTAssertEqual(try XCTUnwrap(hue(24, 184)), 2, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(hue(196, 184)), 0, accuracy: 0.04)
        XCTAssertNil(hue(24, 64))
    }

    func testSelectedColorSurvivesWhileOtherHuesLoseChromaOnLiveInput() throws {
        let filter = DesktopColorEffects.selectiveColorFilter(hue: 0)
        let red = try rgb(SIMD3(0.85, 0.01, 0.01), through: filter)
        let green = try rgb(SIMD3(0.01, 0.85, 0.01), through: filter)
        XCTAssertGreaterThan(red.x - red.y, 0.79)
        XCTAssertLessThan(green.max() - green.min(), 0.05)
        XCTAssertGreaterThan(green.min(), 0.54)
    }

    func testWideSpotlightProtectsHighlightsAndRetainsTheDimBackgroundOnLeave() throws {
        let effects = DesktopColorEffects()
        defer { effects.stop() }
        let parent = CALayer()
        let visible = CGRect(x: 12, y: 20, width: 420, height: 236)
        effects.dim(in: visible, on: parent)
        let shade = try XCTUnwrap(parent.sublayers?.first)
        XCTAssertEqual(shade.frame, visible)
        XCTAssertGreaterThan(shade.opacity, 0)
        XCTAssertLessThan(shade.opacity, 0.3)
        effects.illuminate(at: CGPoint(x: 17, y: 25), in: visible, on: parent)
        let patch = try XCTUnwrap(parent.sublayers?.first)
        let filter = try XCTUnwrap(patch.backgroundFilters?.first as? CIFilter)
        let dark = try rgb(SIMD3(repeating: 0.065), through: filter)
        let bright = try rgb(SIMD3(repeating: 0.94), through: filter)
        XCTAssertGreaterThan(dark.x, 0.17)
        XCTAssertEqual(bright.x, 0.94, accuracy: 0.006)
        XCTAssertTrue(visible.contains(patch.frame))
        let mask = try XCTUnwrap(patch.mask)
        effects.illuminate(at: CGPoint(x: 220, y: 126), in: visible, on: parent)
        XCTAssertTrue(parent.sublayers?.first === patch)
        XCTAssertTrue(patch.mask === mask)
        XCTAssertEqual(patch.frame.midX, 220, accuracy: 0.01)
        XCTAssertGreaterThan(patch.frame.width, visible.height * 0.8)
        XCTAssertNotNil(shade.mask)
        effects.leave()
        XCTAssertEqual(parent.sublayers, [shade])
        XCTAssertNil(shade.mask)
        effects.stop()
        XCTAssertTrue(parent.sublayers?.isEmpty ?? true)
    }

    func testHeldPickSwitchesBetweenSourceColorsWithoutReconfiguringPlayback() async throws {
        let player = AVPlayer(url: try TestMediaFixture.h264URL(for: Self.self))
        player.isMuted = true
        player.play()
        let effects = DesktopColorEffects()
        defer { effects.stop(); player.pause() }
        let startup = ContinuousClock.now + .seconds(3)
        while player.timeControlStatus != .playing, ContinuousClock.now < startup {
            try await Task.sleep(for: .milliseconds(20))
        }
        let parent = CALayer()
        let visible = CGRect(x: 12, y: 20, width: 320, height: 180)
        let start = player.currentTime().seconds
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.outputs.isEmpty)
        effects.beginPicking(at: CGPoint(x: 32, y: 40), in: visible, displayedRect: visible,
                             on: parent, player: player)
        XCTAssertTrue(item.outputs.isEmpty)
        let first = ContinuousClock.now + .seconds(2)
        while parent.sublayers?.first == nil, ContinuousClock.now < first {
            try await Task.sleep(for: .milliseconds(12))
        }
        let patch = try XCTUnwrap(parent.sublayers?.first)
        let firstFilter = try XCTUnwrap(patch.backgroundFilters?.first as? CIFilter)
        let red = try rgb(SIMD3(0.85, 0.01, 0.01), through: firstFilter)
        XCTAssertGreaterThan(red.x - red.z, 0.75)
        effects.movePick(to: CGPoint(x: 177, y: 40))
        let moved = ContinuousClock.now + .seconds(1)
        var blue = SIMD3<Float>.zero
        repeat {
            try await Task.sleep(for: .milliseconds(12))
            if let filter = patch.backgroundFilters?.first as? CIFilter {
                blue = try rgb(SIMD3(0.01, 0.01, 0.85), through: filter)
            }
        } while blue.z - blue.x < 0.75 && ContinuousClock.now < moved
        XCTAssertGreaterThan(blue.z - blue.x, 0.75)
        XCTAssertEqual(parent.sublayers, [patch])
        XCTAssertTrue(item.outputs.isEmpty)
        effects.endPicking()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(patch.superlayer)
        XCTAssertGreaterThan(player.currentTime().seconds, start)
        effects.stop()
        XCTAssertTrue(item.outputs.isEmpty)
    }

    func testReplacingAndCancellingPicksDoesNotInstallLateColorLayers() async throws {
        let player = AVPlayer(url: try TestMediaFixture.h264URL(for: Self.self))
        player.isMuted = true
        player.play()
        let effects = DesktopColorEffects()
        defer { effects.stop(); player.pause() }
        let startup = ContinuousClock.now + .seconds(3)
        while player.timeControlStatus != .playing, ContinuousClock.now < startup {
            try await Task.sleep(for: .milliseconds(20))
        }
        let first = CALayer(), second = CALayer()
        let visible = CGRect(x: 0, y: 0, width: 320, height: 180)
        let point = CGPoint(x: 20, y: 20)
        effects.beginPicking(at: point, in: visible, displayedRect: visible, on: first, player: player)
        await Task.yield()
        effects.beginPicking(at: point, in: visible, displayedRect: visible, on: second, player: player)
        let deadline = ContinuousClock.now + .seconds(2)
        while second.sublayers?.first == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertNotNil(second.sublayers?.first)
        effects.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(first.sublayers?.isEmpty ?? true)
        XCTAssertTrue(second.sublayers?.isEmpty ?? true)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
    }

    func testSpotlightBoostFollowsHeldPointerAndClearsOnReleaseOrExit() throws {
        let effects = DesktopColorEffects()
        defer { effects.stop() }
        let parent = CALayer()
        let area = CGRect(x: 0, y: 0, width: 600, height: 350)
        let center = CGPoint(x: 200, y: 160)
        effects.illuminate(at: center, in: area, on: parent)
        let ordinary = try XCTUnwrap(parent.sublayers)
        let baseFilter = try XCTUnwrap(ordinary.first?.backgroundFilters?.first as? CIFilter)
        effects.illuminate(at: center, in: area, on: parent, pressed: true)
        let layers = try XCTUnwrap(parent.sublayers)
        XCTAssertEqual(layers.count, ordinary.count + 1)
        let core = try XCTUnwrap(layers.first { !ordinary.contains($0) })
        XCTAssertLessThan(core.frame.width, ordinary[0].frame.width * 0.6)
        XCTAssertNotNil(core.mask)
        let heldFilter = try XCTUnwrap(core.backgroundFilters?.first as? CIFilter)
        let dark = try rgb(SIMD3(repeating: 0.035), through: baseFilter)
        let boosted = try rgb(dark, through: heldFilter)
        XCTAssertGreaterThan(boosted.x - dark.x, 0.09)
        let high = try rgb(SIMD3(repeating: 0.94), through: baseFilter)
        XCTAssertEqual(try rgb(high, through: heldFilter).x, high.x, accuracy: 0.006)

        let moved = CGPoint(x: 345, y: 180)
        effects.illuminate(at: moved, in: area, on: parent, pressed: true)
        XCTAssertEqual(core.frame.midX, moved.x, accuracy: 0.1)
        XCTAssertEqual(parent.sublayers, layers)
        XCTAssertTrue(core.mask?.animationKeys()?.isEmpty ?? true)
        effects.illuminate(at: moved, in: area, on: parent, pressed: false)
        XCTAssertEqual(parent.sublayers, ordinary)
        effects.illuminate(at: moved, in: area, on: parent, pressed: true)
        effects.leave()
        XCTAssertEqual(parent.sublayers, [ordinary[1]])
    }

    func testCompositedSpotlightBoostIsSustainedUntilReleaseAndPreservesTheOuterSpot() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Offscreen compositing requires a Metal device")
        }
        let size = 256
        let area = CGRect(x: 0, y: 0, width: size, height: size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        let root = CALayer()
        root.frame = area
        root.backgroundColor = CGColor(gray: 0.12, alpha: 1)
        renderer.layer = root
        renderer.bounds = area
        let effects = DesktopColorEffects()
        defer { effects.stop() }
        func sample(at time: CFTimeInterval) throws -> (center: UInt8, outside: UInt8) {
            CATransaction.flush()
            renderer.beginFrame(atTime: time, timeStamp: nil)
            renderer.addUpdate(area)
            renderer.render()
            renderer.endFrame()
            let fence = try XCTUnwrap(queue.makeCommandBuffer())
            fence.commit()
            fence.waitUntilCompleted()
            var row = [UInt8](repeating: 0, count: size * 4)
            texture.getBytes(&row, bytesPerRow: row.count, from: MTLRegionMake2D(0, size / 2, size, 1),
                             mipmapLevel: 0)
            return (row[(size / 2) * 4], row[4 * 4])
        }
        let center = CGPoint(x: area.midX, y: area.midY)
        effects.illuminate(at: center, in: area, on: root)
        let initial = try sample(at: CACurrentMediaTime())
        effects.illuminate(at: center, in: area, on: root, pressed: true)
        let start = CACurrentMediaTime()
        let pressed = try sample(at: start)
        let held = try sample(at: start + 2)
        effects.illuminate(at: center, in: area, on: root, pressed: false)
        let restored = try sample(at: start + 2.1)
        XCTAssertGreaterThan(Int(pressed.center) - Int(initial.center), 16)
        XCTAssertEqual(held.center, pressed.center)
        XCTAssertEqual(restored.center, initial.center)
        XCTAssertEqual(held.outside, initial.outside)
    }

    private func rgb(_ value: SIMD3<Float>, through filter: CIFilter) throws -> SIMD3<Float> {
        let color = CIColor(red: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z))
        filter.setValue(CIImage(color: color), forKey: kCIInputImageKey)
        let image = try XCTUnwrap(filter.outputImage)
        var rgba = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return SIMD3(rgba[0], rgba[1], rgba[2])
    }
}
