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
        let layers = preparedTransitionPlayer == nil ? activeLayers : spareLayers
        return layers.foreground.isReadyForDisplay
            && (layers.background.isHidden || layers.background.isReadyForDisplay)
    }

    var connectedPlayerIdentity: ObjectIdentifier? {
        activeLayers.foreground.player.map(ObjectIdentifier.init)
    }

    var backgroundConnectedPlayerIdentity: ObjectIdentifier? {
        activeLayers.background.player.map(ObjectIdentifier.init)
    }

    var isBackgroundVisible: Bool {
        !activeLayers.background.isHidden
    }

    var foregroundVideoGravity: AVLayerVideoGravity {
        activeLayers.foreground.videoGravity
    }

    var foregroundDisplayedVideoRect: CGRect {
        activeLayers.foreground.videoRect
    }

    var backgroundVideoGravity: AVLayerVideoGravity {
        activeLayers.background.videoGravity
    }

    var backgroundRenderSize: CGSize {
        activeLayers.background.bounds.size
    }

    var isObservingPlayerItemChanges: Bool {
        currentItemObservation != nil
    }

    var isObservingPresentationSizeChanges: Bool {
        presentationSizeObservation != nil
    }

    private(set) var contentMode: DesktopVideoContentMode
    private(set) var isEnergyConstrained = false

    private var clickRipple: DesktopClickRipple?
    private var focusEffects: DesktopFocusEffects?
    private var colorEffects: DesktopColorEffects?
    private var isPickingColor = false
    var refreshPointerPosition: (() -> Void)? {
        didSet { observeHoverReadiness() }
    }
    private var hoverPlaybackObservation: NSKeyValueObservation?
    private var hoverLayerObservation: NSKeyValueObservation?

    private final class VideoLayers {
        let container = CALayer()
        let background = AVPlayerLayer()
        let shade = CALayer()
        let foreground = AVPlayerLayer()
    }

    private let videoContainer = CALayer()
    private var activeLayers = VideoLayers()
    private var spareLayers = VideoLayers()
    private weak var connectedPlayer: AVPlayer?
    private weak var preparedTransitionPlayer: AVPlayer?
    private var transitionCleanupWorkItem: DispatchWorkItem?
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
        let didResize = videoContainer.frame != bounds
        if didResize { clearDesktopEffects() }
        updateLayerGeometry()
        if didResize { refreshHoverWhenReady() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        clearDesktopEffects()
        updateLayerGeometry()
        refreshHoverWhenReady()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearDesktopEffects() }
        super.viewWillMove(toWindow: newWindow)
    }

    private var interactivePlayer: AVPlayer? {
        guard preparedTransitionPlayer == nil, transitionCleanupWorkItem == nil,
              activeLayers.foreground.isReadyForDisplay,
              let connectedPlayer, connectedPlayer.timeControlStatus == .playing else { return nil }
        return connectedPlayer
    }

    func handleDesktopInteraction(
        _ effect: DesktopInteractionEffect, input: DesktopPointerInput, at point: CGPoint
    ) {
        guard let layer, let player = interactivePlayer else {
            clearDesktopEffects()
            return
        }
        let visible = bounds.intersection(activeLayers.foreground.videoRect)
        guard visible.contains(point) else {
            desktopPointerDidLeave()
            return
        }
        switch (effect, input) {
        case (.waterRipple, .click), (.waterRipple, .movement):
            if clickRipple == nil { clickRipple = DesktopClickRipple() }
            let pulse: DesktopWaterInput = input == .click ? .click : .movement
            clickRipple?.show(pulse, at: point, in: visible, on: layer, player: player)
        case (.colorFocus, .pressBegan), (.colorFocus, .pressMoved):
            if isPickingColor, input == .pressMoved {
                colorEffects?.movePick(to: point)
            } else {
                if colorEffects == nil { colorEffects = DesktopColorEffects() }
                isPickingColor = true
                colorEffects?.beginPicking(at: point, in: visible, displayedRect: activeLayers.foreground.videoRect,
                                           on: layer, player: player)
            }
        case (.shadowLight, .movement), (.shadowLight, .pressBegan), (.shadowLight, .pressMoved):
            if colorEffects == nil { colorEffects = DesktopColorEffects() }
            colorEffects?.illuminate(at: point, in: visible, on: layer, pressed: input != .movement)
        case (.hoverLens, .movement), (.hoverLens, .pressBegan), (.hoverLens, .pressMoved):
            if focusEffects == nil { focusEffects = DesktopFocusEffects() }
            focusEffects?.hover(at: point, in: visible, on: layer, pressed: input != .movement)
        default:
            break
        }
    }

    func freezeDesktopSelection(_ selection: CGRect) {
        guard let layer, let player = interactivePlayer else { return }
        let displayed = activeLayers.foreground.videoRect
        let region = bounds.intersection(displayed).intersection(selection)
        guard !region.isEmpty else { return }
        if focusEffects == nil { focusEffects = DesktopFocusEffects() }
        focusEffects?.freeze(in: region, displayedRect: displayed, on: layer, player: player)
    }

    func dimDesktopVideo() {
        guard let layer, interactivePlayer != nil else { return }
        let visible = bounds.intersection(activeLayers.foreground.videoRect)
        guard !visible.isEmpty else { return }
        if colorEffects == nil { colorEffects = DesktopColorEffects() }
        colorEffects?.dim(in: visible, on: layer)
    }

    func endDesktopColorPick() {
        isPickingColor = false
        colorEffects?.endPicking()
    }

    func desktopPointerDidLeave() {
        focusEffects?.leave()
        if isPickingColor {
            colorEffects?.stop()
            isPickingColor = false
        } else {
            colorEffects?.leave()
        }
    }

    private func observeHoverReadiness() {
        hoverPlaybackObservation = nil
        hoverLayerObservation = nil
        guard refreshPointerPosition != nil, let connectedPlayer else { return }
        // Keep a still pointer attached to live video across pause, resume and item changes.
        hoverPlaybackObservation = connectedPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshHoverWhenReady() }
        }
        hoverLayerObservation = activeLayers.foreground.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshHoverWhenReady() }
        }
    }

    private func refreshHoverWhenReady() {
        guard let refreshPointerPosition else { return }
        if interactivePlayer != nil {
            refreshPointerPosition()
        } else {
            clearDesktopEffects()
        }
    }

    func clearDesktopEffects() {
        clickRipple?.stop()
        clickRipple = nil
        focusEffects?.stop()
        focusEffects = nil
        colorEffects?.stop()
        colorEffects = nil
        isPickingColor = false
    }

    func connect(to player: AVPlayer?) {
        clearDesktopEffects()
        cancelPreparedTransition()
        bind(player, to: activeLayers)
        observeActivePlayer(player)
        refreshHoverWhenReady()
    }

    private func bind(_ player: AVPlayer?, to layers: VideoLayers) {
        updateBackground(in: layers, for: player)
        if layers.foreground.player !== player {
            layers.foreground.player = player
        }
    }

    private func observeActivePlayer(_ player: AVPlayer?) {
        if connectedPlayer !== player {
            stopObservingPlayerChanges()
        }
        connectedPlayer = player
        observeHoverReadiness()
        refreshPlayerObservations()
    }

    func setContentMode(_ contentMode: DesktopVideoContentMode) {
        guard self.contentMode != contentMode else {
            return
        }
        clearDesktopEffects()
        self.contentMode = contentMode
        refreshPlayerObservations()
        applyContentMode()
        updateLayerGeometry()
        refreshHoverWhenReady()
    }

    func setEnergyConstrained(_ isEnergyConstrained: Bool) {
        guard self.isEnergyConstrained != isEnergyConstrained else {
            return
        }
        self.isEnergyConstrained = isEnergyConstrained
        refreshPlayerObservations()
        updateBackgrounds()
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

        disableImplicitAnimations(for: videoContainer)
        rootLayer.addSublayer(videoContainer)
        for layers in [activeLayers, spareLayers] {
            layers.container.backgroundColor = NSColor.black.cgColor
            disableImplicitAnimations(for: layers.container)

            layers.background.videoGravity = .resizeAspectFill
            layers.background.backgroundColor = NSColor.black.cgColor
            layers.background.contentsScale = 1
            layers.background.magnificationFilter = .linear
            layers.background.minificationFilter = .linear
            layers.background.filters = [makeBlurFilter()]
            disableImplicitAnimations(for: layers.background)

            layers.shade.backgroundColor = NSColor.black.cgColor
            layers.shade.opacity = DesktopBlurRenderingPolicy.shadeOpacity
            disableImplicitAnimations(for: layers.shade)

            layers.foreground.backgroundColor = NSColor.clear.cgColor
            layers.foreground.masksToBounds = true
            disableImplicitAnimations(for: layers.foreground)

            layers.container.addSublayer(layers.background)
            layers.container.addSublayer(layers.shade)
            layers.container.addSublayer(layers.foreground)
            videoContainer.addSublayer(layers.container)
        }
        activeLayers.container.zPosition = 1
        spareLayers.container.opacity = 0
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
        let gravity: AVLayerVideoGravity = contentMode == .cover
            ? .resizeAspectFill : .resizeAspect
        activeLayers.foreground.videoGravity = gravity
        spareLayers.foreground.videoGravity = gravity
        updateBackgrounds()
    }

    private func updateBackgrounds() {
        for layers in [activeLayers, spareLayers] {
            updateBackground(in: layers, for: layers.foreground.player)
        }
    }

    private func updateBackground(in layers: VideoLayers, for player: AVPlayer?) {
        let shouldRender = contentMode == .blurredBackground
            && DesktopBlurBackgroundPolicy.shouldRender(
                videoSize: player?.currentItem?.presentationSize ?? .zero,
                containerSize: bounds.size,
                isEnergyConstrained: isEnergyConstrained
            )
        layers.background.isHidden = !shouldRender
        layers.shade.isHidden = !shouldRender
        let backgroundPlayer = shouldRender ? player : nil
        if layers.background.player !== backgroundPlayer {
            layers.background.player = backgroundPlayer
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
            updateBackground(in: activeLayers, for: connectedPlayer)
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
                self.updateBackground(in: self.activeLayers, for: self.connectedPlayer)
            }
        }
        updateBackground(in: activeLayers, for: connectedPlayer)
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
        updateBackgrounds()
        guard !bounds.isEmpty else {
            return
        }

        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        layer?.contentsScale = backingScale
        videoContainer.frame = bounds
        let area = videoContainer.bounds
        let workSize = backgroundWorkSize(for: area.size)
        let transform = CATransform3DMakeScale(
            area.width / workSize.width * DesktopBlurRenderingPolicy.overscanScale,
            area.height / workSize.height * DesktopBlurRenderingPolicy.overscanScale,
            1
        )
        for layers in [activeLayers, spareLayers] {
            layers.container.frame = area
            layers.foreground.contentsScale = backingScale
            layers.foreground.frame = area
            layers.shade.frame = area
            layers.background.bounds = CGRect(origin: .zero, size: workSize)
            layers.background.position = CGPoint(x: area.midX, y: area.midY)
            layers.background.transform = transform
        }
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
            "videoGravity": NSNull(),
            "zPosition": NSNull()
        ]
    }
}

extension DesktopPlayerLayerSurfaceView: AVPlayerTransitionSurface {
    func prepareTransition(to player: AVPlayer) {
        clearDesktopEffects()
        cancelPreparedTransition()
        preparedTransitionPlayer = player
        bind(player, to: spareLayers)
    }

    func commitPreparedTransition(duration: TimeInterval) {
        guard let incomingPlayer = preparedTransitionPlayer else { return }
        preparedTransitionPlayer = nil

        // Keep the exact layers that passed the first-frame check on screen.
        // Rebinding their player at fade completion resets display readiness.
        let outgoing = activeLayers
        activeLayers = spareLayers
        spareLayers = outgoing
        activeLayers.container.zPosition = 1
        outgoing.container.zPosition = 0
        activeLayers.container.opacity = 1
        observeActivePlayer(incomingPlayer)

        guard duration > 0 else {
            retireSpareLayers()
            refreshHoverWhenReady()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = Float.zero
        animation.toValue = Float(1)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        activeLayers.container.add(
            animation,
            forKey: PlaybackSurfaceTransitionAnimationKey.incomingOpacity
        )

        let cleanup = DispatchWorkItem { [weak self, weak outgoing] in
            guard let self, spareLayers === outgoing else { return }
            retireSpareLayers()
            transitionCleanupWorkItem = nil
            refreshHoverWhenReady()
        }
        transitionCleanupWorkItem = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }

    func cancelPreparedTransition() {
        transitionCleanupWorkItem?.cancel()
        transitionCleanupWorkItem = nil
        preparedTransitionPlayer = nil
        activeLayers.container.removeAnimation(
            forKey: PlaybackSurfaceTransitionAnimationKey.incomingOpacity
        )
        retireSpareLayers()
    }

    private func retireSpareLayers() {
        spareLayers.container.opacity = 0
        spareLayers.foreground.player = nil
        spareLayers.background.player = nil
    }
}

@MainActor
final class DesktopPlayerLayerSurfaceGroup: AVPlayerTransitionSurface {
    let id: PlaybackSurfaceID

    var isReadyForDisplay: Bool {
        !displaySurfaces.isEmpty
            && displaySurfaces.allSatisfy(\.isReadyForDisplay)
    }

    private(set) var displaySurfaces: [DesktopPlayerLayerSurfaceView] = []
    private(set) var isEnergyConstrained = false
    private weak var connectedPlayer: AVPlayer?
    private weak var preparedTransitionPlayer: AVPlayer?

    init(id: PlaybackSurfaceID) {
        self.id = id
    }

    func connect(to player: AVPlayer?) {
        cancelPreparedTransition()
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
                if let preparedTransitionPlayer {
                    $0.prepareTransition(to: preparedTransitionPlayer)
                }
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

    func prepareTransition(to player: AVPlayer) {
        preparedTransitionPlayer = player
        displaySurfaces.forEach { $0.prepareTransition(to: player) }
    }

    func commitPreparedTransition(duration: TimeInterval) {
        guard let preparedTransitionPlayer else {
            return
        }
        connectedPlayer = preparedTransitionPlayer
        self.preparedTransitionPlayer = nil
        displaySurfaces.forEach {
            $0.commitPreparedTransition(duration: duration)
        }
    }

    func cancelPreparedTransition() {
        preparedTransitionPlayer = nil
        displaySurfaces.forEach { $0.cancelPreparedTransition() }
    }
}
