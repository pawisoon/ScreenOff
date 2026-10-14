// Renders the app icon and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background: Apple's macOS icon grid (824pt body, ~185pt corner radius on a 1024 canvas).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = color(0x000000, 0.35)
    drop.shadowOffset = NSSize(width: 0, height: -12)
    drop.shadowBlurRadius = 24
    drop.set()
    color(0x15132E).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x2A2660), ending: color(0x0C0B1A))!.draw(in: squircle, angle: -90)

    // Stand.
    let neck = NSBezierPath(roundedRect: NSRect(x: 472, y: 292, width: 80, height: 96), xRadius: 10, yRadius: 10)
    NSGradient(starting: color(0x9EA3AE), ending: color(0x6B707C))!.draw(in: neck, angle: -90)
    let base = NSBezierPath(roundedRect: NSRect(x: 372, y: 270, width: 280, height: 34), xRadius: 17, yRadius: 17)
    NSGradient(starting: color(0xD5D8DF), ending: color(0x9298A4))!.draw(in: base, angle: -90)

    // Bezel.
    let bezelRect = NSRect(x: 202, y: 372, width: 620, height: 420)
    let bezel = NSBezierPath(roundedRect: bezelRect, xRadius: 44, yRadius: 44)
    NSGradient(starting: color(0xE4E7EC), ending: color(0xA3A8B3))!.draw(in: bezel, angle: -90)

    // Screen: off, nearly black.
    let screenRect = bezelRect.insetBy(dx: 26, dy: 26)
    let screen = NSBezierPath(roundedRect: screenRect, xRadius: 22, yRadius: 22)
    NSGradient(starting: color(0x1A1A24), ending: color(0x050508))!.draw(in: screen, angle: -90)

    // Power glyph with a soft glow.
    let center = NSPoint(x: screenRect.midX, y: screenRect.midY - 6)
    let r: CGFloat = 92
    let glyph = NSBezierPath()
    glyph.appendArc(withCenter: center, radius: r, startAngle: 125, endAngle: 55, clockwise: false)
    glyph.move(to: NSPoint(x: center.x, y: center.y + 8))
    glyph.line(to: NSPoint(x: center.x, y: center.y + r + 22))
    glyph.lineWidth = 28
    glyph.lineCapStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x5EEAD4, 0.85)
    glow.shadowBlurRadius = 40
    glow.shadowOffset = .zero
    glow.set()
    color(0x7FF5E0).setStroke()
    glyph.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try render().representation(using: .png, properties: [:])!.write(to: master)
try fm.copyItem(at: master, to: root.appendingPathComponent("Resources/AppIcon.png").replacingExisting())

func shell(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: args[0], code: Int(p.terminationStatus)) }
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] where !(base == 512 && scale == 2) {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try shell(["sips", "-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try shell(["iconutil", "-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")

extension URL {
    func replacingExisting() -> URL {
        try? FileManager.default.removeItem(at: self)
        return self
    }
}
