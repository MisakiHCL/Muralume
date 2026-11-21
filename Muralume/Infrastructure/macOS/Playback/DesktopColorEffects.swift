import AVFoundation
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Decode one small frame at a time independently of the playing item. The
/// pointer can keep sampling the latest frame while the next one is loading.
private actor DesktopHueSampler {
    enum Update {
        case unchanged, neutral, table(Data)
    }
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let generator: AVAssetImageGenerator
    private var frame: CIImage?
    private var nextFrameRequest = ContinuousClock.now
    private var isDecoding = false
    private var cancelled = false
    private var lastPoint: CGPoint?
    private var lastBand: Int?

    init(asset: AVAsset, composition: AVVideoComposition?) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 384, height: 384)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        self.generator = generator
    }

    func read(at time: CMTime, point: CGPoint, displayed: CGRect, presentation: CGSize) -> Update {
        guard !cancelled, !Task.isCancelled else { return .unchanged }
        let now = ContinuousClock.now
        if time.isNumeric, !isDecoding, now >= nextFrameRequest {
            nextFrameRequest = now + .milliseconds(100)
            isDecoding = true
            generator.generateCGImageAsynchronously(for: time) { [weak self] image, _, _ in
                Task { await self?.didDecode(image) }
            }
        }
        guard let frame, point != lastPoint else { return .unchanged }
        lastPoint = point
        guard let hue = DesktopColorEffects.sampleHue(in: frame, at: point, displayedRect: displayed,
                                                      presentation: presentation, context: context) else {
            lastBand = nil
            return .neutral
        }
        // 5-degree steps keep nearly identical samples from rebuilding the cube.
        let band = Int((hue * 12).rounded()) % 72
        guard band != lastBand else { return .unchanged }
        lastBand = band
        return .table(DesktopColorEffects.selectiveColorTable(hue: Float(band) / 12))
    }

    private func didDecode(_ image: CGImage?) {
        isDecoding = false
        guard !cancelled, let image else { return }
        frame = CIImage(cgImage: image)
        lastPoint = nil
    }

    func cancel() {
        cancelled = true
        generator.cancelAllCGImageGeneration()
        frame = nil
    }
}

@MainActor
final class DesktopColorEffects {
    nonisolated private static let cubeSize = 24
    private static let releaseDuration = 0.22
    private var sampler: DesktopHueSampler?
    private var sampling: Task<Void, Never>?
    private var removal: Task<Void, Never>?
    private var point: CGPoint?
    private var focused: CALayer?
    private var dimmed: CALayer?
    private var illuminated: CALayer?
    private var spotlightBoost: CALayer?

    isolated deinit { stop() }

    func beginPicking(at point: CGPoint, in visible: CGRect, displayedRect: CGRect,
                      on parent: CALayer, player: AVPlayer) {
        clearFocus()
        guard visible.contains(point), !displayedRect.isEmpty,
              let item = player.currentItem, player.timeControlStatus == .playing else { return }
        self.point = point
        let sampler = DesktopHueSampler(asset: item.asset, composition: item.videoComposition)
        self.sampler = sampler
        sampling = Task { @MainActor [weak self, weak player, weak parent] in
            while !Task.isCancelled, let point = self?.point, let parent, let player,
                  player.currentItem === item, player.timeControlStatus == .playing {
                let update = await sampler.read(at: item.currentTime(), point: point, displayed: displayedRect,
                                                presentation: item.presentationSize)
                guard !Task.isCancelled else { return }
                guard player.currentItem === item, player.timeControlStatus == .playing else { break }
                switch update {
                case .unchanged: break
                case .neutral:
                    self?.focused?.removeFromSuperlayer()
                    self?.focused = nil
                case .table(let data):
                    self?.applyFocus(data, in: visible, to: parent)
                }
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
            }
            if !Task.isCancelled { self?.endPicking() }
        }
    }

    func movePick(to point: CGPoint) {
        if sampling != nil { self.point = point }
    }

    private func applyFocus(_ data: Data, in visible: CGRect, to parent: CALayer) {
        let patch = focused ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.frame = visible
        patch.masksToBounds = true
        patch.contentsScale = parent.contentsScale
        patch.backgroundFilters = [Self.filter(with: data)]
        if patch.superlayer !== parent { parent.addSublayer(patch) }
        CATransaction.commit()
        focused = patch
    }

    func endPicking() {
        cancelSampling()
        guard removal == nil, let patch = focused else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(1)
        fade.toValue = Float(0)
        fade.duration = Self.releaseDuration
        patch.add(fade, forKey: "focusRelease")
        CATransaction.commit()
        removal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Self.releaseDuration)) } catch { return }
            self?.clearFocus()
        }
    }

    func dim(in visible: CGRect, on parent: CALayer) {
        guard !visible.isEmpty else { return }
        let shade = dimmed ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = visible
        shade.backgroundColor = CGColor(gray: 0, alpha: 1)
        shade.opacity = 0.18
        if shade.superlayer !== parent { parent.addSublayer(shade) }
        CATransaction.commit()
        dimmed = shade
    }

    func illuminate(at point: CGPoint, in visible: CGRect, on parent: CALayer, pressed: Bool = false) {
        dim(in: visible, on: parent)
        guard visible.contains(point), let dimmed else { leave(); return }
        let radius = min(440, max(96, min(visible.width, visible.height) * 0.42))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func place(_ existing: CALayer?, radius: CGFloat) -> CALayer {
            let patch: CALayer
            if let existing {
                patch = existing
            } else {
                patch = CALayer()
                patch.masksToBounds = true
                patch.backgroundFilters = [Self.shadowFilter()]
                patch.mask = Self.gradient(inverse: false)
            }
            let disc = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let frame = disc.intersection(visible)
            patch.frame = frame
            patch.contentsScale = parent.contentsScale
            patch.mask?.frame = disc.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if patch.superlayer !== parent { parent.insertSublayer(patch, below: dimmed) }
            return patch
        }
        illuminated = place(illuminated, radius: radius)
        if pressed {
            // The smaller second pass further lifts shadows while preserving highlights.
            spotlightBoost = place(spotlightBoost, radius: radius * 0.5)
        } else {
            clearSpotlightBoost()
        }
        // The shade above the corrected image has a matching soft opening.
        let opening = (dimmed.mask as? CAGradientLayer) ?? Self.gradient(inverse: true)
        opening.frame = dimmed.bounds
        let center = CGPoint(x: (point.x - visible.minX) / visible.width, y: (point.y - visible.minY) / visible.height)
        opening.startPoint = center
        opening.endPoint = CGPoint(x: center.x + radius / visible.width, y: center.y + radius / visible.height)
        dimmed.mask = opening
        CATransaction.commit()
    }

    private func clearSpotlightBoost() {
        spotlightBoost?.removeFromSuperlayer()
        spotlightBoost = nil
    }

    private static func gradient(inverse: Bool) -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        mask.colors = [1, 0.96, 0.73, 0.37, 0.10, 0].map { (alpha: CGFloat) in
            CGColor(gray: 1, alpha: inverse ? 1 - alpha : alpha)
        }
        mask.locations = [0, 0.12, 0.38, 0.64, 0.85, 1]
        return mask
    }

    func leave() {
        endPicking()
        clearSpotlightBoost()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        illuminated?.removeFromSuperlayer()
        illuminated = nil
        dimmed?.mask = nil
        CATransaction.commit()
    }

    func stop() {
        leave()
        clearFocus()
        dimmed?.removeFromSuperlayer()
        dimmed = nil
    }

    private func cancelSampling() {
        point = nil
        sampling?.cancel()
        sampling = nil
        if let sampler {
            self.sampler = nil
            Task { await sampler.cancel() }
        }
    }

    private func clearFocus() {
        cancelSampling()
        removal?.cancel()
        removal = nil
        focused?.removeFromSuperlayer()
        focused = nil
    }

    nonisolated static func sampleHue(in image: CIImage, at point: CGPoint, displayedRect: CGRect,
                                      presentation: CGSize, context: CIContext) -> Float? {
        let size = presentation.width > 0 && presentation.height > 0 ? presentation : image.extent.size
        guard !image.extent.isEmpty, size.width > 0, size.height > 0, displayedRect.contains(point) else { return nil }
        let fit = max(displayedRect.width / size.width, displayedRect.height / size.height)
        let width = size.width * fit, height = size.height * fit
        let x = image.extent.minX + (0.5 + (point.x - displayedRect.midX) / width) * image.extent.width
        let y = image.extent.minY + (0.5 + (point.y - displayedRect.midY) / height) * image.extent.height
        let roi = CGRect(x: x - 1, y: y - 1, width: 3, height: 3).integral.intersection(image.extent)
        guard !roi.isEmpty else { return nil }
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = roi
        guard let sample = average.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(sample, toBitmap: &pixel, rowBytes: 4, bounds: sample.extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let rgb = SIMD3(Float(pixel[0]), Float(pixel[1]), Float(pixel[2])) / 255
        guard rgb.max() - rgb.min() >= max(0.042, 0.12 * rgb.max()) else { return nil }
        return hue(of: rgb)
    }

    nonisolated private static func hue(of rgb: SIMD3<Float>) -> Float {
        let high = rgb.max(), span = high - rgb.min()
        guard span > 0 else { return 0 }
        let sector: Float
        if high == rgb.x { sector = (rgb.y - rgb.z) / span }
        else if high == rgb.y { sector = (rgb.z - rgb.x) / span + 2 }
        else { sector = (rgb.x - rgb.y) / span + 4 }
        return sector < 0 ? sector + 6 : sector
    }

    nonisolated private static func sRGB(_ linear: Float) -> Float {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    nonisolated fileprivate static func selectiveColorTable(hue target: Float) -> Data {
        // CIColorCube uses linear RGB samples. Compare hues in perceptual sRGB,
        // then mix with linear luminance so the desaturated subject keeps its brightness.
        let encoded = (0..<cubeSize).map { sRGB(Float($0) / Float(cubeSize - 1)) }
        return cubeData { rgb, r, g, b in
            let distance = abs(hue(of: SIMD3(encoded[r], encoded[g], encoded[b])) - target)
            let arc = min(distance, 6 - distance)
            let blend = min(1, max(0, (arc - 0.28) / 0.51))
            let chroma = 1 - 0.97 * blend * blend * (3 - 2 * blend)
            let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
            return SIMD3(repeating: luminance) + chroma * (rgb - SIMD3(repeating: luminance))
        }
    }

    static func selectiveColorFilter(hue: Float) -> CIFilter { filter(with: selectiveColorTable(hue: hue)) }

    // Immutable transfer table shared by all pointers. It contains no video data.
    private static let shadowTable = cubeData { rgb, _, _, _ in
        let shadow = max(0, 1 - rgb.max() / 0.65)
        return rgb * (1 + 2.5 * shadow * shadow)
    }

    private static func shadowFilter() -> CIFilter { filter(with: shadowTable) }

    private static func filter(with table: Data) -> CIFilter {
        let cube = CIFilter.colorCube()
        cube.cubeDimension = Float(cubeSize)
        cube.cubeData = table
        cube.extrapolate = true
        return cube
    }

    nonisolated private static func cubeData(_ map: (SIMD3<Float>, Int, Int, Int) -> SIMD3<Float>) -> Data {
        var samples = [SIMD4<Float>]()
        samples.reserveCapacity(cubeSize * cubeSize * cubeSize)
        for b in 0..<cubeSize {
            for g in 0..<cubeSize {
                for r in 0..<cubeSize {
                    let color = SIMD3(Float(r), Float(g), Float(b)) / Float(cubeSize - 1)
                    samples.append(SIMD4(map(color, r, g, b), 1))
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
