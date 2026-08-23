import AVFoundation
import AppKit

enum PlaybackSurfaceTransitionAnimationKey {
    static let incomingOpacity =
        "muralume.queue-crossfade.incoming"
    static let outgoingOpacity =
        "muralume.queue-crossfade.outgoing"
}

@MainActor
protocol AVPlayerRenderSurface: PlaybackRenderSurface {
    func connect(to player: AVPlayer?)
}

@MainActor
protocol AVPlayerTransitionSurface: AVPlayerRenderSurface {
    func prepareTransition(to player: AVPlayer)
    func commitPreparedTransition(duration: TimeInterval)
    func cancelPreparedTransition()
}

@MainActor
final class PlayerLayerSurfaceView: NSView, AVPlayerRenderSurface {
    let id: PlaybackSurfaceID

    var isReadyForDisplay: Bool {
        preparedTransitionPlayerLayer?.isReadyForDisplay
            ?? activePlayerLayer.isReadyForDisplay
    }

    var connectedPlayerIdentity: ObjectIdentifier? {
        activePlayerLayer.player.map(ObjectIdentifier.init)
    }

    var displayedVideoRect: CGRect {
        activePlayerLayer.videoRect
    }

    var videoGravity: AVLayerVideoGravity {
        activePlayerLayer.videoGravity
    }

    private var activePlayerLayer = AVPlayerLayer()
    private var transitionPlayerLayer = AVPlayerLayer()
    private var preparedTransitionPlayerLayer: AVPlayerLayer?
    private var transitionCleanupWorkItem: DispatchWorkItem?

    init(id: PlaybackSurfaceID, videoGravity: AVLayerVideoGravity) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        configurePlayerLayer(activePlayerLayer, videoGravity: videoGravity)
        configurePlayerLayer(transitionPlayerLayer, videoGravity: videoGravity)
        transitionPlayerLayer.opacity = 0
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(activePlayerLayer)
        layer?.addSublayer(transitionPlayerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        activePlayerLayer.frame = bounds
        transitionPlayerLayer.frame = bounds
    }

    func connect(to player: AVPlayer?) {
        cancelPreparedTransition()
        activePlayerLayer.player = player
    }

    func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        activePlayerLayer.videoGravity = videoGravity
        transitionPlayerLayer.videoGravity = videoGravity
    }

    private func configurePlayerLayer(
        _ playerLayer: AVPlayerLayer,
        videoGravity: AVLayerVideoGravity
    ) {
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.actions = [
            "bounds": NSNull(),
            "opacity": NSNull(),
            "player": NSNull(),
            "position": NSNull(),
            "videoGravity": NSNull()
        ]
    }
}

extension PlayerLayerSurfaceView: AVPlayerTransitionSurface {
    func prepareTransition(to player: AVPlayer) {
        cancelPreparedTransition()
        transitionPlayerLayer.player = player
        transitionPlayerLayer.opacity = 0
        preparedTransitionPlayerLayer = transitionPlayerLayer
    }

    func commitPreparedTransition(duration: TimeInterval) {
        guard preparedTransitionPlayerLayer === transitionPlayerLayer else {
            return
        }
        preparedTransitionPlayerLayer = nil
        transitionCleanupWorkItem?.cancel()

        let outgoingLayer = activePlayerLayer
        let incomingLayer = transitionPlayerLayer
        incomingLayer.opacity = 1
        outgoingLayer.opacity = 0
        incomingLayer.add(
            opacityAnimation(from: 0, to: 1, duration: duration),
            forKey: PlaybackSurfaceTransitionAnimationKey.incomingOpacity
        )
        outgoingLayer.add(
            opacityAnimation(from: 1, to: 0, duration: duration),
            forKey: PlaybackSurfaceTransitionAnimationKey.outgoingOpacity
        )

        activePlayerLayer = incomingLayer
        transitionPlayerLayer = outgoingLayer

        let cleanup = DispatchWorkItem { [weak self, weak outgoingLayer] in
            guard let self,
                  transitionPlayerLayer === outgoingLayer else {
                return
            }
            outgoingLayer?.removeAllAnimations()
            outgoingLayer?.player = nil
            outgoingLayer?.opacity = 0
            activePlayerLayer.removeAllAnimations()
            activePlayerLayer.opacity = 1
            transitionCleanupWorkItem = nil
        }
        transitionCleanupWorkItem = cleanup
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(duration, 0),
            execute: cleanup
        )
    }

    func cancelPreparedTransition() {
        transitionCleanupWorkItem?.cancel()
        transitionCleanupWorkItem = nil
        preparedTransitionPlayerLayer = nil
        activePlayerLayer.removeAllAnimations()
        transitionPlayerLayer.removeAllAnimations()
        activePlayerLayer.opacity = 1
        transitionPlayerLayer.opacity = 0
        transitionPlayerLayer.player = nil
    }

    private func opacityAnimation(
        from start: Float,
        to end: Float,
        duration: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = max(duration, 0)
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )
        return animation
    }
}
