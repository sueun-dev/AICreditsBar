import AppKit

// Original AICreditsBar artwork. Coordinates use a 1024-point, top-left canvas.
// The two bars represent provider quotas; the open ring represents remaining capacity.
// Render every ICNS size from geometry so small icons do not inherit a blurred bitmap.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func icon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    let pixelScale = CGFloat(size) / 1024
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: pixelScale, y: -pixelScale)
    context.setShouldAntialias(true)

    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                      cornerWidth: 202, cornerHeight: 202, transform: nil)
    // A restrained edge and shadow keep the tile legible on both light and dark surfaces.
    context.saveGState()
    if size >= 64 {
        context.setShadow(offset: CGSize(width: 0, height: -12 * pixelScale), blur: 22 * pixelScale,
                          color: color(0x002F8A, alpha: 0.24).cgColor)
    }
    context.addPath(tile)
    context.setFillColor(color(0x167FFA).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let blue = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x41C9FF).cgColor, color(0x168FF8).cgColor,
                                   color(0x1657E9).cgColor] as CFArray,
                          locations: [0, 0.45, 1])!
    context.drawLinearGradient(blue, start: CGPoint(x: 512, y: 64),
                               end: CGPoint(x: 512, y: 960), options: [])
    context.restoreGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 67, y: 67, width: 890, height: 890),
                           cornerWidth: 199, cornerHeight: 199, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.22).cgColor)
    context.setLineWidth(5)
    context.strokePath()

    // Slightly heavier strokes at the smallest sizes preserve the silhouette.
    let stroke: CGFloat = size <= 32 ? 76 : 66
    let gauge = CGMutablePath()
    gauge.addArc(center: CGPoint(x: 512, y: 500), radius: 266,
                 startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: false)
    let ring = gauge.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round,
                          miterLimit: 1)
    let mark = CGMutablePath()
    mark.addPath(ring)
    mark.addRoundedRect(in: CGRect(x: 380, y: 450, width: 100, height: 226),
                        cornerWidth: 50, cornerHeight: 50)
    mark.addRoundedRect(in: CGRect(x: 544, y: 342, width: 100, height: 334),
                        cornerWidth: 50, cornerHeight: 50)
    context.saveGState()
    if size >= 64 {
        context.setShadow(offset: CGSize(width: 0, height: -6 * pixelScale), blur: 10 * pixelScale,
                          color: color(0x063C9B, alpha: 0.2).cgColor)
    }
    context.addPath(mark)
    context.setFillColor(color(0xFFFFFF).cgColor)
    context.fillPath()
    context.restoreGState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/render-app-icon.swift <output.iconset> <preview.png>\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(icon(size: points * scale),
                     to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try writePNG(icon(size: 512), to: URL(fileURLWithPath: CommandLine.arguments[2]))
