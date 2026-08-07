// Renders one app icon as a complete .iconset directory. The look is
// chosen by a style name on the command line; each style is one entry
// in the `styles` registry below, so adding a new look means adding
// one entry and nothing else.
//
// Run by scripts/build-icons.sh via `swift render-icon.swift <style>
// <rrggbb> <out.iconset>`; not part of the Swift package.
// `swift render-icon.swift --list` prints the available styles.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Style registry

/// Everything a style needs to draw one square rendering. The canvas
/// outside `tile` is transparent margin; `tilePath` is the rounded
/// rect on Apple's icon grid (824/1024 of the canvas, corners at
/// 185/824 of the tile). `base` is the shade from the command line.
struct StyleContext {
    let canvas: CGFloat
    let tile: NSRect
    let tilePath: NSBezierPath
    let base: NSColor
}

struct Style {
    let name: String
    let summary: String
    let draw: (StyleContext) -> Void
}

/// The ㊙ maruhi centred in the tile. U+FE0E forces the text
/// presentation so the glyph takes our colour instead of arriving as
/// the orange emoji.
func drawMaruhi(_ color: NSColor, in tile: NSRect, scale: CGFloat = 0.72) {
    let glyph = "㊙\u{FE0E}" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: tile.height * scale),
        .foregroundColor: color,
    ]
    let size = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2),
        withAttributes: attributes
    )
}

/// A solid tile with the white maruhi blown up past the tile edge and
/// clipped, so larger scales crop deeper into the glyph.
func zoomStyle(name: String, scale: CGFloat, summary: String) -> Style {
    Style(name: name, summary: summary) { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        drawMaruhi(.white, in: ctx.tile, scale: scale)
        NSGraphicsContext.restoreGraphicsState()
    }
}

let styles: [Style] = [
    Style(name: "gradient", summary: "slight top-lit gradient tile, white maruhi (the original)") { ctx in
        let lit = ctx.base.blended(withFraction: 0.10, of: .white) ?? ctx.base
        let shaded = ctx.base.blended(withFraction: 0.14, of: .black) ?? ctx.base
        NSGradient(starting: lit, ending: shaded)?.draw(in: ctx.tilePath, angle: -90)
        drawMaruhi(.white, in: ctx.tile)
    },
    Style(name: "flat", summary: "solid tile in the shade, white maruhi") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        drawMaruhi(.white, in: ctx.tile)
    },
    Style(name: "inverse", summary: "near-white tile, maruhi in the shade") { ctx in
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        ctx.tilePath.fill()
        drawMaruhi(ctx.base, in: ctx.tile)
    },
    zoomStyle(name: "zoom", scale: 1.6,
              summary: "maruhi zoomed past the tile so its ring crops away"),
    zoomStyle(name: "zoom2", scale: 3.2,
              summary: "zoom twice as far in, strokes filling the tile"),
    zoomStyle(name: "zoom4", scale: 6.4,
              summary: "zoom four times as far in, a single stroke fragment"),
    Style(name: "stamp", summary: "hanko: warm paper tile, maruhi inked askew in the shade") { ctx in
        NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1).setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let tilt = NSAffineTransform()
        tilt.translateX(by: ctx.tile.midX, yBy: ctx.tile.midY)
        tilt.rotate(byDegrees: -12)
        tilt.translateX(by: -ctx.tile.midX, yBy: -ctx.tile.midY)
        tilt.concat()
        drawMaruhi(ctx.base.withAlphaComponent(0.88), in: ctx.tile, scale: 0.78)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "neon", summary: "night tile, maruhi glowing in the shade like a sign") { ctx in
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let tube = ctx.base.blended(withFraction: 0.45, of: .white) ?? ctx.base
        let glow = NSShadow()
        glow.shadowColor = tube
        glow.shadowBlurRadius = ctx.tile.height * 0.05
        glow.set()
        for _ in 0..<3 { drawMaruhi(tube, in: ctx.tile, scale: 0.66) }
        drawMaruhi(tube.blended(withFraction: 0.55, of: .white) ?? tube, in: ctx.tile, scale: 0.66)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "ring", summary: "solid tile, white ring around a smaller maruhi") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        let ring = NSBezierPath(ovalIn: ctx.tile.insetBy(
            dx: ctx.tile.width * 0.10, dy: ctx.tile.height * 0.10))
        ring.lineWidth = ctx.tile.width * 0.035
        NSColor.white.setStroke()
        ring.stroke()
        drawMaruhi(.white, in: ctx.tile, scale: 0.56)
    },
    Style(name: "split", summary: "tile halved on the diagonal, maruhi swapping colours at the seam") { ctx in
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        ctx.tilePath.fill()
        let upper = NSBezierPath()
        upper.move(to: NSPoint(x: ctx.tile.minX, y: ctx.tile.minY))
        upper.line(to: NSPoint(x: ctx.tile.minX, y: ctx.tile.maxY))
        upper.line(to: NSPoint(x: ctx.tile.maxX, y: ctx.tile.maxY))
        upper.close()
        let lower = NSBezierPath()
        lower.move(to: NSPoint(x: ctx.tile.minX, y: ctx.tile.minY))
        lower.line(to: NSPoint(x: ctx.tile.maxX, y: ctx.tile.maxY))
        lower.line(to: NSPoint(x: ctx.tile.maxX, y: ctx.tile.minY))
        lower.close()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        upper.addClip()
        ctx.base.setFill()
        ctx.tile.fill()
        drawMaruhi(.white, in: ctx.tile)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        lower.addClip()
        drawMaruhi(ctx.base, in: ctx.tile)
        NSGraphicsContext.restoreGraphicsState()
    },
]

// MARK: - Command line

let arguments = CommandLine.arguments

if arguments.count == 2, arguments[1] == "--list" {
    for style in styles {
        print("\(style.name)\t\(style.summary)")
    }
    exit(0)
}

guard arguments.count == 4 else {
    let names = styles.map(\.name).joined(separator: "|")
    fail("""
    usage: swift render-icon.swift <style> <rrggbb> <output.iconset>
           swift render-icon.swift --list
    styles: \(names)
    """)
}

guard let style = styles.first(where: { $0.name == arguments[1] }) else {
    fail("unknown style \"\(arguments[1])\"; run with --list to see the choices")
}

let hex = arguments[2]
let outDir = URL(fileURLWithPath: arguments[3], isDirectory: true)

guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
    fail("shade must be six hex digits, got \"\(hex)\"")
}
let base = NSColor(
    calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
    green: CGFloat((rgb >> 8) & 0xFF) / 255,
    blue: CGFloat(rgb & 0xFF) / 255,
    alpha: 1
)

// MARK: - Rendering

func render(px: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("could not allocate a \(px)px bitmap") }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = CGFloat(px)
    let inset = canvas * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 185 / 824, yRadius: tile.width * 185 / 824)
    style.draw(StyleContext(canvas: canvas, tile: tile, tilePath: path, base: base))
    return rep
}

// iconutil's expected members: each point size at 1x and 2x, sharing
// pixel renderings where they coincide.
let members: [(file: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var cache: [Int: Data] = [:]
    for (file, px) in members {
        if cache[px] == nil {
            guard let png = render(px: px).representation(using: .png, properties: [:]) else {
                fail("could not encode the \(px)px rendering as PNG")
            }
            cache[px] = png
        }
        try cache[px]!.write(to: outDir.appendingPathComponent(file))
    }
} catch {
    fail("writing \(outDir.path): \(error.localizedDescription)")
}
