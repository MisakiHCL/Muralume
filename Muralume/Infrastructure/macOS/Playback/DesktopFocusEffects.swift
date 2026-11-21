import AVFoundation
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Composites a live magnifier or a temporary selection from the playing video.
@MainActor
final class DesktopFocusEffects {
    private enum Timing {
        static let decodeTimeout = 1.0
        static let freezeHold = 0.65
        static let freezeFade = 0.85
        static let maximumImageSide: CGFloat = 3072
    }

    private var lens: CALayer?

    private var frameGenerator: AVAssetImageGenerator?
    private var frameRequest: UUID?
    private var freezeExpiry: Task<Void, Never>?
    private var frozenPatch: CALayer?

    isolated deinit {
        stop()
    }

    func hover(at point: CGPoint, in videoRect: CGRect, on parent: CALayer, pressed: Bool = false) {
        guard videoRect.contains(point) else { leave(); return }
        let radius = Self.radius(in: videoRect)
        let area = Self.neighborhood(at: point, radius: radius)
        let frame = area.intersection(videoRect)
        // Both profiles use the same footprint. Only the center magnification
        // increases on a press, with both distortions easing out at their edges.
        func refraction(radius: CGFloat, strength: Float) -> CIFilter {
            let filter = CIFilter.bumpDistortion()
            filter.center = point
            filter.radius = Float(radius)
            filter.scale = strength
            return filter
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let patch: CALayer
        if let lens {
            patch = lens
        } else {
            patch = CALayer()
            patch.masksToBounds = true
            patch.mask = Self.makeLensMask()
            lens = patch
        }
        patch.frame = frame
        patch.contentsScale = parent.contentsScale
        patch.mask?.frame = area.offsetBy(dx: -frame.minX, dy: -frame.minY)
        patch.backgroundFilters = [
            refraction(radius: radius, strength: pressed ? 0.35 : 0.23),
            refraction(radius: radius * 0.56, strength: pressed ? 0.415 : 0.28)
        ]
        if patch.superlayer !== parent { parent.addSublayer(patch) }
        CATransaction.commit()
    }

    func leave() {
        lens?.removeFromSuperlayer()
        lens = nil
    }

    func freeze(
        in selection: CGRect, displayedRect: CGRect, on parent: CALayer, player: AVPlayer
    ) {
        let region = selection.standardized.intersection(displayedRect)
        guard !region.isEmpty, !region.isInfinite,
              let item = player.currentItem, player.timeControlStatus == .playing else { return }
        let time = item.currentTime()
        guard time.isNumeric else { return }
        clearFreeze()

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.videoComposition = item.videoComposition
        // Decode the frame displayed on mouse-up, including the asset's orientation.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let maxSide = min(Timing.maximumImageSide,
                          max(displayedRect.width, displayedRect.height) * max(1, parent.contentsScale))
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        frameGenerator = generator
        let request = UUID()
        frameRequest = request
        expireFreeze(after: Timing.decodeTimeout)
        let display: @MainActor @Sendable (CGImage?) -> Void = { [weak self, weak parent, weak player, weak item] image in
            guard let self, frameRequest == request, let image, let parent, let player, let item,
                  player.currentItem === item, player.timeControlStatus == .playing else { return }
            frameGenerator = nil
            showFrozenImage(image, in: region, displayed: displayedRect, on: parent)
        }
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            Task { @MainActor in display(image) }
        }
    }

    private func showFrozenImage(
        _ image: CGImage, in region: CGRect, displayed displayedRect: CGRect,
        on parent: CALayer
    ) {
        guard let (crop, imageFrame) = Self.crop(image, from: displayedRect, to: region) else { return }
        let lifetime = Timing.freezeHold + Timing.freezeFade

        let patch = CALayer()
        let content = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.frame = region
        patch.masksToBounds = true
        patch.mask = Self.selectionMask(in: patch.bounds)
        content.frame = imageFrame.offsetBy(dx: -region.minX, dy: -region.minY)
        content.contents = crop
        patch.addSublayer(content)
        parent.addSublayer(patch)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: Timing.freezeHold / lifetime), 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        fade.duration = lifetime
        patch.opacity = 0
        patch.add(fade, forKey: "opacity")
        CATransaction.commit()
        frozenPatch = patch
        // Decoding the clicked frame must not shorten its visible hold or fade.
        expireFreeze(after: lifetime)
    }

    private func expireFreeze(after seconds: TimeInterval) {
        freezeExpiry?.cancel()
        freezeExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.clearFreeze()
        }
    }

    private func clearFreeze() {
        frameRequest = nil
        frameGenerator?.cancelAllCGImageGeneration()
        frameGenerator = nil
        freezeExpiry?.cancel()
        freezeExpiry = nil
        frozenPatch?.removeFromSuperlayer()
        frozenPatch = nil
    }

    func stop() {
        leave()
        clearFreeze()
    }

    private static func radius(in rect: CGRect) -> CGFloat {
        min(320, max(80, min(rect.width, rect.height) * 0.33))
    }

    private static func neighborhood(at point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func makeLensMask() -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        let solid = CGColor(gray: 1, alpha: 1)
        mask.colors = [solid, solid, CGColor(gray: 1, alpha: 0)]
        mask.locations = [0, 0.94, 1]
        return mask
    }

    /// Feather inward in display points, retaining an opaque middle even in a narrow selection.
    static func selectionMask(in bounds: CGRect) -> CALayer {
        let width = min(40, min(bounds.width, bounds.height) * 0.22)
        let transparent = CGColor(gray: 1, alpha: 0)
        let solid = CGColor(gray: 1, alpha: 1)
        func gradient(from start: CGPoint, to end: CGPoint, length: CGFloat) -> CAGradientLayer {
            let edge = width / length
            let result = CAGradientLayer()
            result.frame = bounds
            result.startPoint = start
            result.endPoint = end
            result.colors = [transparent, solid, solid, transparent]
            result.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            return result
        }
        let horizontal = gradient(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5), length: bounds.width)
        horizontal.mask = gradient(from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1), length: bounds.height)
        return horizontal
    }

    /// CGImage crops count down from the top. The desktop surface counts up.
    static func crop(_ image: CGImage, from displayed: CGRect, to region: CGRect) -> (CGImage, CGRect)? {
        guard !displayed.isEmpty, !region.isEmpty else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        // For aspect fill, videoRect may be clipped to the layer bounds.
        let scale = max(displayed.width / size.width, displayed.height / size.height)
        let source = CGRect(x: displayed.midX - size.width * scale / 2,
                            y: displayed.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        let pixels = CGRect(x: (region.minX - source.minX) / scale,
                            y: (source.maxY - region.maxY) / scale,
                            width: region.width / scale, height: region.height / scale)
            .integral.intersection(CGRect(origin: .zero, size: size))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        let actual = CGRect(x: source.minX + pixels.minX * scale,
                            y: source.maxY - pixels.maxY * scale,
                            width: pixels.width * scale, height: pixels.height * scale)
        return (crop, actual)
    }
}
