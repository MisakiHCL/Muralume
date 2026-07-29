import AVFoundation
import AppKit

@MainActor
protocol AVPlayerRenderSurface: PlaybackRenderSurface {
    func connect(to player: AVPlayer?)
}

@MainActor
final class PlayerLayerSurfaceView: NSView, AVPlayerRenderSurface {
    let id: PlaybackSurfaceID

    var isReadyForDisplay: Bool {
        playerLayer.isReadyForDisplay
    }

    var connectedPlayerIdentity: ObjectIdentifier? {
        playerLayer.player.map(ObjectIdentifier.init)
    }

    var displayedVideoRect: CGRect {
        playerLayer.videoRect
    }

    var videoGravity: AVLayerVideoGravity {
        playerLayer.videoGravity
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerLayerSurfaceView requires an AVPlayerLayer backing layer")
        }
        return playerLayer
    }

    init(id: PlaybackSurfaceID, videoGravity: AVLayerVideoGravity) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = videoGravity
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    func connect(to player: AVPlayer?) {
        playerLayer.player = player
    }

    func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = videoGravity
    }
}
