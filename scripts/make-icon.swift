// Renders Hearth's app icon (warm gradient squircle + white flame) into the asset catalog.
// Usage: swift scripts/make-icon.swift Hearth/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: ~10% margin around a continuous-corner rounded square.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.72, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.38, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.13, blue: 0.16, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.56, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let fs = flame.size
        let origin = NSPoint(x: rect.midX - fs.width / 2, y: rect.midY - fs.height / 2 - rect.height * 0.01)
        flame.draw(in: NSRect(origin: origin, size: fs), from: .zero, operation: .sourceOver, fraction: 0.97)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(pixels: base * scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
print("wrote icons to \(outDir)")
