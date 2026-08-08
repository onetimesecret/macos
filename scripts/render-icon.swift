// Renders one app icon as a complete .iconset directory. The look is
// chosen by a style name on the command line; each style is one entry
// in the `styles` registry below, so adding a new look means adding
// one entry and nothing else.
//
// Run by scripts/build-icons.sh via `swift render-icon.swift <style>
// <rrggbb> <out.iconset>`; not part of the Swift package.
// `swift render-icon.swift --list` prints the available styles, and
// `--sheet <rrggbb> <out.png>` renders every style into one contact
// sheet for side-by-side judging.

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
/// the orange emoji. `offset` shifts in points; `focus` shifts in
/// fractions of the glyph box, picking which point of the glyph sits
/// at the tile centre (positive x looks right, positive y looks up).
func drawMaruhi(_ color: NSColor, in tile: NSRect, scale: CGFloat = 0.72,
                offset: NSPoint = .zero, focus: NSPoint = .zero) {
    let glyph = "㊙\u{FE0E}" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: tile.height * scale),
        .foregroundColor: color,
    ]
    let size = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: NSPoint(
            x: tile.midX - size.width / 2 + offset.x - focus.x * size.width,
            y: tile.midY - size.height / 2 + offset.y - focus.y * size.height),
        withAttributes: attributes
    )
}

/// A solid tile with the white maruhi blown up past the tile edge and
/// clipped, so larger scales crop deeper into the glyph and `focus`
/// chooses which vignette of it fills the tile.
func vignetteStyle(name: String, scale: CGFloat, focus: NSPoint = .zero, summary: String) -> Style {
    Style(name: name, summary: summary) { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        drawMaruhi(.white, in: ctx.tile, scale: scale, focus: focus)
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
    vignetteStyle(name: "zoom", scale: 1.6,
                  summary: "maruhi zoomed past the tile so its ring crops away"),
    vignetteStyle(name: "zoom2", scale: 3.2,
                  summary: "zoom twice as far in, strokes filling the tile"),
    vignetteStyle(name: "zoom4", scale: 6.4,
                  summary: "zoom four times as far in, a single stroke fragment"),
    vignetteStyle(name: "grain", scale: 3.2, focus: NSPoint(x: -0.15, y: 0),
                  summary: "vignette of the grain radical, bold strokes filling the tile"),
    vignetteStyle(name: "heart", scale: 3.2, focus: NSPoint(x: 0.15, y: -0.12),
                  summary: "vignette of the hooked heart of the right radical"),
    vignetteStyle(name: "glimpse", scale: 2.2, focus: NSPoint(x: 0.30, y: -0.10),
                  summary: "the hooked heart caught against the seal's rim"),
    vignetteStyle(name: "strokes", scale: 3.2, focus: NSPoint(x: 0.30, y: 0),
                  summary: "two sweeping strokes beside the rim, nearly abstract"),
    vignetteStyle(name: "hook", scale: 4.8, focus: NSPoint(x: 0.15, y: -0.15),
                  summary: "deep vignette of the heart's hook, one heavy curl"),
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
    Style(name: "longshadow", summary: "flat tile, maruhi casting a solid diagonal shadow") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let ink = ctx.base.blended(withFraction: 0.25, of: .black) ?? ctx.base
        let step = ctx.tile.height / 160
        for i in 1...120 {
            drawMaruhi(ink, in: ctx.tile,
                       offset: NSPoint(x: step * CGFloat(i), y: -step * CGFloat(i)))
        }
        drawMaruhi(.white, in: ctx.tile)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "badge", summary: "shade tile, white disc badge holding the maruhi") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        let disc = NSBezierPath(ovalIn: ctx.tile.insetBy(
            dx: ctx.tile.width * 0.14, dy: ctx.tile.height * 0.14))
        NSColor.white.setFill()
        disc.fill()
        drawMaruhi(ctx.base, in: ctx.tile, scale: 0.56)
    },
    Style(name: "misprint", summary: "near-white tile, maruhi printed twice out of register") { ctx in
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        ctx.tilePath.fill()
        let slip = ctx.tile.width * 0.02
        let ghost = ctx.base.blended(withFraction: 0.55, of: .white) ?? ctx.base
        drawMaruhi(ghost, in: ctx.tile, offset: NSPoint(x: slip, y: -slip))
        drawMaruhi(ctx.base.withAlphaComponent(0.92), in: ctx.tile)
    },
    Style(name: "night", summary: "near-black tile, maruhi inked in the shade itself") { ctx in
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        ctx.tilePath.fill()
        drawMaruhi(ctx.base.blended(withFraction: 0.20, of: .white) ?? ctx.base, in: ctx.tile)
    },
]

// MARK: - Rendering

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("could not allocate a \(width)x\(height) bitmap") }
    rep.size = NSSize(width: width, height: height)
    return rep
}

func render(px: Int, style: Style, base: NSColor) -> NSBitmapImageRep {
    let rep = makeBitmap(width: px, height: px)

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

func writeIconset(style: Style, base: NSColor, to outDir: URL) {
    // iconutil's expected members: each point size at 1x and 2x,
    // sharing pixel renderings where they coincide.
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
                guard let png = render(px: px, style: style, base: base)
                    .representation(using: .png, properties: [:]) else {
                    fail("could not encode the \(px)px rendering as PNG")
                }
                cache[px] = png
            }
            try cache[px]!.write(to: outDir.appendingPathComponent(file))
        }
    } catch {
        fail("writing \(outDir.path): \(error.localizedDescription)")
    }
}

/// One labelled cell per style: the 128px rendering above the 16px
/// rendering blown up 4x with no smoothing. The blow-up is the
/// legibility test the styles are judged by, so the sheet shows every
/// look at both scales side by side.
func writeSheet(base: NSColor, to url: URL) {
    let big = 128, tinyShown = 64, pad = 12, labelH = 16
    let columns = 4
    let rows = (styles.count + columns - 1) / columns
    let cellW = big + pad
    let cellH = big + 4 + tinyShown + labelH + pad
    let width = columns * cellW + pad
    let height = rows * cellH + pad

    let rep = makeBitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.white,
    ]

    let pixelated: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.none.rawValue]
    for (index, style) in styles.enumerated() {
        let x = CGFloat(pad + (index % columns) * cellW)
        let yTop = CGFloat(height - pad - (index / columns) * cellH)
        render(px: big, style: style, base: base).draw(
            in: NSRect(x: x, y: yTop - CGFloat(big), width: CGFloat(big), height: CGFloat(big)),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: pixelated)
        render(px: 16, style: style, base: base).draw(
            in: NSRect(x: x, y: yTop - CGFloat(big + 4 + tinyShown),
                       width: CGFloat(tinyShown), height: CGFloat(tinyShown)),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: pixelated)
        (style.name as NSString).draw(
            at: NSPoint(x: x, y: yTop - CGFloat(big + 4 + tinyShown + labelH)),
            withAttributes: labelAttributes)
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode the contact sheet as PNG")
    }
    do {
        try png.write(to: url)
    } catch {
        fail("writing \(url.path): \(error.localizedDescription)")
    }
}

// MARK: - Command line

func parseShade(_ hex: String) -> NSColor {
    guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
        fail("shade must be six hex digits, got \"\(hex)\"")
    }
    return NSColor(
        calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: 1
    )
}

let arguments = CommandLine.arguments

if arguments.count == 2, arguments[1] == "--list" {
    for style in styles {
        print("\(style.name)\t\(style.summary)")
    }
    exit(0)
}

if arguments.count == 4, arguments[1] == "--sheet" {
    writeSheet(base: parseShade(arguments[2]), to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}

guard arguments.count == 4, !arguments[1].hasPrefix("--") else {
    let names = styles.map(\.name).joined(separator: "|")
    fail("""
    usage: swift render-icon.swift <style> <rrggbb> <output.iconset>
           swift render-icon.swift --sheet <rrggbb> <output.png>
           swift render-icon.swift --list
    styles: \(names)
    """)
}

guard let style = styles.first(where: { $0.name == arguments[1] }) else {
    fail("unknown style \"\(arguments[1])\"; run with --list to see the choices")
}

writeIconset(style: style, base: parseShade(arguments[2]),
             to: URL(fileURLWithPath: arguments[3], isDirectory: true))
