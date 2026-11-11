import AppKit
import Foundation

let project = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 85, y: 85, width: 854, height: 854), xRadius: 195, yRadius: 195)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.46, blue: 0.97, alpha: 1),
                   ending: NSColor(srgbRed: 0.12, green: 0.24, blue: 0.69, alpha: 1))!.draw(in: tile, angle: -70)
        let box = NSBezierPath()
        box.move(to: NSPoint(x: 285, y: 625)); box.line(to: NSPoint(x: 512, y: 745))
        box.line(to: NSPoint(x: 739, y: 625)); box.line(to: NSPoint(x: 739, y: 380))
        box.line(to: NSPoint(x: 512, y: 255)); box.line(to: NSPoint(x: 285, y: 380)); box.close()
        NSColor.white.withAlphaComponent(0.12).setFill(); box.fill()
        NSColor.white.setStroke(); box.lineWidth = 29; box.lineJoinStyle = .round; box.stroke()
        let seams = NSBezierPath()
        seams.move(to: NSPoint(x: 285, y: 625)); seams.line(to: NSPoint(x: 512, y: 505))
        seams.line(to: NSPoint(x: 739, y: 625))
        seams.move(to: NSPoint(x: 512, y: 505)); seams.line(to: NSPoint(x: 512, y: 255))
        seams.move(to: NSPoint(x: 399, y: 685)); seams.line(to: NSPoint(x: 626, y: 565))
        seams.lineWidth = 25; seams.lineCapStyle = .round; seams.stroke()
        let badge = NSBezierPath(ovalIn: NSRect(x: 656, y: 227, width: 166, height: 166))
        NSColor(srgbRed: 0.30, green: 0.91, blue: 0.72, alpha: 1).setFill(); badge.fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 699, y: 311)); check.line(to: NSPoint(x: 728, y: 281)); check.line(to: NSPoint(x: 780, y: 340))
        NSColor(srgbRed: 0.04, green: 0.24, blue: 0.30, alpha: 1).setStroke()
        check.lineWidth = 17; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon-\(points)-\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
