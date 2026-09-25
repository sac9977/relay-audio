import AppKit

// Relay app icon generator.
// Draws the 1024×1024 macOS icon artwork: an indigo→purple squircle with a
// white speaker cabinet and broadcast arcs ("any app → every speaker").
// Output: Assets/icon_1024.png (the .icns assembly happens in build_app.sh
// via sips + iconutil).

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
    NSColor(red: 0.373, green: 0.400, blue: 0.945, alpha: 1), // indigo #5F66F1
    NSColor(red: 0.545, green: 0.353, blue: 0.965, alpha: 1), // violet #8B5AF6
])
gradient?.draw(in: squircle, angle: -70)

// Subtle top sheen for depth.
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.16),
    NSColor.white.withAlphaComponent(0.0),
])?.draw(in: squircle, angle: 90)

// MARK: Glyph — speaker cabinet + broadcast arcs
// Composition is centered as a whole: cabinet on the left, two bold arcs
// sweeping out of the cone to the right. Arcs radiate from the cabinet's
// center so they visually emanate from the driver, not float beside it.

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

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
let white = NSColor.white.cgColor

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
NSGraphicsContext.restoreGraphicsState()

// MARK: Write PNG

guard let pngData = rep.representation(using: .png, properties: [:]) else {
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
