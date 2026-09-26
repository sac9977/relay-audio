import AppKit

// Relay app icon generator.
// Draws the 1024×1024 macOS icon artwork: a teal→green squircle (matching the
// Satellite UI palette) with a white speaker cabinet and broadcast arcs
// ("any app → every speaker").
//
// Like the Satellite icon, the glyph is rendered to its own transparent
// bitmap first, its ink bounding box is measured, and it is then composited
// exactly centered on the squircle (geometric centering of the actual painted
// pixels — no hand-tuned offsets).
//
// Output: Assets/icon_1024.png (the .icns assembly happens in make_icns.sh
// via sips + iconutil).

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
    let cabinetCenterX: CGFloat = 450
    let cabinetW: CGFloat = 260
    let cabinetH: CGFloat = 400
    let cabinetRect = NSRect(
        x: cabinetCenterX - cabinetW / 2,
        y: midY - cabinetH / 2,
        width: cabinetW,
        height: cabinetH
    )

    // Cabinet
    cg.setFillColor(white)
    cg.addPath(CGPath(roundedRect: cabinetRect, cornerWidth: 52, cornerHeight: 52, transform: nil))
    cg.fillPath()

    // Woofer (lower): ring + center dot
    let wooferCenter = CGPoint(x: cabinetCenterX, y: midY - 72)
    cg.setLineWidth(16)
    cg.setStrokeColor(white)
    cg.addEllipse(in: CGRect(x: wooferCenter.x - 86, y: wooferCenter.y - 86, width: 172, height: 172))
    cg.strokePath()
    cg.setFillColor(white)
    cg.addEllipse(in: CGRect(x: wooferCenter.x - 42, y: wooferCenter.y - 42, width: 84, height: 84))
    cg.fillPath()

    // Tweeter (upper): ring + dot
    let tweeterCenter = CGPoint(x: cabinetCenterX, y: midY + 104)
    cg.setLineWidth(14)
    cg.setStrokeColor(white)
    cg.addEllipse(in: CGRect(x: tweeterCenter.x - 32, y: tweeterCenter.y - 32, width: 64, height: 64))
    cg.strokePath()
    cg.setFillColor(white)
    cg.addEllipse(in: CGRect(x: tweeterCenter.x - 11, y: tweeterCenter.y - 11, width: 22, height: 22))
    cg.fillPath()

    // Broadcast arcs radiating from the cabinet center (rightward sweep only;
    // the sweep angles keep every arc point clear of the cabinet body).
    let arcs: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (220, 30, 1.0),
        (315, 25, 0.62),
    ]
    for arc in arcs {
        cg.setStrokeColor(NSColor.white.withAlphaComponent(arc.alpha).cgColor)
        cg.setLineWidth(arc.width)
        cg.setLineCap(.round)
        cg.addArc(center: CGPoint(x: cabinetCenterX, y: midY), radius: arc.radius, startAngle: -0.62, endAngle: 0.62, clockwise: false)
        cg.strokePath()
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
let outURL = outDir.appendingPathComponent("icon_1024.png")
do {
    try pngData.write(to: outURL)
    print("Wrote \(outURL.path)")
} catch {
    fputs("Failed to write \(outURL.path): \(error)\n", stderr)
    exit(1)
}
