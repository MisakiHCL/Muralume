import AppKit
import SwiftUI

struct MuralumeSlider: NSViewRepresentable {
    enum Kind {
        case timeline
        case volume
    }

    @Environment(\.isEnabled) private var isEnabled
    @Binding private var value: Double

    private let bounds: ClosedRange<Double>
    private let kind: Kind
    private let accessibilityIdentifier: String?
    private let onEditingChanged: (Bool) -> Void

    init(
        value: Binding<Double>,
        in bounds: ClosedRange<Double>,
        kind: Kind,
        accessibilityIdentifier: String? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.bounds = bounds
        self.kind = kind
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            value: $value,
            onEditingChanged: onEditingChanged
        )
    }

    func makeNSView(context: Context) -> MuralumeNativeSlider {
        let slider = MuralumeNativeSlider(frame: .zero)
        slider.cell = MuralumeSliderCell(kind: kind)
        slider.sliderType = .linear
        slider.minValue = bounds.lowerBound
        slider.maxValue = bounds.upperBound
        slider.doubleValue = clampedValue
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.isEnabled = isEnabled
        slider.onEditingChanged = context.coordinator.editingChanged
        slider.setAccessibilityIdentifier(accessibilityIdentifier)
        return slider
    }

    func updateNSView(
        _ nsView: MuralumeNativeSlider,
        context: Context
    ) {
        context.coordinator.value = $value
        context.coordinator.onEditingChanged = onEditingChanged
        nsView.minValue = bounds.lowerBound
        nsView.maxValue = bounds.upperBound
        nsView.isEnabled = isEnabled
        nsView.onEditingChanged = context.coordinator.editingChanged
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)

        if let sliderCell = nsView.cell as? MuralumeSliderCell {
            sliderCell.kind = kind
        }

        if !nsView.isUserInteracting,
           nsView.doubleValue != clampedValue {
            nsView.doubleValue = clampedValue
        }
        nsView.needsDisplay = true
    }

    private var clampedValue: Double {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void

        init(
            value: Binding<Double>,
            onEditingChanged: @escaping (Bool) -> Void
        ) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }

        @objc
        func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }

        func editingChanged(_ isEditing: Bool) {
            onEditingChanged(isEditing)
        }
    }
}

@MainActor
final class MuralumeNativeSlider: NSSlider {
    private(set) var isUserInteracting = false
    var onEditingChanged: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: MuralumeTheme.Size.sliderHitTargetHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        isUserInteracting = true
        onEditingChanged?(true)
        needsDisplay = true
        defer {
            isUserInteracting = false
            onEditingChanged?(false)
            needsDisplay = true
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        needsDisplay = true
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        needsDisplay = true
        return didResignFirstResponder
    }
}

@MainActor
private final class MuralumeSliderCell: NSSliderCell {
    var kind: MuralumeSlider.Kind {
        didSet {
            controlView?.needsDisplay = true
        }
    }

    init(kind: MuralumeSlider.Kind) {
        self.kind = kind
        super.init()
    }

    required init(coder: NSCoder) {
        kind = .timeline
        super.init(coder: coder)
    }

    override func drawBar(
        inside rect: NSRect,
        flipped: Bool
    ) {
        let trackRect = MuralumeSliderGeometry.trackRect(
            in: rect
        )

        drawCapsule(
            in: trackRect,
            color: palette.track
        )

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width * normalizedValue,
            height: trackRect.height
        )
        drawCapsule(
            in: fillRect,
            color: palette.fill
        )
    }

    override func drawKnob(_ knobRect: NSRect) {
        let thumbRect = MuralumeSliderGeometry.thumbRect(
            in: knobRect,
            isInteracting: isUserInteracting
        )
        let thumbPath = NSBezierPath(ovalIn: thumbRect)

        if showsFirstResponder {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            thumbPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        palette.thumb.setFill()
        thumbPath.fill()
    }

    private var normalizedValue: CGFloat {
        let range = maxValue - minValue
        guard range > 0 else {
            return 0
        }
        return CGFloat(min(max((doubleValue - minValue) / range, 0), 1))
    }

    private var isUserInteracting: Bool {
        (controlView as? MuralumeNativeSlider)?.isUserInteracting == true
    }

    private var palette: Palette {
        switch kind {
        case .timeline:
            Palette(
                fill: NSColor(
                    MuralumeTheme.Colors.timelineSliderFill
                ),
                track: NSColor(
                    MuralumeTheme.Colors.timelineSliderTrack
                ),
                thumb: NSColor(
                    MuralumeTheme.Colors.sliderThumb
                )
            )
        case .volume:
            Palette(
                fill: NSColor(
                    MuralumeTheme.Colors.volumeSliderFill
                ),
                track: NSColor(
                    MuralumeTheme.Colors.volumeSliderTrack
                ),
                thumb: NSColor(
                    MuralumeTheme.Colors.sliderThumb
                )
            )
        }
    }

    private func drawCapsule(
        in rect: NSRect,
        color: NSColor
    ) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
        .fill()
    }

    private struct Palette {
        let fill: NSColor
        let track: NSColor
        let thumb: NSColor
    }
}

enum MuralumeSliderGeometry {
    static func trackRect(in rect: NSRect) -> NSRect {
        let horizontalInset =
            MuralumeTheme.Size.sliderActiveThumbDiameter / 2
        return NSRect(
            x: rect.minX + horizontalInset,
            y: rect.midY
                - MuralumeTheme.Size.sliderTrackHeight / 2,
            width: max(0, rect.width - horizontalInset * 2),
            height: MuralumeTheme.Size.sliderTrackHeight
        )
    }

    static func thumbRect(
        in knobRect: NSRect,
        isInteracting: Bool
    ) -> NSRect {
        let diameter = isInteracting
            ? MuralumeTheme.Size.sliderActiveThumbDiameter
            : MuralumeTheme.Size.sliderThumbDiameter
        return NSRect(
            x: knobRect.midX - diameter / 2,
            y: knobRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }
}
