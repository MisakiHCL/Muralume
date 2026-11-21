import AVFoundation
import CoreImage.CIFilterBuiltins
import QuartzCore

@MainActor
final class DesktopClickRipple {
    static let layerName = "muralume.desktop.water"
    private static let frameInterval: Duration = .milliseconds(33)

    private var field = DesktopWaterField()
    private var videoRect = CGRect.zero
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let backdrop = CALayer()
    private let activityMask = CALayer()
    private var animation: Task<Void, Never>?

    init() {
        backdrop.name = Self.layerName
        backdrop.masksToBounds = true
        backdrop.mask = activityMask
    }

    isolated deinit {
        stop()
    }

    static func filter(for frame: DesktopWaterField.Frame) -> CIFilter & CIDisplacementDistortion {
        let filter = CIFilter.displacementDistortion()
        filter.displacementImage = frame.displacementImage
        filter.scale = DesktopWaterField.displacementScale
        return filter
    }

    func show(
        _ input: DesktopWaterInput, at point: CGPoint, in visibleVideo: CGRect,
        on parent: CALayer, player: AVPlayer
    ) {
        guard let currentItem = player.currentItem, player.timeControlStatus == .playing else {
            stop()
            return
        }
        guard !visibleVideo.isEmpty, visibleVideo.contains(point) else { return }
        if self.player !== player || item !== currentItem || videoRect != visibleVideo || backdrop.superlayer !== parent {
            stop()
            self.player = player
            item = currentItem
            videoRect = visibleVideo
            backdrop.contentsScale = parent.contentsScale
            parent.addSublayer(backdrop)
        }
        let time = CACurrentMediaTime()
        field.disturb(input, at: point, in: visibleVideo, time: time)
        guard animation == nil, draw(at: time) else { return }
        animation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.frameInterval)
                guard !Task.isCancelled, self?.draw(at: CACurrentMediaTime()) == true else { return }
            }
        }
    }

    private func draw(at time: TimeInterval) -> Bool {
        guard let player, let item, player.currentItem === item, player.timeControlStatus == .playing,
              backdrop.superlayer != nil, let frame = field.frame(in: videoRect, at: time) else {
            stop()
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = frame.region
        // Preserve the original full-resolution video between disturbances, even when
        // Core Animation evaluates the backdrop at a different rasterization scale.
        activityMask.frame = backdrop.bounds
        activityMask.contents = frame.activityMask
        // Backdrop filters sample the already composited video in the parent's coordinates.
        // Reattach the filter each frame so Core Animation publishes the new displacement image.
        backdrop.backgroundFilters = [Self.filter(for: frame)]
        CATransaction.commit()
        return true
    }

    func stop() {
        animation?.cancel()
        animation = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.removeFromSuperlayer()
        backdrop.backgroundFilters = nil
        activityMask.contents = nil
        CATransaction.commit()
        field = DesktopWaterField()
        player = nil
        item = nil
    }
}
