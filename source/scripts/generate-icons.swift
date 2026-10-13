import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.appendingPathComponent("LinkDesk.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func png(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: Double(size) / 1024); (transform as NSAffineTransform).concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(calibratedRed: 0.40, green: 0.43, blue: 0.94, alpha: 1), ending: NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.59, alpha: 1))!.draw(in: tile, angle: -80)
    func line(_ points: [NSPoint], color: NSColor = .white, width: CGFloat = 28) {
        let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }; color.setStroke(); path.stroke()
    }
    for x: CGFloat in [140, 568] {
        let display = NSBezierPath(roundedRect: NSRect(x: x, y: 420, width: 316, height: 240), xRadius: 30, yRadius: 30)
        display.lineWidth = 28; NSColor.white.setStroke(); display.stroke()
        NSColor.white.withAlphaComponent(0.07).setFill(); display.fill()
    }
    line([NSPoint(x: 298, y: 418), NSPoint(x: 298, y: 362)])
    line([NSPoint(x: 196, y: 360), NSPoint(x: 400, y: 360)])
    line([NSPoint(x: 726, y: 418), NSPoint(x: 726, y: 362)])
    line([NSPoint(x: 624, y: 360), NSPoint(x: 828, y: 360)])
    let cyan = NSColor(calibratedRed: 0.50, green: 0.94, blue: 0.92, alpha: 1)
    line([NSPoint(x: 479, y: 579), NSPoint(x: 547, y: 579)], color: cyan, width: 22)
    line([NSPoint(x: 532, y: 598), NSPoint(x: 553, y: 579), NSPoint(x: 532, y: 560)], color: cyan, width: 22)
    line([NSPoint(x: 545, y: 501), NSPoint(x: 477, y: 501)], color: cyan, width: 22)
    line([NSPoint(x: 492, y: 520), NSPoint(x: 471, y: 501), NSPoint(x: 492, y: 482)], color: cyan, width: 22)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
for size in [16, 32, 48, 64, 128, 256] { try png(size).write(to: destination.appendingPathComponent("icon-\(size).png")) }
try png(1024).write(to: destination.appendingPathComponent("LinkDesk.png"))
