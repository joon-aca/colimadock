// Renders ColimaDock's app icon: a gray macOS squircle with an isometric shipping box,
// drawn from scratch in the style of the menu bar glyph (SF Symbols may not be used in app icons).
//
// Usage: swift Scripts/make-icon.swift <output.icns>
import AppKit

struct Shade {
    static let backgroundTop = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let backgroundBottom = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let topFace = NSColor(calibratedWhite: 0.98, alpha: 1)
    static let leftFace = NSColor(calibratedWhite: 0.86, alpha: 1)
    static let rightFace = NSColor(calibratedWhite: 0.74, alpha: 1)
    static let topTape = NSColor(calibratedWhite: 0.80, alpha: 1)
    static let rightTape = NSColor(calibratedWhite: 0.60, alpha: 1)
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

func fill(_ points: [CGPoint], _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    color.setFill()
    path.fill()
}

/// Draws the icon in a 1024-point design space, scaled to `pixels`.
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824pt content square inset 100pt, with a soft drop shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    Shade.backgroundBottom.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: Shade.backgroundTop, ending: Shade.backgroundBottom)!.draw(in: tile, angle: -90)

    // Isometric box: 30° faces, centered on the tile.
    let halfWidth: CGFloat = 250
    let rise = halfWidth * tan(.pi / 6)
    let edge: CGFloat = 270
    let top = 512 + (2 * rise + edge) / 2
    let n = CGPoint(x: 512, y: top)
    let e = CGPoint(x: 512 + halfWidth, y: top - rise)
    let s = CGPoint(x: 512, y: top - 2 * rise)
    let w = CGPoint(x: 512 - halfWidth, y: top - rise)
    let down = { (p: CGPoint) in CGPoint(x: p.x, y: p.y - edge) }

    fill([n, e, s, w], Shade.topFace)
    fill([w, s, down(s), down(w)], Shade.leftFace)
    fill([s, e, down(e), down(s)], Shade.rightFace)

    // Packing tape across the top and down the right face.
    let band: CGFloat = 0.09
    fill([lerp(w, n, 0.5 - band), lerp(w, n, 0.5 + band), lerp(s, e, 0.5 + band), lerp(s, e, 0.5 - band)], Shade.topTape)
    fill([lerp(s, e, 0.5 - band), lerp(s, e, 0.5 + band), lerp(down(s), down(e), 0.5 + band), lerp(down(s), down(e), 0.5 - band)], Shade.rightTape)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
