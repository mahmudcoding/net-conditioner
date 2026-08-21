// Draws the 1024px app icon (a speedometer with the needle resting in the
// slow zone) with CoreGraphics. Run: swift render-icon.swift <out.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift render-icon.swift <out.png>\n".utf8))
    exit(1)
}

let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let size = CGFloat(side)
let background = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
    xRadius: 232, yRadius: 232
)
NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.21, alpha: 1),
    NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.07, alpha: 1),
])!.draw(in: background, angle: -70)

let center = NSPoint(x: 512, y: 430)
let radius: CGFloat = 290

func segment(_ start: CGFloat, _ end: CGFloat, _ color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius,
                   startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = 92
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

// The dial sweeps clockwise from lower-left (200°) to lower-right (-20°).
segment(200, 128, NSColor(calibratedRed: 0.34, green: 0.78, blue: 0.42, alpha: 1))
segment(120, 56, NSColor(calibratedRed: 0.95, green: 0.77, blue: 0.28, alpha: 1))
segment(48, -20, NSColor(calibratedRed: 0.90, green: 0.32, blue: 0.31, alpha: 1))

// Needle resting deep in the green: the machine is being slowed on purpose.
let needleAngle = 172.0 * .pi / 180
let needleTip = NSPoint(
    x: center.x + (radius - 24) * cos(needleAngle),
    y: center.y + (radius - 24) * sin(needleAngle)
)
let needle = NSBezierPath()
needle.move(to: center)
needle.line(to: needleTip)
needle.lineWidth = 40
needle.lineCapStyle = .round
NSColor.white.setStroke()
needle.stroke()

let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104))
NSColor.white.setFill()
hub.fill()

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("could not write \(arguments[1]): \(error)\n".utf8))
    exit(1)
}
