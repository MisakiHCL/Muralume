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

enum DesktopBlurBackgroundPolicy {
    // This only absorbs floating-point noise. If a real bar can be visible,
    // the blurred background remains enabled.
    private static let aspectRatioTolerance: CGFloat = 0.000_001

    static func shouldRender(
        videoSize: CGSize,
        containerSize: CGSize,
        isEnergyConstrained: Bool
    ) -> Bool {
        guard !isEnergyConstrained else {
            return false
        }
        guard videoSize.width.isFinite,
              videoSize.height.isFinite,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              videoSize.width > 0,
              videoSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            // Preserve the decorative layer until AVFoundation publishes the
            // presentation size; this avoids a black-to-blur flash on attach.
            return true
        }

        let videoAspectRatio = videoSize.width / videoSize.height
        let containerAspectRatio = containerSize.width / containerSize.height
        let tolerance = max(videoAspectRatio, containerAspectRatio)
            * aspectRatioTolerance
        return abs(videoAspectRatio - containerAspectRatio) > tolerance
    }
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

    var isObservingPlayerItemChanges: Bool {
        currentItemObservation != nil
    }

    var isObservingPresentationSizeChanges: Bool {
        presentationSizeObservation != nil
    }

    private(set) var contentMode: DesktopVideoContentMode
    private(set) var isEnergyConstrained = false

    private let backgroundPlayerLayer = AVPlayerLayer()
    private let backgroundShadeLayer = CALayer()
    private let foregroundPlayerLayer = AVPlayerLayer()
    private weak var connectedPlayer: AVPlayer?
    private var currentItemObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?

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
        let didChangePlayer = connectedPlayer !== player
        if didChangePlayer {
            stopObservingPlayerChanges()
        }
        connectedPlayer = player
        refreshPlayerObservations()
        updateBackgroundPresentation()
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
        refreshPlayerObservations()
        applyContentMode()
        updateLayerGeometry()
    }

    func setEnergyConstrained(_ isEnergyConstrained: Bool) {
        guard self.isEnergyConstrained != isEnergyConstrained else {
            return
        }
        self.isEnergyConstrained = isEnergyConstrained
        refreshPlayerObservations()
        updateBackgroundPresentation()
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
        case .cover:
            foregroundPlayerLayer.videoGravity = .resizeAspectFill
        case .contain:
            foregroundPlayerLayer.videoGravity = .resizeAspect
        }
        updateBackgroundPresentation()
        if contentMode == .blurredBackground {
            foregroundPlayerLayer.player = connectedPlayer
        }
    }

    private func updateBackgroundPresentation() {
        let shouldRenderBackground = contentMode == .blurredBackground
            && DesktopBlurBackgroundPolicy.shouldRender(
                videoSize: connectedPlayer?.currentItem?.presentationSize
                    ?? .zero,
                containerSize: bounds.size,
                isEnergyConstrained: isEnergyConstrained
            )
        let isBackgroundHidden = !shouldRenderBackground
        if backgroundPlayerLayer.isHidden != isBackgroundHidden {
            backgroundPlayerLayer.isHidden = isBackgroundHidden
            backgroundShadeLayer.isHidden = isBackgroundHidden
        }
        let desiredBackgroundPlayer = shouldRenderBackground
            ? connectedPlayer
            : nil
        if backgroundPlayerLayer.player !== desiredBackgroundPlayer {
            backgroundPlayerLayer.player = desiredBackgroundPlayer
        }
    }

    private func observeCurrentItemChanges(in player: AVPlayer?) {
        stopObservingPlayerChanges()

        guard let player else {
            return
        }
        currentItemObservation = player.observe(
            \.currentItem,
            options: [.new]
        ) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self,
                      self.connectedPlayer === observedPlayer else {
                    return
                }
                self.observePresentationSize(of: observedPlayer?.currentItem)
            }
        }
        observePresentationSize(of: player.currentItem)
    }

    private func observePresentationSize(of item: AVPlayerItem?) {
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil

        guard let item else {
            updateBackgroundPresentation()
            return
        }
        presentationSizeObservation = item.observe(
            \.presentationSize,
            options: [.new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      self.connectedPlayer?.currentItem === item else {
                    return
                }
                self.updateBackgroundPresentation()
            }
        }
        updateBackgroundPresentation()
    }

    private func refreshPlayerObservations() {
        let shouldObserve = contentMode == .blurredBackground
            && !isEnergyConstrained
        guard shouldObserve, let connectedPlayer else {
            stopObservingPlayerChanges()
            return
        }
        guard currentItemObservation == nil else {
            return
        }
        observeCurrentItemChanges(in: connectedPlayer)
    }

    private func stopObservingPlayerChanges() {
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
    }

    private func updateLayerGeometry() {
        updateBackgroundPresentation()
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

@MainActor
final class DesktopPlayerLayerSurfaceGroup: AVPlayerRenderSurface {
    let id: PlaybackSurfaceID

    var isReadyForDisplay: Bool {
        !displaySurfaces.isEmpty
            && displaySurfaces.allSatisfy(\.isReadyForDisplay)
    }

    private(set) var displaySurfaces: [DesktopPlayerLayerSurfaceView] = []
    private(set) var isEnergyConstrained = false
    private weak var connectedPlayer: AVPlayer?

    init(id: PlaybackSurfaceID) {
        self.id = id
    }

    func connect(to player: AVPlayer?) {
        connectedPlayer = player
        displaySurfaces.forEach { $0.connect(to: player) }
    }

    func replaceDisplaySurfaces(
        _ displaySurfaces: [DesktopPlayerLayerSurfaceView]
    ) {
        let previousIdentities = Set(
            self.displaySurfaces.map(ObjectIdentifier.init)
        )
        let replacementIdentities = Set(
            displaySurfaces.map(ObjectIdentifier.init)
        )
        self.displaySurfaces
            .filter { !replacementIdentities.contains(ObjectIdentifier($0)) }
            .forEach { $0.connect(to: nil) }

        self.displaySurfaces = displaySurfaces
        self.displaySurfaces
            .filter { !previousIdentities.contains(ObjectIdentifier($0)) }
            .forEach {
                $0.setEnergyConstrained(isEnergyConstrained)
                $0.connect(to: connectedPlayer)
            }
    }

    func setContentMode(_ contentMode: DesktopVideoContentMode) {
        displaySurfaces.forEach { $0.setContentMode(contentMode) }
    }

    func setEnergyConstrained(_ isEnergyConstrained: Bool) {
        guard self.isEnergyConstrained != isEnergyConstrained else {
            return
        }
        self.isEnergyConstrained = isEnergyConstrained
        displaySurfaces.forEach {
            $0.setEnergyConstrained(isEnergyConstrained)
        }
    }
}
