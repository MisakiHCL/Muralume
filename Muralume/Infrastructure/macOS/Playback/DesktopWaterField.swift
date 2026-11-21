import CoreImage
import Foundation

enum DesktopWaterInput {
    case click
    case movement
}

/// A surface shared by all disturbances on one display. Each outward wave contributes a
/// signed height. Core Image refracts the video using the slope of the combined surface.
struct DesktopWaterField {
    struct Frame {
        let region: CGRect
        let displacementImage: CIImage
        let activityMask: CGImage
    }

    // CIDisplacementDistortion samples the gradient of its red channel. Scale converts
    // a per-point height gradient to an offset in the original video.
    static let displacementScale: Float = 640

    private struct Pulse {
        let kind: DesktopWaterInput
        let center: CGPoint
        let start: TimeInterval
        let duration: TimeInterval
        let travel: CGFloat
        let wavelength: CGFloat
        let halfWidth: CGFloat
        let strength: CGFloat

        init(_ kind: DesktopWaterInput, point: CGPoint, visible: CGRect, start: TimeInterval) {
            self.kind = kind
            self.center = point
            self.start = start
            switch kind {
            case .click:
                duration = 1.4
                travel = min(360, max(200, min(visible.width, visible.height) * 0.34))
                wavelength = 52
                halfWidth = 55
                strength = 23
            case .movement:
                duration = 0.63
                travel = 62
                wavelength = 28
                halfWidth = 24
                strength = 7
            }
        }

        func front(at time: TimeInterval) -> CGFloat {
            travel * CGFloat((time - start) / duration)
        }

        func support(at time: TimeInterval) -> CGRect {
            let extent = front(at: time) + halfWidth
            return CGRect(x: center.x - extent, y: center.y - extent,
                          width: 2 * extent, height: 2 * extent)
        }
    }

    private var pulses: [Pulse] = []
    private var lastMovement: (point: CGPoint, time: TimeInterval)?

    mutating func disturb(_ input: DesktopWaterInput, at point: CGPoint, in visibleVideo: CGRect, time: TimeInterval) {
        guard time.isFinite, !visibleVideo.isInfinite, visibleVideo.contains(point) else { return }
        reap(at: time)
        if input == .movement {
            if let lastMovement, time - lastMovement.time < 0.35 {
                guard time - lastMovement.time >= 0.031,
                      hypot(point.x - lastMovement.point.x, point.y - lastMovement.point.y) >= 18 else { return }
            }
            lastMovement = (point, time)
        }
        // Reserve the click budget even while the pointer is moving continuously.
        let limit = input == .click ? 8 : 16
        if pulses.lazy.filter({ $0.kind == input }).count >= limit,
           let oldest = pulses.firstIndex(where: { $0.kind == input }) {
            pulses.remove(at: oldest)
        }
        pulses.append(Pulse(input, point: point, visible: visibleVideo, start: time))
    }

    mutating func frame(in visibleVideo: CGRect, at time: TimeInterval) -> Frame? {
        reap(at: time)
        guard !pulses.isEmpty, !visibleVideo.isInfinite, !visibleVideo.isEmpty else { return nil }
        let spacing = max(3, ceil(max(visibleVideo.width / 520, visibleVideo.height / 360)))
        var support = CGRect.null
        for pulse in pulses where time >= pulse.start {
            support = support.union(pulse.support(at: time))
        }
        guard !support.isNull else { return nil }
        // Leave neutral texels around the outermost ring for bilinear interpolation.
        let region = support.insetBy(dx: -2 * spacing, dy: -2 * spacing)
            .integral.intersection(visibleVideo)
        guard !region.isEmpty else { return nil }
        let columns = max(1, Int(ceil(region.width / spacing)))
        let rows = max(1, Int(ceil(region.height / spacing)))
        let stepX = region.width / CGFloat(columns)
        let stepY = region.height / CGFloat(rows)
        var heights = [Float](repeating: 0.5, count: rows * columns)

        for pulse in pulses where time >= pulse.start {
            addHeight(of: pulse, at: time, region: region, columns: columns, rows: rows,
                     stepX: stepX, stepY: stepY, to: &heights)
        }
        let horizontalRoom = (0..<columns).map { column in
            let x = region.minX + (CGFloat(column) + 0.5) * stepX
            return min(x - visibleVideo.minX, visibleVideo.maxX - x)
        }
        Self.fadeEdges(&heights, horizontalRoom: horizontalRoom, region: region, visible: visibleVideo,
                       columns: columns, rows: rows, stepX: stepX, stepY: stepY)
        guard let activityMask = Self.activityMask(
            heights: heights, columns: columns, rows: rows, region: region, visible: visibleVideo,
            horizontalRoom: horizontalRoom, stepX: stepX, stepY: stepY
        ) else { return nil }

        let bitmap = CIImage(
            bitmapData: heights.withUnsafeBytes { Data($0) },
            bytesPerRow: columns * MemoryLayout<Float>.stride,
            size: CGSize(width: columns, height: rows), format: .Lf, colorSpace: nil
        )
        let coordinates = CGAffineTransform(a: stepX, b: 0, c: 0, d: stepY, tx: region.minX, ty: region.minY)
        // The distortion filter takes neighboring height samples even on the final
        // visible pixel. Keep a finite flat guard band beyond the compositor layer.
        let guardBand = region.insetBy(dx: -4 * spacing, dy: -4 * spacing)
        let image = bitmap.clampedToExtent().transformed(by: coordinates).cropped(to: guardBand)
        return Frame(region: region, displacementImage: image, activityMask: activityMask)
    }

    // Only the outer band can bend across a letterbox boundary. The middle of
    // each row is already at full strength and need not be visited again.
    private static func fadeEdges(
        _ heights: inout [Float], horizontalRoom: [CGFloat], region: CGRect, visible: CGRect,
        columns: Int, rows: Int, stepX: CGFloat, stepY: CGFloat
    ) {
        let fade: CGFloat = 40
        guard !visible.insetBy(dx: fade + stepX, dy: fade + stepY).contains(region) else { return }
        let sideColumns = horizontalRoom.indices.filter { horizontalRoom[$0] - stepX < fade }
        for row in 0..<rows {
            let y = region.maxY - (CGFloat(row) + 0.5) * stepY
            let roomY = min(y - visible.minY, visible.maxY - y) - stepY
            func attenuate(_ column: Int) {
                let distance = min(horizontalRoom[column] - stepX, roomY)
                let t = Float(max(0, min(1, distance / fade)))
                let index = row * columns + column
                heights[index] = 0.5 + (heights[index] - 0.5) * t * t * (3 - 2 * t)
            }
            if roomY < fade {
                for column in 0..<columns { attenuate(column) }
            } else {
                for column in sideColumns { attenuate(column) }
            }
        }
    }

    private static func activityMask(
        heights: [Float], columns: Int, rows: Int, region: CGRect, visible: CGRect,
        horizontalRoom: [CGFloat], stepX: CGFloat, stepY: CGFloat
    ) -> CGImage? {
        // Quartz image masks encode full coverage as 0 and transparency as 255.
        var mask = [UInt8](repeating: 255, count: heights.count)
        let xScale = displacementScale / Float(stepX)
        let yScale = displacementScale / Float(stepY)
        for row in 0..<rows {
            let py = region.maxY - (CGFloat(row) + 0.5) * stepY
            let verticalRoom = Float(min(visible.maxY - py, py - visible.minY))
            for column in 0..<columns {
                let index = row * columns + column
                let height = heights[index]
                let left = heights[index - (column > 0 ? 1 : 0)]
                let right = heights[index + (column + 1 < columns ? 1 : 0)]
                let above = heights[index - (row > 0 ? columns : 0)]
                let below = heights[index + (row + 1 < rows ? columns : 0)]
                let dx = max(abs(height - left), abs(right - height)) * xScale
                let dy = max(abs(height - above), abs(below - height)) * yScale
                guard dx > 0 || dy > 0 else { continue }
                let margin = min((Float(horizontalRoom[column]) - dx) / Float(stepX), (verticalRoom - dy) / Float(stepY))
                let opacity = max(0, min(1, margin)) * min(1, (dx + dy) / 1.5)
                mask[index] = 255 - UInt8(opacity * 255)
            }
        }
        let data = mask.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(maskWidth: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: columns, provider: provider, decode: nil, shouldInterpolate: true)
    }

    private mutating func reap(at time: TimeInterval) {
        pulses.removeAll { time - $0.start >= $0.duration }
        if pulses.isEmpty { lastMovement = nil }
    }

    private func addHeight(
        of pulse: Pulse, at time: TimeInterval, region: CGRect, columns: Int, rows: Int,
        stepX: CGFloat, stepY: CGFloat, to heights: inout [Float]
    ) {
        let front = pulse.front(at: time)
        let minRadius = max(0, front - pulse.halfWidth)
        let maxRadius = front + pulse.halfWidth
        let minSquared = minRadius * minRadius
        let maxSquared = maxRadius * maxRadius
        let controlX = pulse.center.x - region.minX
        let controlY = pulse.center.y - region.minY
        let firstCol = max(0, Int(floor((controlX - maxRadius) / stepX)))
        let endCol = min(columns, Int(ceil((controlX + maxRadius) / stepX)))
        let firstRow = max(0, Int(floor((controlY - maxRadius) / stepY)))
        let endRow = min(rows, Int(ceil((controlY + maxRadius) / stepY)))
        guard firstCol < endCol, firstRow < endRow else { return }

        // The compact cosine packet is radially symmetric. Tabulate it per point of
        // radius, then sample that profile into the common height texture.
        let tableStart = floor(minRadius)
        let radialFrequency = 2 * CGFloat.pi / pulse.wavelength
        let life = CGFloat((time - pulse.start) / pulse.duration)
        let gain = pulse.strength * (1 - life * life) * (1 - 0.35 * life)
            / (CGFloat(Self.displacementScale) * radialFrequency)
        let tableCount = Int(ceil(maxRadius) - tableStart) + 2
        let profile: [Float] = (0..<tableCount).map { index in
            let radius = tableStart + CGFloat(index)
            let delta = radius - front
            let u = delta / pulse.halfWidth
            guard abs(u) < 1 else { return 0 }
            let envelope = 1 - u * u
            let phase = delta * radialFrequency
            return Float(gain * cos(phase) * envelope * envelope)
        }

        for y in firstRow..<endRow {
            let dy = (CGFloat(y) + 0.5) * stepY - controlY
            // CIImage bitmapData starts at the top, but Core Image and AppKit
            // coordinates on this backing layer both count upward from the bottom.
            let rowStart = (rows - 1 - y) * columns
            for x in firstCol..<endCol {
                let dx = (CGFloat(x) + 0.5) * stepX - controlX
                let squared = dx * dx + dy * dy
                guard squared >= minSquared, squared < maxSquared else { continue }
                let radialIndex = sqrt(squared) - tableStart
                let index = Int(radialIndex)
                let fraction = Float(radialIndex - CGFloat(index))
                let height = profile[index] + (profile[index + 1] - profile[index]) * fraction
                heights[rowStart + x] += height
            }
        }
    }
}
