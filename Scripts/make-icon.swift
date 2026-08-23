#!/usr/bin/env swift

// Renders Resources/icon-1024.png, the single source image that build-app.sh
// downsamples into an .iconset for iconutil. Run only when the icon changes.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon-1024.png"

guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("failed to create bitmap context\n".utf8))
    exit(1)
}

// macOS icons sit inside a rounded square inset from the canvas edge; ~0.18 of
// the width is the platform's corner radius.
let inset = size * 0.08
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = CGPath(
    roundedRect: rect,
    cornerWidth: rect.width * 0.22,
    cornerHeight: rect.width * 0.22,
    transform: nil
)

context.saveGState()
context.addPath(squircle)
context.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1),
        CGColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)
context.restoreGState()

// Concentric arcs suggesting a waveform, with a filled play triangle at the centre.
let centre = CGPoint(x: size * 0.44, y: size / 2)
// Dracula red (#FF5555), the ANSI red the terminal theme uses — see Theme.draculaPalette.
let accent = CGColor(red: 0xFF / 255.0, green: 0x55 / 255.0, blue: 0x55 / 255.0, alpha: 1)

context.setStrokeColor(accent)
context.setLineCap(.round)
for (index, radius) in [0.17, 0.26, 0.35].enumerated() {
    context.setLineWidth(size * 0.032)
    context.setAlpha(1.0 - Double(index) * 0.28)
    context.addArc(
        center: centre,
        radius: size * radius,
        startAngle: -.pi / 3.4,
        endAngle: .pi / 3.4,
        clockwise: false
    )
    context.strokePath()
}

context.setAlpha(1)
context.setFillColor(accent)
let triangle = CGMutablePath()
let side = size * 0.16
triangle.move(to: CGPoint(x: centre.x - side * 0.45, y: centre.y + side))
triangle.addLine(to: CGPoint(x: centre.x - side * 0.45, y: centre.y - side))
triangle.addLine(to: CGPoint(x: centre.x + side * 0.95, y: centre.y))
triangle.closeSubpath()
context.addPath(triangle)
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("failed to render image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, "public.png" as CFString, 1, nil
) else {
    FileHandle.standardError.write(Data("failed to create PNG destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("failed to write PNG\n".utf8))
    exit(1)
}
print("wrote \(outputPath)")
