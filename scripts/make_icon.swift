// Draws the app icon: swift scripts/make_icon.swift <out.iconset dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.49, green: 0.36, blue: 1, alpha: 1), NSColor(red: 0.10, green: 0.83, blue: 1, alpha: 1)])!
        .draw(in: bg, angle: -45)
    // Ruler ticks.
    NSColor.white.withAlphaComponent(0.85).setFill()
    let n = 21, left = rect.minX + rect.width * 0.14, width = rect.width * 0.72
    for i in 0..<n {
        let major = i % 5 == 0
        let h = rect.height * (major ? 0.20 : 0.11)
        let x = left + width * CGFloat(i) / CGFloat(n - 1)
        NSBezierPath(roundedRect: NSRect(x: x - s * 0.007, y: rect.minY + rect.height * 0.27, width: s * 0.014, height: h),
                     xRadius: s * 0.007, yRadius: s * 0.007).fill()
    }
    // Playhead.
    let px0 = left + width * 0.62
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: px0 - s * 0.012, y: rect.minY + rect.height * 0.22, width: s * 0.024, height: rect.height * 0.5),
                 xRadius: s * 0.012, yRadius: s * 0.012).fill()
    NSBezierPath(ovalIn: NSRect(x: px0 - s * 0.05, y: rect.minY + rect.height * 0.68, width: s * 0.1, height: s * 0.1)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
