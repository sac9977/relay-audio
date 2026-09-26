import AppKit

// Relay Satellite app icon generator.
// Draws the 1024×1024 macOS icon artwork: the same teal→green squircle as the
// main Relay icon, with a white antenna mast and symmetric broadcast arcs —
// the glyph used across the Satellite UI ("receiving from Relay").
//
// The glyph is rendered to its own transparent bitmap first, its ink bounding
// box is measured, and it is then composited exactly centered on the squircle
// (geometric centering of the actual painted pixels — no hand-tuned offsets).
//
// Output: Assets/satellite_1024.png (assembled into an .icns by
// Scripts/make_satellite_icns.sh, copied into the bundle by build_satellite.sh).

let canvasSize = 1024

// MARK: Glyph bitmap (rendered standalone so its ink box can be measured)

func makeGlyphRep() -> NSBitmapImageRep {
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
        fatalError("Failed to create glyph bitmap")
    }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create glyph graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawGlyph(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawGlyph(in cg: CGContext) {
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

    // Broadcast arcs: two per side, radiating from the antenna tip. Each arc
    // is a narrow angular window around the horizontal (±0.62 rad) so the
    // pair hugs the mast symmetrically. NOTE: both windows sweep with
    // clockwise=false — flipping the flag makes CGContext take the long way
    // around (through the top), which is exactly the off-center bug.
    let arcHalfWindow: CGFloat = 0.62
    let windows: [(start: CGFloat, end: CGFloat)] = [
        (-arcHalfWindow, arcHalfWindow),                      // right side
        (.pi - arcHalfWindow, .pi + arcHalfWindow),           // left side
    ]
    let arcs: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (205, 30, 1.0),
        (310, 25, 0.62),
    ]
    for arc in arcs {
        for window in windows {
            cg.setStrokeColor(NSColor.white.withAlphaComponent(arc.alpha).cgColor)
            cg.setLineWidth(arc.width)
            cg.setLineCap(.round)
            cg.addArc(center: tipCenter, radius: arc.radius, startAngle: window.start, endAngle: window.end, clockwise: false)
            cg.strokePath()
        }
    }

    cg.restoreGState()
}

// MARK: Measure the glyph's ink bounding box (alpha > threshold)
// NSBitmapImageRep pixel coords: (0,0) is the TOP-left corner.

func inkBoundingBox(of rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    guard let data = rep.bitmapData else { return nil }
    let bytesPerRow = rep.bytesPerRow
    let spp = rep.samplesPerPixel
    let alphaIndex = spp - 1 // RGBA: alpha is the last sample
    var minX = canvasSize, maxX = -1, minY = canvasSize, maxY = -1
    for y in 0..<canvasSize {
        let row = data + y * bytesPerRow
        for x in 0..<canvasSize {
            if row[x * spp + alphaIndex] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return maxX >= 0 ? (minX, maxX, minY, maxY) : nil
}

let glyphRep = makeGlyphRep()
guard let bbox = inkBoundingBox(of: glyphRep) else {
    fputs("Glyph rendered empty — nothing to center\n", stderr)
    exit(1)
}
let inkCenterX = CGFloat(bbox.minX + bbox.maxX) / 2
let inkCenterYTop = CGFloat(bbox.minY + bbox.maxY) / 2 // top-left coords
let center = CGFloat(canvasSize) / 2
// Shift applied when drawing into the bottom-left-origin final context: moving
// the origin up (positive y) moves the ink up. If ink sits above center in
// top-left coords (inkCenterYTop < center) it must move DOWN (negative dy).
let dx = center - inkCenterX
let dy = inkCenterYTop - center
print("Ink box: x \(bbox.minX)–\(bbox.maxX), y \(bbox.minY)–\(bbox.maxY) (top-left coords)")
print("Centering shift: dx=\(dx), dy=\(dy)")

// MARK: Final canvas — squircle base + centered glyph

guard let finalRep = NSBitmapImageRep(
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
    fputs("Failed to create final bitmap\n", stderr)
    exit(1)
}
guard let context = NSGraphicsContext(bitmapImageRep: finalRep) else {
    fputs("Failed to create final graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext

let margin = 100
let iconRect = NSRect(x: CGFloat(margin), y: CGFloat(margin), width: CGFloat(canvasSize - margin * 2), height: CGFloat(canvasSize - margin * 2))
let cornerRadius: CGFloat = 185.4 // Apple's macOS squircle radius for an 824pt tile

// Squircle base with soft drop shadow (Apple template style)
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

// Composite the glyph, shifted so its ink box is exactly centered.
cg.saveGState()
cg.translateBy(x: dx, y: dy)
glyphRep.draw(in: NSRect(x: 0, y: 0, width: CGFloat(canvasSize), height: CGFloat(canvasSize)))
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// MARK: Write PNG

guard let pngData = finalRep.representation(using: .png, properties: [:]) else {
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
