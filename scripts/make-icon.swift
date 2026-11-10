// Renders the app icon (a warm sofa on a dark rounded square) into an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.2, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)])!
        .draw(in: path, angle: -90)
    // Warm glow, like a lamp in a dark room.
    NSGradient(colors: [NSColor(red: 1, green: 0.62, blue: 0.42, alpha: 0.35), NSColor(red: 1, green: 0.62, blue: 0.42, alpha: 0)])!
        .draw(in: path, relativeCenterPosition: NSPoint(x: 0, y: -0.2))
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 1, green: 0.66, blue: 0.46, alpha: 1)]))
    if let sofa = NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = sofa.size
        sofa.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.02, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
print("wrote \(out)")
