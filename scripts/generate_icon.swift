import AppKit
import CoreGraphics
import Foundation

// Renders a macOS squircle AppIcon for UsageView:
// Deep neutral charcoal squircle with 3 concentric glowing usage rings
// (Claude Coral Orange, Codex Emerald Green, Antigravity Electric Blue).

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // macOS standard icon inset (approx 9.8% margin around 80.4% squircle)
    let pad = s * 0.095
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Subtle drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.018),
        blur: s * 0.045,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )
    ctx.setFillColor(CGColor(red: 0.145, green: 0.153, blue: 0.173, alpha: 1.0))
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle and fill dark neutral surface gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.21, green: 0.22, blue: 0.25, alpha: 1.0),
        CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: s * 0.5, y: rect.maxY),
            end: CGPoint(x: s * 0.5, y: rect.minY),
            options: []
        )
    }

    // Inner subtle border
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.addPath(squircle)
    ctx.strokePath()

    // Draw 3 concentric usage rings (Claude Orange, Codex Green, Antigravity Blue)
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let rings: [(radius: CGFloat, width: CGFloat, progress: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (s * 0.285, s * 0.056, 0.78, 0.91, 0.48, 0.33), // Outer: Claude Coral Orange
        (s * 0.195, s * 0.052, 0.64, 0.16, 0.82, 0.62), // Middle: Codex Emerald Green
        (s * 0.110, s * 0.048, 0.86, 0.38, 0.58, 0.99), // Inner: Antigravity Electric Blue
    ]

    for ring in rings {
        // Track
        ctx.setStrokeColor(CGColor(red: ring.r, green: ring.g, blue: ring.b, alpha: 0.22))
        ctx.setLineWidth(ring.width)
        ctx.addArc(center: center, radius: ring.radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Active arc (starts at top = +pi/2, goes clockwise)
        let startAngle = CGFloat.pi / 2
        let endAngle = startAngle - (.pi * 2 * ring.progress)
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: s * 0.025,
            color: CGColor(red: ring.r, green: ring.g, blue: ring.b, alpha: 0.55)
        )
        ctx.setStrokeColor(CGColor(red: ring.r, green: ring.g, blue: ring.b, alpha: 1.0))
        ctx.setLineWidth(ring.width)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: ring.radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Center core dot
    let dotRadius = s * 0.032
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

    ctx.restoreGState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in specs {
    if let data = renderIcon(pixelSize: px) {
        let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(name)
        try data.write(to: url)
    }
}
