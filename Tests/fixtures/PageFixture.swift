import AppKit
import Foundation

let image = NSImage(size: NSSize(width: 1100, height: 650))
image.lockFocus()
NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1100, height: 650)).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, bold: Bool = false) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [
        .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
        .foregroundColor: NSColor.black, .paragraphStyle: paragraph
    ])
}
text("PR #128  ·  Review requested", x: 45, y: 535, width: 1000, height: 60, size: 34, bold: true)
text("Fix login retry after session expiry in Safari", x: 45, y: 445, width: 1000, height: 75, size: 29, bold: true)
text("Problem\nSafari enters a login loop when a session expires and the user retries.", x: 45, y: 285, width: 1000, height: 135, size: 25)
text("Change\nReset expired session state before retrying authentication.\nRegression tests cover session expiry followed by login retry.", x: 45, y: 80, width: 1000, height: 180, size: 25)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
