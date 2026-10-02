import AppKit

// Original vector-drawn artwork. No WinSCP icon assets are reused.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

@MainActor
func render(pixels: Int, destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MacSCPIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 180, yRadius: 180)
    NSColor.controlAccentColor.setFill()
    tile.fill()
    NSGradient(starting: .systemIndigo, ending: .systemBlue)?.draw(in: tile, angle: -55)
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 260, y: 342))
    folder.line(to: NSPoint(x: 260, y: 690))
    folder.curve(to: NSPoint(x: 300, y: 730), controlPoint1: NSPoint(x: 260, y: 719), controlPoint2: NSPoint(x: 276, y: 730))
    folder.line(to: NSPoint(x: 425, y: 730))
    folder.line(to: NSPoint(x: 490, y: 665))
    folder.line(to: NSPoint(x: 727, y: 665))
    folder.curve(to: NSPoint(x: 766, y: 626), controlPoint1: NSPoint(x: 751, y: 665), controlPoint2: NSPoint(x: 766, y: 650))
    folder.line(to: NSPoint(x: 766, y: 342))
    folder.curve(to: NSPoint(x: 725, y: 301), controlPoint1: NSPoint(x: 766, y: 317), controlPoint2: NSPoint(x: 751, y: 301))
    folder.line(to: NSPoint(x: 301, y: 301))
    folder.curve(to: NSPoint(x: 260, y: 342), controlPoint1: NSPoint(x: 275, y: 301), controlPoint2: NSPoint(x: 260, y: 317))
    folder.close()
    NSColor.white.withAlphaComponent(0.2).setFill()
    folder.fill()
    NSColor.white.withAlphaComponent(0.8).setStroke()
    folder.lineWidth = 14
    folder.stroke()
    let arrows = NSBezierPath()
    arrows.move(to: NSPoint(x: 347, y: 555)); arrows.line(to: NSPoint(x: 682, y: 555))
    arrows.move(to: NSPoint(x: 607, y: 630)); arrows.line(to: NSPoint(x: 682, y: 555)); arrows.line(to: NSPoint(x: 607, y: 480))
    arrows.move(to: NSPoint(x: 677, y: 410)); arrows.line(to: NSPoint(x: 342, y: 410))
    arrows.move(to: NSPoint(x: 417, y: 485)); arrows.line(to: NSPoint(x: 342, y: 410)); arrows.line(to: NSPoint(x: 417, y: 335))
    arrows.lineWidth = 32
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round
    NSColor.white.setStroke()
    arrows.stroke()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MacSCPIcon", code: 1)
    }
    try png.write(to: destination)
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size, destination: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2, destination: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
