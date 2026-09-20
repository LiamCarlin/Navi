import AppKit

// Renders Navi's app icon: the menu-bar `sparkle` SF Symbol in Navi purple on a
// white macOS squircle. Geometry follows Apple's macOS icon template — the tile
// fills ~82% of the canvas with a soft drop shadow in the remaining margin.
//
//   swift scripts/make-icon.swift Navi/Resources/Assets.xcassets/AppIcon.appiconset
func render(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    // Draw into an explicit 1x bitmap so every PNG has exactly `size` pixels
    // regardless of the host display's backing scale.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Tile
    let tileSide = s * 824.0 / 1024.0
    let tileRect = NSRect(x: (s - tileSide) / 2, y: (s - tileSide) / 2 + s * 0.01, width: tileSide, height: tileSide)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileSide * 0.2237, yRadius: tileSide * 0.2237)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.white.setFill()
    tile.fill()
    ctx.restoreGState()

    // Very slight cool-white gradient so the tile isn't a flat sheet, plus a hairline edge.
    NSGradient(colors: [NSColor.white,
                        NSColor(calibratedRed: 0.965, green: 0.955, blue: 0.985, alpha: 1)])!
        .draw(in: tile, angle: -90)
    NSColor.black.withAlphaComponent(0.06).setStroke()
    tile.lineWidth = max(1, s * 0.004)
    tile.stroke()

    // Sparkle glyph — the same SF Symbol the menu bar uses.
    let cfg = NSImage.SymbolConfiguration(pointSize: tileSide * 0.5, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let glyphSide = tileSide * 0.56
    let aspect = symbol.size.width / symbol.size.height
    let glyphSize = aspect >= 1 ? NSSize(width: glyphSide, height: glyphSide / aspect)
                                : NSSize(width: glyphSide * aspect, height: glyphSide)
    let glyphRect = NSRect(x: tileRect.midX - glyphSize.width / 2,
                           y: tileRect.midY - glyphSize.height / 2,
                           width: glyphSize.width, height: glyphSize.height).integral // pixel-aligned so the mask edge has no partial pixels

    // Clip to the symbol's coverage, then paint the purple gradient through it.
    // Symbol images only render into RGBA contexts, so draw there and lift the
    // alpha channel into a DeviceGray mask (white = visible).
    let maskW = Int(glyphRect.width.rounded(.up)), maskH = Int(glyphRect.height.rounded(.up))
    let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: maskW, pixelsHigh: maskH,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rgba.size = NSSize(width: maskW, height: maskH)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
    symbol.draw(in: NSRect(x: 0, y: 0, width: maskW, height: maskH))
    NSGraphicsContext.restoreGraphicsState()
    let maskRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: maskW, pixelsHigh: maskH,
                                   bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
    let src = rgba.bitmapData!, dst = maskRep.bitmapData!
    for row in 0..<maskH {
        for col in 0..<maskW {
            dst[row * maskRep.bytesPerRow + col] = src[row * rgba.bytesPerRow + col * 4 + 3]
        }
    }

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.02,
                  color: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.95, alpha: 0.35).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // so the glow follows the clipped shape
    ctx.clip(to: glyphRect, mask: maskRep.cgImage!)
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.92, alpha: 1),   // indigo
                        NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.94, alpha: 1),   // purple
                        NSColor(calibratedRed: 0.80, green: 0.36, blue: 0.86, alpha: 1)])! // violet-pink
        .draw(in: glyphRect, angle: -50)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (px, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),
                   (128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),
                   (512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    let png = render(size: px).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("icons written to \(out)")
