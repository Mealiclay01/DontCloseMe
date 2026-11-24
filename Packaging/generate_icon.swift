#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output_iconset_dir>\n", stderr)
    exit(1)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let inset = rect.insetBy(dx: s * 0.06, dy: s * 0.06)
    let bgPath = NSBezierPath(roundedRect: inset, xRadius: s * 0.21, yRadius: s * 0.21)

    // Matte dark charcoal industrial Mac app icon with sharp crimson alert accent
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    ])!
    grad.draw(in: bgPath, angle: -90)

    NSColor.white.withAlphaComponent(0.14).setStroke()
    bgPath.lineWidth = max(1.5, s * 0.015)
    bgPath.stroke()

    // Crimson corner alert badge
    let badgeRadius = s * 0.12
    let badgeCenter = NSPoint(x: s * 0.76, y: s * 0.76)
    let badgePath = NSBezierPath(
        ovalIn: NSRect(
            x: badgeCenter.x - badgeRadius,
            y: badgeCenter.y - badgeRadius,
            width: badgeRadius * 2,
            height: badgeRadius * 2
        )
    )
    NSColor(calibratedRed: 0.92, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
    badgePath.fill()

    // Laptop silhouette
    if let symbol = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let configured = symbol.withSymbolConfiguration(cfg) {
            let imgSize = configured.size
            let scale = min((s * 0.64) / max(1, imgSize.width), (s * 0.50) / max(1, imgSize.height))
            let drawSize = NSSize(width: imgSize.width * scale, height: imgSize.height * scale)
            let drawRect = NSRect(
                x: (s - drawSize.width) / 2.0,
                y: (s - drawSize.height) / 2.0 - s * 0.03,
                width: drawSize.width,
                height: drawSize.height
            )
            configured.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    let data = renderIcon(size: px)
    try data.write(to: iconsetURL.appendingPathComponent(filename))
}
print("Generated iconset at \(iconsetURL.path)")
