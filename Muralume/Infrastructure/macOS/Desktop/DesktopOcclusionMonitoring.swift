import AppKit

enum DesktopOcclusionPolicy {
    static let debounceNanoseconds: UInt64 = 750_000_000
    static let recoveryDebounceNanoseconds: UInt64 = 150_000_000
    static let refreshIntervalNanoseconds: UInt64 = 200_000_000
    static let probeColumnCount = 4
    static let probeRowCount = 3
    static let probeScale: CGFloat = 0.5
    static let requiredOccludedProbeNumerator = 3
    static let requiredOccludedProbeDenominator = 4
    static let revealedWindowAlphaThreshold: CGFloat = 0.99
    static let maximumHorizontalInset: CGFloat = 48
    static let minimumHorizontalInset: CGFloat = 24
    static let maximumVerticalInset: CGFloat = 36
    static let minimumVerticalInset: CGFloat = 16
    static let proportionalInset: CGFloat = 0.02
}

enum DesktopOcclusionGeometry {
    static func effectiveDesktopRect(
        visibleFrame: NSRect,
        screenFrame: NSRect
    ) -> NSRect {
        let visibleRect = visibleFrame.intersection(screenFrame)
        guard !visibleRect.isNull,
              visibleRect.width > 0,
              visibleRect.height > 0 else {
            return screenFrame
        }
        let horizontalInset = min(
            DesktopOcclusionPolicy.maximumHorizontalInset,
            max(
                DesktopOcclusionPolicy.minimumHorizontalInset,
                visibleRect.width * DesktopOcclusionPolicy.proportionalInset
            )
        )
        let verticalInset = min(
            DesktopOcclusionPolicy.maximumVerticalInset,
            max(
                DesktopOcclusionPolicy.minimumVerticalInset,
                visibleRect.height * DesktopOcclusionPolicy.proportionalInset
            )
        )
        let insetRect = visibleRect.insetBy(
            dx: horizontalInset,
            dy: verticalInset
        )
        guard insetRect.width > 0, insetRect.height > 0 else {
            return visibleRect
        }
        return insetRect
    }

    static func effectiveDesktopRect(for screen: NSScreen) -> NSRect {
        effectiveDesktopRect(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame
        )
    }

    static func probeRects(in effectiveDesktopRect: NSRect) -> [NSRect] {
        guard effectiveDesktopRect.width > 0,
              effectiveDesktopRect.height > 0 else {
            return []
        }
        let columnCount = DesktopOcclusionPolicy.probeColumnCount
        let rowCount = DesktopOcclusionPolicy.probeRowCount
        let cellWidth = effectiveDesktopRect.width / CGFloat(columnCount)
        let cellHeight = effectiveDesktopRect.height / CGFloat(rowCount)
        let probeWidth = cellWidth * DesktopOcclusionPolicy.probeScale
        let probeHeight = cellHeight * DesktopOcclusionPolicy.probeScale
        let horizontalOffset = (cellWidth - probeWidth) / 2
        let verticalOffset = (cellHeight - probeHeight) / 2

        return (0..<rowCount).flatMap { row in
            (0..<columnCount).map { column in
                NSRect(
                    x: effectiveDesktopRect.minX
                        + CGFloat(column) * cellWidth
                        + horizontalOffset,
                    y: effectiveDesktopRect.minY
                        + CGFloat(row) * cellHeight
                        + verticalOffset,
                    width: probeWidth,
                    height: probeHeight
                )
            }
        }
    }
}

enum DesktopOcclusionSampling {
    static func isEffectivelyOccluded(
        probeVisibility: [Bool]
    ) -> Bool {
        let expectedProbeCount = DesktopOcclusionPolicy.probeColumnCount
            * DesktopOcclusionPolicy.probeRowCount
        guard probeVisibility.count == expectedProbeCount else {
            return false
        }
        let occludedProbeCount = probeVisibility.lazy.filter { !$0 }.count
        return occludedProbeCount
            * DesktopOcclusionPolicy.requiredOccludedProbeDenominator
            >= expectedProbeCount
                * DesktopOcclusionPolicy.requiredOccludedProbeNumerator
    }
}

@MainActor
final class DesktopOcclusionProbeWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
