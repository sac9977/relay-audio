import AppKit

// Relay Satellite app icon generator.
// Draws the 1024×1024 macOS icon artwork: the same teal→green squircle as the
// main Relay icon, with a white antenna mast and symmetric broadcast arcs —
// the glyph used across the Satellite UI ("receiving from Relay").
// Output: Assets/satellite_1024.png (assembled into an .icns by
// Scripts/make_satellite_icns.sh, copied into the bundle by build_satellite.sh).

let canvasSize = 1024
let margin = 100
let iconRect = NSRect(x: CGFloat(margin), y: CGFloat(margin), width: CGFloat(canvasSize - margin * 2), height: CGFloat(canvasSize - margin * 2))
let cornerRadius: CGFloat = 185.4 // Apple's macOS squircle radius for an 824pt tile

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create bitmap image rep\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Failed to create graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext

// MARK: Squircle base with soft drop shadow (Apple template style)

let squircle = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState() // shadow off for subsequent fills

let gradient = NSGradient(colors: [
    NSColor(red: 0.161, green: 0.678, blue: 0.659, alpha: 1), // teal   #29ADA8
    NSColor(red: 0.220, green: 0.780, blue: 0.435, alpha: 1), // green  #38C76F
])
gradient?.draw(in: squircle, angle: -70)

// Subtle top sheen for depth.
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.16),
    NSColor.white.withAlphaComponent(0.0),
])?.draw(in: squircle, angle: 90)

// MARK: Glyph — antenna mast + symmetric broadcast arcs
// Same geometry language as SF's antenna.radiowaves.left.and.right: a rounded
// mast with a circular tip, flanked by two arcs per side. Everything is drawn
// from the canvas center so the composition stays balanced.

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
let white = NSColor.white.cgColor

let midY = CGFloat(canvasSize) / 2
let centerX = CGFloat(canvasSize) / 2

// Antenna mast: a vertical rounded rectangle from below center up to the tip.
let mastWidth: CGFloat = 46
let mastBottom = midY - 190
let mastTop = midY + 44
let mastRect = NSRect(x: centerX - mastWidth / 2, y: mastBottom, width: mastWidth, height: mastTop - mastBottom)
cg.setFillColor(white)
cg.addPath(CGPath(roundedRect: mastRect, cornerWidth: mastWidth / 2, cornerHeight: mastWidth / 2, transform: nil))
cg.fillPath()

// Antenna tip: filled circle capping the mast.
let tipRadius: CGFloat = 52
let tipCenter = CGPoint(x: centerX, y: mastTop + tipRadius * 0.55)
cg.addEllipse(in: CGRect(x: tipCenter.x - tipRadius, y: tipCenter.y - tipRadius, width: tipRadius * 2, height: tipRadius * 2))
cg.fillPath()

// Base: a subtle grounded ellipse under the mast (SF-style pedestal).
let baseCenter = CGPoint(x: centerX, y: midY - 214)
cg.addEllipse(in: CGRect(x: baseCenter.x - 120, y: baseCenter.y - 24, width: 240, height: 48))
cg.fillPath()

// Broadcast arcs: two per side, radiating from the antenna tip. Arcs are
// angular windows around horizontal so they hug the mast without crossing it.
let arcs: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (205, 30, 1.0),
    (310, 25, 0.62),
]
for arc in arcs {
    for direction in [false, true] { // right = counterclockwise 0°, left = mirrored
        cg.setStrokeColor(NSColor.white.withAlphaComponent(arc.alpha).cgColor)
        cg.setLineWidth(arc.width)
        cg.setLineCap(.round)
        let start: CGFloat = direction ? CGFloat.pi - 0.62 : -0.62
        let end: CGFloat = direction ? CGFloat.pi + 0.62 : 0.62
        cg.addArc(center: tipCenter, radius: arc.radius, startAngle: start, endAngle: end, clockwise: direction)
        cg.strokePath()
    }
}

cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()

// MARK: Write PNG

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
let outDir = URL(fileURLWithPath: "Assets")
try? fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
let outURL = outDir.appendingPathComponent("satellite_1024.png")
do {
    try pngData.write(to: outURL)
    print("Wrote \(outURL.path)")
} catch {
    fputs("Failed to write \(outURL.path): \(error)\n", stderr)
    exit(1)
}
