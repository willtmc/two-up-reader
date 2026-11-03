import Cocoa
// Draws the app icon: an open two-page spread on a dark tile.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
let paper = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)
let ink = NSColor(calibratedRed: 0.55, green: 0.52, blue: 0.46, alpha: 1)
for x in [222.0, 522.0] {
    paper.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 250, width: 280, height: 524), xRadius: 14, yRadius: 14).fill()
    ink.setFill()
    var y = 690.0
    while y > 300 {
        let w = (y < 340 && x > 500) ? 120.0 : 216.0
        NSBezierPath(roundedRect: NSRect(x: x + 32, y: y, width: w, height: 14), xRadius: 7, yRadius: 7).fill()
        y -= 38
    }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
