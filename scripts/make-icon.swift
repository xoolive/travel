// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the package root)
import AppKit

let size: CGFloat = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Sober, in the family of the hoax, jet1090 and ship162 marks: one muted
// colour and a cream silhouette, with only a very light glow.
let cream = NSColor(srgbRed: 1, green: 0.98, blue: 0.95, alpha: 1)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.clip()
let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0xc2573f), rgb(0xb74d37), rgb(0xa5412d)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// The aircraft leaves the globe towards the upper right; the symbol points east.
let configuration = NSImage.SymbolConfiguration(pointSize: 270, weight: .bold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [cream]))
let plane = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
let position = CGPoint(x: 648, y: 650)
let angle = 42 * CGFloat.pi / 180
func drawPlane(dx: CGFloat, dy: CGFloat, _ operation: NSCompositingOperation) {
    ctx.saveGState()
    ctx.translateBy(x: position.x + dx, y: position.y + dy)
    ctx.rotate(by: angle)
    let s = plane.size
    plane.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height),
               from: .zero, operation: operation, fraction: 1)
    ctx.restoreGState()
}

// The whole mark is one layer so that the glow follows its outline.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: rgb(0xfff1e0, 0.38))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

// Globe, drawn as a wireframe.
let center = CGPoint(x: 478, y: 478)
let radius: CGFloat = 232
ctx.setStrokeColor(cream.cgColor)
ctx.setLineWidth(22)
ctx.setLineCap(.round)
let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
ctx.strokeEllipse(in: disc)
ctx.saveGState()
ctx.addEllipse(in: disc)
ctx.clip()
ctx.strokeEllipse(in: CGRect(x: center.x - radius * 0.46, y: center.y - radius, width: radius * 0.92, height: radius * 2))
for offset in [-0.5, 0, 0.5] {
    let y = center.y + radius * CGFloat(offset)
    ctx.move(to: CGPoint(x: center.x - radius, y: y))
    ctx.addLine(to: CGPoint(x: center.x + radius, y: y))
    ctx.strokePath()
}
ctx.restoreGState()

// Cut a margin out of the globe around the aircraft, then draw it.
for reach in [26.0, 50.0] {
    for step in 0..<32 {
        let a = CGFloat(step) / 32 * 2 * .pi
        drawPlane(dx: cos(a) * reach, dy: sin(a) * reach, .destinationOut)
    }
}
drawPlane(dx: 0, dy: 0, .sourceOver)

ctx.endTransparencyLayer()
ctx.restoreGState()

// Export the iconset and convert it.
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    try run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent("icon_\(name).png").path])
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"])
try? fm.copyItem(at: master, to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/dev/null"))
print("Wrote Resources/AppIcon.icns")
