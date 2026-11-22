import AppKit
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let n = size * multiplier
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(n) / 512, y: CGFloat(n) / 512)
        NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 14, y: 14, width: 484, height: 484), xRadius: 106, yRadius: 106).fill()
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: NSRect(x: 85, y: 147, width: 230, height: 218), xRadius: 35, yRadius: 35).fill()
        let p = NSBezierPath(); p.move(to: NSPoint(x: 334, y: 210)); p.line(to: NSPoint(x: 429, y: 156)); p.line(to: NSPoint(x: 429, y: 356)); p.line(to: NSPoint(x: 334, y: 302)); p.close(); p.fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 177, y: 214, width: 88, height: 88)).fill()
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 196, y: 233, width: 50, height: 50)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"))
    }
}
