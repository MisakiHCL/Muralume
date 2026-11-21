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

    // Oldest first. A distant jump can overlap at most two local footprints.
    private var lenses: [Lens] = []

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let next: Lens
        if let index = lenses.lastIndex(where: { $0.canFollow(point, radius: radius, on: parent) }) {
            next = lenses[index]
            if next.expiry != nil {
                // A quick reversal resumes the outgoing refraction from its visible strength.
                next.expiry?.cancel()
                next.expiry = nil
                lenses.remove(at: index)
                lenses.append(next)
            }
        } else {
            if lenses.count == 2 { remove(lenses[0]) }
            next = Lens(at: point, radius: radius, in: videoRect, on: parent)
            lenses.append(next)
        }
        if let previous = lenses.first, previous !== next { retire(previous) }
        next.move(to: point, in: videoRect)
        next.setStrength(pressed: pressed)
    }

    func leave() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for lens in lenses { retire(lens) }
        CATransaction.commit()
    }

    private func retire(_ lens: Lens) {
        guard lens.expiry == nil else { return }
        lens.setStrength(pressed: nil)
        lens.expiry = Task { @MainActor [weak self, weak lens] in
            do { try await Task.sleep(for: .seconds(Lens.strengthDuration)) } catch { return }
            if let lens { self?.remove(lens) }
        }
    }

    private func remove(_ lens: Lens) {
        lens.expiry?.cancel()
        lens.expiry = nil
        lens.layer.removeFromSuperlayer()
        lenses.removeAll { $0 === lens }
    }

    @MainActor
    private final class Lens {
        static let strengthDuration = 0.20
        private static let followDuration = 0.12
        private static let followCurve = CAMediaTimingFunction(controlPoints: 0.15, 0.75, 0.3, 1)
        private static let strengthCurve = CAMediaTimingFunction(name: .easeInEaseOut)
        private static let outer = "outerLens"
        private static let inner = "innerLens"

        let layer = CALayer()
        var expiry: Task<Void, Never>?
        private let mask = DesktopFocusEffects.makeLensMask()
        private let radius: CGFloat
        private var center: CGPoint
        private var isPressed: Bool?

        init(at point: CGPoint, radius: CGFloat, in videoRect: CGRect, on parent: CALayer) {
            self.radius = radius
            center = point
            let area = DesktopFocusEffects.neighborhood(at: point, radius: radius)
            let frame = area.intersection(videoRect)
            layer.frame = frame
            layer.contentsScale = parent.contentsScale
            layer.masksToBounds = true
            mask.frame = area.offsetBy(dx: -frame.minX, dy: -frame.minY)
            layer.mask = mask

            func refraction(name: String, radius: CGFloat) -> CIFilter {
                let filter = CIFilter.bumpDistortion()
                filter.name = name
                filter.center = point
                filter.radius = Float(radius)
                filter.scale = 0
                return filter
            }
            layer.backgroundFilters = [refraction(name: Self.outer, radius: radius),
                                       refraction(name: Self.inner, radius: radius * 0.56)]
            parent.addSublayer(layer)
        }

        func canFollow(_ point: CGPoint, radius: CGFloat, on parent: CALayer) -> Bool {
            layer.superlayer === parent && self.radius == radius
                && hypot(point.x - center.x, point.y - center.y) <= radius
        }

        func move(to point: CGPoint, in videoRect: CGRect) {
            guard point != center else { return }
            center = point
            let area = DesktopFocusEffects.neighborhood(at: point, radius: radius)
            let frame = area.intersection(videoRect)
            let maskCenter = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            let position = CGPoint(x: frame.midX, y: frame.midY)
            let bounds = CGRect(origin: .zero, size: frame.size)
            func follow(_ target: CALayer, _ key: String, _ value: NSObject) {
                target.animateDesktopEffect(key, to: value, duration: Self.followDuration, timing: Self.followCurve)
            }
            follow(layer, "position", NSValue(point: position))
            follow(layer, "bounds", NSValue(rect: bounds))
            follow(mask, "position", NSValue(point: maskCenter))
            for name in [Self.outer, Self.inner] {
                follow(layer, "backgroundFilters.\(name).inputCenter", CIVector(cgPoint: point))
            }
        }

        func setStrength(pressed: Bool?) {
            guard isPressed != pressed else { return }
            isPressed = pressed
            let outer: Float = pressed.map { $0 ? 0.35 : 0.23 } ?? 0
            let inner: Float = pressed.map { $0 ? 0.415 : 0.28 } ?? 0
            for (name, strength) in [(Self.outer, outer), (Self.inner, inner)] {
                layer.animateDesktopEffect("backgroundFilters.\(name).inputScale", to: NSNumber(value: strength),
                                           duration: Self.strengthDuration, timing: Self.strengthCurve)
            }
        }
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
        for lens in lenses { remove(lens) }
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
