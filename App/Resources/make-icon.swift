// Generates a simple app icon (EQ bars on a rounded square) as an .iconset directory.
// Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.13, alpha: 1),
               ending: NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.24, alpha: 1))!.draw(in: bg, angle: 90)
    let levels: [CGFloat] = [0.45, 0.7, 0.55, 0.85, 0.6, 0.4]
    let n = CGFloat(levels.count)
    let area = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.16)
    let w = area.width / (n * 1.6)
    for (i, l) in levels.enumerated() {
        let x = area.minX + CGFloat(i) * area.width / n + (area.width / n - w) / 2
        let bar = NSRect(x: x, y: area.minY, width: w, height: area.height * l)
        NSColor(calibratedRed: 1, green: 0.86, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
