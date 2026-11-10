import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(srgbRed: 0.326, green: 0.443, blue: 0.282, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
        NSColor(srgbRed: 0.975, green: 0.978, blue: 0.953, alpha: 1).setStroke()
        for y in [320.0, 510.0, 700.0] {
            let tick = NSBezierPath()
            tick.lineWidth = 41; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            tick.move(to: NSPoint(x: 262, y: y))
            tick.line(to: NSPoint(x: 308, y: y - 43))
            tick.line(to: NSPoint(x: 389, y: y + 52)); tick.stroke()
            let line = NSBezierPath()
            line.lineWidth = 36; line.lineCapStyle = .round
            line.move(to: NSPoint(x: 475, y: y + 3)); line.line(to: NSPoint(x: 747, y: y + 3)); line.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
