import AVFoundation
import AppKit
import CoreImage

private enum DesktopBlurRenderingPolicy {
    // The blur is evaluated before this layer is enlarged to the desktop.
    // Bounding its long edge keeps the animated GPU workload independent of
    // 4K/5K display resolution while the foreground remains full resolution.
    static let maximumBackgroundLongEdge: CGFloat = 512
    static let blurRadius: CGFloat = 12
    static let overscanScale: CGFloat = 1.08
    static let shadeOpacity: Float = 0.16
}

@MainActor
final class DesktopPlayerLayerSurfaceView: NSView, AVPlayerRenderSurface {
    let id: PlaybackSurfaceID

    var isReadyForDisplay: Bool {
        foregroundPlayerLayer.isReadyForDisplay
            && (!isBackgroundVisible || backgroundPlayerLayer.isReadyForDisplay)
    }

    var connectedPlayerIdentity: ObjectIdentifier? {
        foregroundPlayerLayer.player.map(ObjectIdentifier.init)
    }

    var backgroundConnectedPlayerIdentity: ObjectIdentifier? {
        backgroundPlayerLayer.player.map(ObjectIdentifier.init)
    }

    var isBackgroundVisible: Bool {
        !backgroundPlayerLayer.isHidden
    }

    var foregroundVideoGravity: AVLayerVideoGravity {
        foregroundPlayerLayer.videoGravity
    }

    var foregroundDisplayedVideoRect: CGRect {
        foregroundPlayerLayer.videoRect
    }

    var backgroundVideoGravity: AVLayerVideoGravity {
        backgroundPlayerLayer.videoGravity
    }

    var backgroundRenderSize: CGSize {
        backgroundPlayerLayer.bounds.size
    }

    private(set) var contentMode: DesktopVideoContentMode

    private let backgroundPlayerLayer = AVPlayerLayer()
    private let backgroundShadeLayer = CALayer()
    private let foregroundPlayerLayer = AVPlayerLayer()
    private weak var connectedPlayer: AVPlayer?

    init(
        id: PlaybackSurfaceID,
        contentMode: DesktopVideoContentMode
    ) {
        self.id = id
        self.contentMode = contentMode
        super.init(frame: .zero)

        wantsLayer = true
        layerUsesCoreImageFilters = true
        configureLayers()
        applyContentMode()
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
        updateLayerGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerGeometry()
    }

    func connect(to player: AVPlayer?) {
        connectedPlayer = player
        updateBackgroundConnection()
        // Keep the clear foreground as the most recently associated layer.
        // Older AVFoundation implementations prioritized that layer when a
        // player was connected to more than one presentation surface.
        foregroundPlayerLayer.player = player
    }

    func setContentMode(_ contentMode: DesktopVideoContentMode) {
        guard self.contentMode != contentMode else {
            return
        }
        self.contentMode = contentMode
        applyContentMode()
        updateLayerGeometry()
    }

    private func configureLayers() {
        guard let rootLayer = layer else {
            preconditionFailure(
                "DesktopPlayerLayerSurfaceView requires a backing layer"
            )
        }

        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        disableImplicitAnimations(for: rootLayer)

        backgroundPlayerLayer.videoGravity = .resizeAspectFill
        backgroundPlayerLayer.backgroundColor = NSColor.black.cgColor
        backgroundPlayerLayer.contentsScale = 1
        backgroundPlayerLayer.magnificationFilter = .linear
        backgroundPlayerLayer.minificationFilter = .linear
        backgroundPlayerLayer.filters = [makeBlurFilter()]
        disableImplicitAnimations(for: backgroundPlayerLayer)

        backgroundShadeLayer.backgroundColor = NSColor.black.cgColor
        backgroundShadeLayer.opacity = DesktopBlurRenderingPolicy.shadeOpacity
        disableImplicitAnimations(for: backgroundShadeLayer)

        foregroundPlayerLayer.backgroundColor = NSColor.clear.cgColor
        foregroundPlayerLayer.masksToBounds = true
        disableImplicitAnimations(for: foregroundPlayerLayer)

        rootLayer.addSublayer(backgroundPlayerLayer)
        rootLayer.addSublayer(backgroundShadeLayer)
        rootLayer.addSublayer(foregroundPlayerLayer)
        updateLayerGeometry()
    }

    private func makeBlurFilter() -> CIFilter {
        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            preconditionFailure("CIGaussianBlur must be available on macOS")
        }
        filter.setValue(
            DesktopBlurRenderingPolicy.blurRadius,
            forKey: kCIInputRadiusKey
        )
        return filter
    }

    private func applyContentMode() {
        switch contentMode {
        case .blurredBackground:
            foregroundPlayerLayer.videoGravity = .resizeAspect
            backgroundPlayerLayer.isHidden = false
            backgroundShadeLayer.isHidden = false
        case .cover:
            foregroundPlayerLayer.videoGravity = .resizeAspectFill
            backgroundPlayerLayer.isHidden = true
            backgroundShadeLayer.isHidden = true
        case .contain:
            foregroundPlayerLayer.videoGravity = .resizeAspect
            backgroundPlayerLayer.isHidden = true
            backgroundShadeLayer.isHidden = true
        }
        updateBackgroundConnection()
        if contentMode == .blurredBackground {
            foregroundPlayerLayer.player = connectedPlayer
        }
    }

    private func updateBackgroundConnection() {
        backgroundPlayerLayer.player = contentMode == .blurredBackground
            ? connectedPlayer
            : nil
    }

    private func updateLayerGeometry() {
        guard !bounds.isEmpty else {
            return
        }

        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        layer?.contentsScale = backingScale
        foregroundPlayerLayer.contentsScale = backingScale
        foregroundPlayerLayer.frame = bounds
        backgroundShadeLayer.frame = bounds

        let workSize = backgroundWorkSize(for: bounds.size)
        backgroundPlayerLayer.bounds = CGRect(
            origin: .zero,
            size: workSize
        )
        backgroundPlayerLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        backgroundPlayerLayer.transform = CATransform3DMakeScale(
            bounds.width / workSize.width
                * DesktopBlurRenderingPolicy.overscanScale,
            bounds.height / workSize.height
                * DesktopBlurRenderingPolicy.overscanScale,
            1
        )
    }

    private func backgroundWorkSize(for targetSize: CGSize) -> CGSize {
        let longEdge = max(targetSize.width, targetSize.height)
        let scale = min(
            1,
            DesktopBlurRenderingPolicy.maximumBackgroundLongEdge / longEdge
        )
        return CGSize(
            width: max(1, (targetSize.width * scale).rounded(.up)),
            height: max(1, (targetSize.height * scale).rounded(.up))
        )
    }

    private func disableImplicitAnimations(for layer: CALayer) {
        layer.actions = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "contentsScale": NSNull(),
            "filters": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
            "player": NSNull(),
            "position": NSNull(),
            "sublayers": NSNull(),
            "transform": NSNull(),
            "videoGravity": NSNull()
        ]
    }
}
