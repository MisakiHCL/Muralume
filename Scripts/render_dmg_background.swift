#!/usr/bin/env swift

import AppKit
import Foundation

private enum Canvas {
    static let width = 660
    static let height = 412
    static let backgroundColor = NSColor(
        srgbRed: 244.0 / 255.0,
        green: 243.0 / 255.0,
        blue: 239.0 / 255.0,
        alpha: 1.0
    )
}

private enum Arrow {
    static let centerX = 330.0
    // Finder positions use a top-left origin; AppKit bitmap drawing uses bottom-left.
    static let centerY = Double(Canvas.height) - 196.0
    static let shaftHalfWidth = 38.0
    static let headLength = 20.0
    static let headHalfHeight = 20.0
    static let lineWidth = 3.0
    static let color = NSColor(
        srgbRed: 44.0 / 255.0,
        green: 43.0 / 255.0,
        blue: 48.0 / 255.0,
        alpha: 0.78
    )
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "--output" else {
    fail("Usage: render_dmg_background.swift --output <path>")
}

let outputURL = URL(fileURLWithPath: arguments[2])
let outputDirectory = outputURL.deletingLastPathComponent()

do {
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )
} catch {
    fail("Unable to create the output directory: \(error.localizedDescription)")
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Canvas.width,
    pixelsHigh: Canvas.height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("Unable to create the background bitmap.")
}

bitmap.size = NSSize(width: Canvas.width, height: Canvas.height)

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("Unable to create the background graphics context.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

Canvas.backgroundColor.setFill()
NSBezierPath(
    rect: NSRect(x: 0, y: 0, width: Canvas.width, height: Canvas.height)
).fill()

let arrowPath = NSBezierPath()
arrowPath.lineWidth = Arrow.lineWidth
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.move(
    to: NSPoint(
        x: Arrow.centerX - Arrow.shaftHalfWidth,
        y: Arrow.centerY
    )
)
arrowPath.line(
    to: NSPoint(
        x: Arrow.centerX + Arrow.shaftHalfWidth,
        y: Arrow.centerY
    )
)
arrowPath.move(
    to: NSPoint(
        x: Arrow.centerX + Arrow.shaftHalfWidth - Arrow.headLength,
        y: Arrow.centerY - Arrow.headHalfHeight
    )
)
arrowPath.line(
    to: NSPoint(
        x: Arrow.centerX + Arrow.shaftHalfWidth,
        y: Arrow.centerY
    )
)
arrowPath.line(
    to: NSPoint(
        x: Arrow.centerX + Arrow.shaftHalfWidth - Arrow.headLength,
        y: Arrow.centerY + Arrow.headHalfHeight
    )
)
Arrow.color.setStroke()
arrowPath.stroke()

graphicsContext.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(
    using: NSBitmapImageRep.FileType.png,
    properties: [:]
) else {
    fail("Unable to encode the background as PNG.")
}

do {
    try pngData.write(to: outputURL, options: Data.WritingOptions.atomic)
} catch {
    fail("Unable to write the background: \(error.localizedDescription)")
}
