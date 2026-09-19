import AppKit

// Renders Navi's app icon: deep indigo→violet glass square with a white sparkle.
func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.42, alpha: 1),
                                   NSColor(calibratedRed: 0.38, green: 0.30, blue: 0.95, alpha: 1),
                                   NSColor(calibratedRed: 0.62, green: 0.55, blue: 1.0, alpha: 1)])!
    grad.draw(in: path, angle: 60)
    // Inner highlight
    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = s * 0.012
    path.stroke()
    // Sparkle (4-point star with soft glow)
    func star(center c: CGPoint, r: CGFloat, thin: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + thin, y: c.y + thin), controlPoint2: CGPoint(x: c.x + thin, y: c.y + thin))
        p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + thin, y: c.y - thin), controlPoint2: CGPoint(x: c.x + thin, y: c.y - thin))
        p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - thin, y: c.y - thin), controlPoint2: CGPoint(x: c.x - thin, y: c.y - thin))
        p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - thin, y: c.y + thin), controlPoint2: CGPoint(x: c.x - thin, y: c.y + thin))
        p.close()
        return p
    }
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.08, color: NSColor.white.withAlphaComponent(0.6).cgColor)
    NSColor.white.setFill()
    star(center: CGPoint(x: s * 0.5, y: s * 0.52), r: s * 0.30, thin: s * 0.055).fill()
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.85).setFill()
    star(center: CGPoint(x: s * 0.74, y: s * 0.74), r: s * 0.09, thin: s * 0.018).fill()
    star(center: CGPoint(x: s * 0.27, y: s * 0.28), r: s * 0.06, thin: s * 0.012).fill()
    img.unlockFocus()
    return img
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (px, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),
                   (128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),
                   (512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    let img = render(size: px)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("icons written to \(out)")
