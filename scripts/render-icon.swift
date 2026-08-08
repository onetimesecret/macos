// Renders one app icon as a complete .iconset directory. The look is
// two independent choices on the command line: a motif (the `marks`
// registry: the maruhi glyph, or the onetimesecret.com logo mark read
// from the app's own resources) and a style (the `styles` registry,
// which says how the tile is treated and where the motif sits on it).
// Every style works with every mark, so adding one entry to either
// registry adds a row or a column to the whole matrix.
//
// Run by scripts/build-icons.sh via `swift render-icon.swift [--mark
// <mark>] <style> <rrggbb> <out.iconset>`; not part of the Swift
// package. `swift render-icon.swift --list` prints the available marks
// and styles; `--sheet <rrggbb> <out.png>` renders every style into
// one contact sheet for side-by-side judging; `--sweep <zoom> <rrggbb>
// <out.png> [grid]` scouts vignette crops of the motif on a grid of
// focuses; `--scout <rrggbb> <out.png> [perUnit]` picks the visually
// interesting crops at each zoom level by scoring corner and
// intersection density instead of walking a blind grid, keeping
// perUnit picks for every unit of zoom. `--mark` applies to all four.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - The logo mark, read from SVG

/// The brand art, resolved from this script's own location so the
/// renderer works from any working directory. It lives with the app
/// rather than with the scripts because the app draws it too: the menu
/// bar item is the same mark (CompanionKit's LogoMark), and one asset
/// is what keeps the tray and the Dock tile from drifting apart. The
/// parser below is duplicated there of necessity; the icon is built
/// before there is an app to share code with.
let logoSVG = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("shell/Sources/CompanionKit/Resources/onetime-logo-v3-xl.svg")

/// The value of one attribute of one tag, or nil when the tag has no
/// such attribute. Enough XML for a hand written two path logo, and
/// deliberately no more: anything richer belongs in a real parser.
func attribute(_ name: String, of tag: String) -> String? {
    guard let range = tag.range(of: "\\b\(name)=\"[^\"]*\"", options: .regularExpression),
          let open = tag[range].firstIndex(of: "\""),
          let close = tag[range].lastIndex(of: "\""), open < close
    else { return nil }
    return String(tag[range][tag.index(after: open)..<close])
}

/// Every `<path …>` tag in the document, in document order.
func pathTags(in svg: String) -> [String] {
    var tags: [String] = []
    var from = svg.startIndex
    while let range = svg.range(of: "<path[^>]*>", options: .regularExpression,
                                range: from..<svg.endIndex) {
        tags.append(String(svg[range]))
        from = range.upperBound
    }
    return tags
}

/// One `d` attribute as a bezier path, in the SVG's own coordinates
/// (y running down). Moves, lines, cubics, and closes, absolute and
/// relative, with the implicit repeat of a command's coordinate sets.
/// Any other command stops the build rather than drawing a wrong mark.
func parseSVGPath(_ d: String) -> NSBezierPath {
    let path = NSBezierPath()
    let scanner = Scanner(string: d)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\r\t")
    var command: Character = " "
    var current = NSPoint.zero, subpathStart = NSPoint.zero

    func number() -> CGFloat {
        guard let value = scanner.scanDouble() else {
            fail("the logo path ends mid command, after \"\(command)\"")
        }
        return CGFloat(value)
    }
    func point(relative: Bool) -> NSPoint {
        let x = number(), y = number()
        return relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
    }

    while true {
        let mark = scanner.currentIndex
        guard let next = scanner.scanCharacter() else { break }
        if next.isLetter {
            command = next
        } else {
            scanner.currentIndex = mark
            guard command != " " else { fail("the logo path does not open with a command") }
        }
        let relative = command.isLowercase
        switch Character(command.lowercased()) {
        case "m":
            current = point(relative: relative)
            subpathStart = current
            path.move(to: current)
            // A move's further coordinate sets are lines, per SVG.
            command = relative ? "l" : "L"
        case "l":
            current = point(relative: relative)
            path.line(to: current)
        case "h":
            let x = number()
            current = NSPoint(x: relative ? current.x + x : x, y: current.y)
            path.line(to: current)
        case "v":
            let y = number()
            current = NSPoint(x: current.x, y: relative ? current.y + y : y)
            path.line(to: current)
        case "c":
            let one = point(relative: relative), two = point(relative: relative)
            current = point(relative: relative)
            path.curve(to: current, controlPoint1: one, controlPoint2: two)
        case "z":
            path.close()
            current = subpathStart
        default:
            fail("the logo path uses the unsupported command \"\(command)\"")
        }
    }
    return path
}

/// The mark alone: every path in the document except a full bleed
/// plate, which is the artwork's background rather than its subject.
/// Fills are dropped because a style tints the motif itself.
func loadLogoMark() -> NSBezierPath {
    guard let svg = try? String(contentsOf: logoSVG, encoding: .utf8) else {
        fail("could not read the logo at \(logoSVG.path)")
    }
    guard let head = svg.range(of: "<svg[^>]*>", options: .regularExpression),
          let width = attribute("width", of: String(svg[head])).flatMap(Double.init),
          let height = attribute("height", of: String(svg[head])).flatMap(Double.init),
          width > 0, height > 0
    else { fail("the logo has no <svg> width and height to measure its plate against") }

    let mark = NSBezierPath()
    for tag in pathTags(in: svg) {
        guard let d = attribute("d", of: tag) else { continue }
        let path = parseSVGPath(d)
        if let translate = attribute("transform", of: tag) {
            let offsets = translate.components(separatedBy: CharacterSet(charactersIn: "(,)"))
                .compactMap(Double.init)
            guard translate.hasPrefix("translate("), offsets.count == 2 else {
                fail("the logo uses the unsupported transform \"\(translate)\"")
            }
            let shift = NSAffineTransform()
            shift.translateX(by: CGFloat(offsets[0]), yBy: CGFloat(offsets[1]))
            path.transform(using: shift as AffineTransform)
        }
        let box = path.cgPath.boundingBoxOfPath
        let plate = box.width >= 0.99 * width && box.height >= 0.99 * height
        if !plate { mark.append(path) }
    }
    guard !mark.isEmpty else { fail("the logo has no path left once its plate is dropped") }
    return mark
}

/// Parsed on first use and kept, so a maruhi render never reads the
/// SVG and a logo sheet reads it once for hundreds of drawings.
var logoMarkCache: (path: NSBezierPath, bounds: CGRect)?

func logoMark() -> (path: NSBezierPath, bounds: CGRect) {
    if let cached = logoMarkCache { return cached }
    let path = loadLogoMark()
    let loaded = (path, path.cgPath.boundingBoxOfPath)
    logoMarkCache = loaded
    return loaded
}

// MARK: - Mark registry

/// A motif a style can stamp on its tile, drawn in whatever colour the
/// style asks for. `scale` sizes the motif's box as a fraction of the
/// tile height, `offset` shifts it in points, and `focus` shifts it in
/// fractions of that box, picking which point of the motif sits at the
/// tile centre (positive x looks right, positive y looks up). Styles
/// name no mark of their own: the mark comes from the command line, so
/// every style renders with every mark.
struct Mark {
    let name: String
    let summary: String
    let draw: (_ color: NSColor, _ tile: NSRect, _ scale: CGFloat,
               _ offset: NSPoint, _ focus: NSPoint) -> Void
}

/// The ㊙ maruhi centred in the tile. U+FE0E forces the text
/// presentation so the glyph takes our colour instead of arriving as
/// the orange emoji.
func drawMaruhi(_ color: NSColor, in tile: NSRect, scale: CGFloat,
                offset: NSPoint, focus: NSPoint) {
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

/// The onetimesecret.com logo mark, fitted into a square box of
/// `tile.height * scale` a side. The glyph box a font hands back
/// carries ascender and descender air the maruhi never fills, so the
/// mark is fitted to `logoFill` of the box instead of all of it; that
/// makes the two motifs read at the same weight at one scale, and lets
/// the vignette styles crop both alike.
let logoFill: CGFloat = 0.88

func drawLogo(_ color: NSColor, in tile: NSRect, scale: CGFloat,
              offset: NSPoint, focus: NSPoint) {
    let (mark, art) = logoMark()
    guard art.width > 0, art.height > 0 else { fail("the logo mark path is empty") }
    let box = tile.height * scale
    let k = box * logoFill / max(art.width, art.height)
    let width = art.width * k, height = art.height * k
    let x = tile.midX - width / 2 + offset.x - focus.x * box
    let y = tile.midY - height / 2 + offset.y - focus.y * box

    // The path is in SVG coordinates, y running down, so the fit flips
    // y and lands the art's top left at the top left of the fitted box.
    let fit = NSAffineTransform()
    fit.translateX(by: x, yBy: y + height)
    fit.scaleX(by: k, yBy: -k)
    fit.translateX(by: -art.minX, yBy: -art.minY)
    let path = fit.transform(mark)
    path.windingRule = .nonZero
    color.setFill()
    path.fill()
}

let marks: [Mark] = [
    Mark(name: "maruhi", summary: "the ㊙ maruhi glyph, the original motif", draw: drawMaruhi),
    Mark(name: "logo", summary: "the onetimesecret.com logo mark", draw: drawLogo),
]

// MARK: - Style registry

/// Everything a style needs to draw one square rendering. The canvas
/// outside `tile` is transparent margin; `tilePath` is the rounded
/// rect on Apple's icon grid (824/1024 of the canvas, corners at
/// 185/824 of the tile). `base` is the shade from the command line,
/// and `mark` the motif chosen alongside it.
struct StyleContext {
    let canvas: CGFloat
    let tile: NSRect
    let tilePath: NSBezierPath
    let base: NSColor
    let mark: Mark

    func drawMark(_ color: NSColor, scale: CGFloat = 0.72,
                  offset: NSPoint = .zero, focus: NSPoint = .zero) {
        mark.draw(color, tile, scale, offset, focus)
    }
}

struct Style {
    let name: String
    let summary: String
    let draw: (StyleContext) -> Void
}

/// A solid tile with the white motif blown up past the tile edge and
/// clipped, so larger scales crop deeper into it and `focus` chooses
/// which vignette of it fills the tile.
func vignetteStyle(name: String, scale: CGFloat, focus: NSPoint = .zero, summary: String) -> Style {
    Style(name: name, summary: summary) { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        ctx.drawMark(.white, scale: scale, focus: focus)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The named vignettes below were scouted on the maruhi, so their
/// focuses land on that glyph's anatomy; under another mark they are
/// still valid crops, just not the ones their names describe.
let styles: [Style] = [
    Style(name: "gradient", summary: "slight top-lit gradient tile, white motif (the original)") { ctx in
        let lit = ctx.base.blended(withFraction: 0.10, of: .white) ?? ctx.base
        let shaded = ctx.base.blended(withFraction: 0.14, of: .black) ?? ctx.base
        NSGradient(starting: lit, ending: shaded)?.draw(in: ctx.tilePath, angle: -90)
        ctx.drawMark(.white)
    },
    Style(name: "flat", summary: "solid tile in the shade, white motif") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        ctx.drawMark(.white)
    },
    Style(name: "inverse", summary: "near-white tile, motif in the shade") { ctx in
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        ctx.tilePath.fill()
        ctx.drawMark(ctx.base)
    },
    vignetteStyle(name: "zoom", scale: 1.6,
                  summary: "motif zoomed past the tile so its outer edge crops away"),
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
    // Scouted on the logo mark, which crops well only at shallow zooms:
    // past about 3x every focus lands on a plain diagonal edge.
    vignetteStyle(name: "logo-bleed", scale: 1.6, focus: NSPoint(x: -0.03, y: 0.015),
                  summary: "the logo mark grown until it bleeds off the tile, still legible"),
    vignetteStyle(name: "logo-curl", scale: 2.5, focus: NSPoint(x: 0.06, y: 0.105),
                  summary: "the logo mark's upper curl, a hook against the corner"),
    Style(name: "stamp", summary: "hanko: warm paper tile, motif inked askew in the shade") { ctx in
        NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1).setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let tilt = NSAffineTransform()
        tilt.translateX(by: ctx.tile.midX, yBy: ctx.tile.midY)
        tilt.rotate(byDegrees: -12)
        tilt.translateX(by: -ctx.tile.midX, yBy: -ctx.tile.midY)
        tilt.concat()
        ctx.drawMark(ctx.base.withAlphaComponent(0.88), scale: 0.78)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "neon", summary: "night tile, motif glowing in the shade like a sign") { ctx in
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let tube = ctx.base.blended(withFraction: 0.45, of: .white) ?? ctx.base
        let glow = NSShadow()
        glow.shadowColor = tube
        glow.shadowBlurRadius = ctx.tile.height * 0.05
        glow.set()
        for _ in 0..<3 { ctx.drawMark(tube, scale: 0.66) }
        ctx.drawMark(tube.blended(withFraction: 0.55, of: .white) ?? tube, scale: 0.66)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "ring", summary: "solid tile, white ring around a smaller motif") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        let ring = NSBezierPath(ovalIn: ctx.tile.insetBy(
            dx: ctx.tile.width * 0.10, dy: ctx.tile.height * 0.10))
        ring.lineWidth = ctx.tile.width * 0.035
        NSColor.white.setStroke()
        ring.stroke()
        ctx.drawMark(.white, scale: 0.56)
    },
    Style(name: "split", summary: "tile halved on the diagonal, motif swapping colours at the seam") { ctx in
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
        ctx.drawMark(.white)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        lower.addClip()
        ctx.drawMark(ctx.base)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "longshadow", summary: "flat tile, motif casting a solid diagonal shadow") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        NSGraphicsContext.saveGraphicsState()
        ctx.tilePath.addClip()
        let ink = ctx.base.blended(withFraction: 0.25, of: .black) ?? ctx.base
        let step = ctx.tile.height / 160
        for i in 1...120 {
            ctx.drawMark(ink, offset: NSPoint(x: step * CGFloat(i), y: -step * CGFloat(i)))
        }
        ctx.drawMark(.white)
        NSGraphicsContext.restoreGraphicsState()
    },
    Style(name: "badge", summary: "shade tile, white disc badge holding the motif") { ctx in
        ctx.base.setFill()
        ctx.tilePath.fill()
        let disc = NSBezierPath(ovalIn: ctx.tile.insetBy(
            dx: ctx.tile.width * 0.14, dy: ctx.tile.height * 0.14))
        NSColor.white.setFill()
        disc.fill()
        ctx.drawMark(ctx.base, scale: 0.56)
    },
    Style(name: "misprint", summary: "near-white tile, motif printed twice out of register") { ctx in
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        ctx.tilePath.fill()
        let slip = ctx.tile.width * 0.02
        let ghost = ctx.base.blended(withFraction: 0.55, of: .white) ?? ctx.base
        ctx.drawMark(ghost, offset: NSPoint(x: slip, y: -slip))
        ctx.drawMark(ctx.base.withAlphaComponent(0.92))
    },
    Style(name: "night", summary: "near-black tile, motif inked in the shade itself") { ctx in
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        ctx.tilePath.fill()
        ctx.drawMark(ctx.base.blended(withFraction: 0.20, of: .white) ?? ctx.base)
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

func render(px: Int, style: Style, base: NSColor, mark: Mark) -> NSBitmapImageRep {
    let rep = makeBitmap(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = CGFloat(px)
    let inset = canvas * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 185 / 824, yRadius: tile.width * 185 / 824)
    style.draw(StyleContext(canvas: canvas, tile: tile, tilePath: path, base: base, mark: mark))
    return rep
}

func writeIconset(style: Style, base: NSColor, mark: Mark, to outDir: URL) {
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
                guard let png = render(px: px, style: style, base: base, mark: mark)
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

/// One labelled cell per entry: the 128px rendering above the 16px
/// rendering blown up 4x with no smoothing. The blow-up is the
/// legibility test the styles are judged by, so the sheet shows every
/// look at both scales side by side.
func writeSheet(cells: [(label: String, style: Style)], columns: Int, base: NSColor,
                mark: Mark, to url: URL) {
    let big = 128, tinyShown = 64, pad = 12, labelH = 16
    let rows = (cells.count + columns - 1) / columns
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
    for (index, cell) in cells.enumerated() {
        let x = CGFloat(pad + (index % columns) * cellW)
        let yTop = CGFloat(height - pad - (index / columns) * cellH)
        render(px: big, style: cell.style, base: base, mark: mark).draw(
            in: NSRect(x: x, y: yTop - CGFloat(big), width: CGFloat(big), height: CGFloat(big)),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: pixelated)
        render(px: 16, style: cell.style, base: base, mark: mark).draw(
            in: NSRect(x: x, y: yTop - CGFloat(big + 4 + tinyShown),
                       width: CGFloat(tinyShown), height: CGFloat(tinyShown)),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: pixelated)
        (cell.label as NSString).draw(
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

/// A focus sweep for one zoom: an n by n grid of vignette crops
/// walking the motif box from its upper left to its lower right, each
/// cell labelled with the focus that reproduces it. This is how new
/// vignette styles are scouted before earning a name in the registry.
func writeSweep(scale: CGFloat, base: NSColor, mark: Mark, n: Int, to url: URL) {
    let span: CGFloat = 0.30
    var cells: [(label: String, style: Style)] = []
    for row in 0..<n {
        let fy = span - 2 * span * CGFloat(row) / CGFloat(n - 1)
        for column in 0..<n {
            let fx = -span + 2 * span * CGFloat(column) / CGFloat(n - 1)
            let label = String(format: "%+.2f,%+.2f", fx, fy)
            cells.append((label, vignetteStyle(
                name: label, scale: scale, focus: NSPoint(x: fx, y: fy), summary: "")))
        }
    }
    writeSheet(cells: cells, columns: n, base: base, mark: mark, to: url)
}

// MARK: - Scouting interesting crops

/// The zooms the scout walks: the named vignette range (zoom at 1.6
/// through zoom4 at 6.4) with steps between, then on into abstract
/// territory where a tile holds one stroke fragment or less.
let scoutZooms: [CGFloat] = [1.6, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6.4, 7, 8, 9, 10, 11, 12]

/// Renders one vignette crop small and reads its ink mask. Returns
/// the ink fraction of the tile and an interest score: the count of
/// 2x2 mask blocks that form corners (1 or 3 ink pixels) or crossings
/// (2 ink pixels on the diagonal). Straight stroke edges score zero,
/// so high scores land on corners, junctions, and stroke overlaps.
func analyzeCrop(scale: CGFloat, focus: NSPoint, base: NSColor, mark: Mark) -> (coverage: CGFloat, interest: Int)? {
    let px = 32
    let rep = render(px: px, style: vignetteStyle(name: "probe", scale: scale, focus: focus, summary: ""),
                     base: base, mark: mark)
    guard let data = rep.bitmapData else { return nil }
    let stride = rep.bytesPerRow, samples = rep.samplesPerPixel

    // 0 outside the tile, 1 base shade, 2 ink. A pixel is ink when it
    // sits nearer white than the shade it was drawn over, which stays
    // honest for a bright shade; a fixed threshold on one channel reads
    // a shade like the brand orange as ink everywhere.
    let shade = base.usingColorSpace(.genericRGB) ?? base
    let shadeRGB = (r: shade.redComponent * 255,
                    g: shade.greenComponent * 255,
                    b: shade.blueComponent * 255)
    var mask = [UInt8](repeating: 0, count: px * px)
    var opaque = 0, ink = 0
    for y in 0..<px {
        for x in 0..<px {
            let pixel = data + y * stride + x * samples
            guard pixel[3] >= 200 else { continue }
            opaque += 1
            let r = CGFloat(pixel[0]), g = CGFloat(pixel[1]), b = CGFloat(pixel[2])
            let toWhite = pow(255 - r, 2) + pow(255 - g, 2) + pow(255 - b, 2)
            let toShade = pow(r - shadeRGB.r, 2) + pow(g - shadeRGB.g, 2) + pow(b - shadeRGB.b, 2)
            let isInk = toWhite < toShade
            if isInk { ink += 1 }
            mask[y * px + x] = isInk ? 2 : 1
        }
    }
    guard opaque > 0 else { return nil }

    var interest = 0
    for y in 0..<(px - 1) {
        for x in 0..<(px - 1) {
            let a = mask[y * px + x], b = mask[y * px + x + 1]
            let c = mask[(y + 1) * px + x], d = mask[(y + 1) * px + x + 1]
            guard a != 0, b != 0, c != 0, d != 0 else { continue }
            let count = (a == 2 ? 1 : 0) + (b == 2 ? 1 : 0) + (c == 2 ? 1 : 0) + (d == 2 ? 1 : 0)
            if count == 1 || count == 3 {
                interest += 1
            } else if count == 2, a == d, b == c, a != b {
                interest += 2
            }
        }
    }
    return (CGFloat(ink) / CGFloat(opaque), interest)
}

/// Walks a dense focus field at one zoom and greedily keeps the
/// highest-scoring crops that are not near an already-kept focus.
/// Crops that are 90 percent or more one colour never qualify. The
/// dedup gap shrinks as the zoom deepens: the viewport covers less of
/// the glyph, so nearer focuses show genuinely different crops.
func scoutFocuses(scale: CGFloat, base: NSColor, mark: Mark, keep: Int) -> [(focus: NSPoint, interest: Int)] {
    let span: CGFloat = 0.30, n = 41, minGap: CGFloat = 0.15 / scale
    var candidates: [(focus: NSPoint, interest: Int)] = []
    for row in 0..<n {
        let fy = span - 2 * span * CGFloat(row) / CGFloat(n - 1)
        for column in 0..<n {
            let fx = -span + 2 * span * CGFloat(column) / CGFloat(n - 1)
            guard let crop = analyzeCrop(scale: scale, focus: NSPoint(x: fx, y: fy), base: base, mark: mark),
                  crop.coverage >= 0.10, crop.coverage <= 0.90 else { continue }
            candidates.append((NSPoint(x: fx, y: fy), crop.interest))
        }
    }
    candidates.sort { $0.interest > $1.interest }

    var kept: [(focus: NSPoint, interest: Int)] = []
    for candidate in candidates where kept.count < keep {
        let crowded = kept.contains {
            max(abs($0.focus.x - candidate.focus.x), abs($0.focus.y - candidate.focus.y)) < minGap
        }
        if !crowded { kept.append(candidate) }
    }
    return kept
}

/// One row per zoom, the row holding that zoom's most interesting
/// crops from left to right. Deeper zooms earn proportionally more
/// picks (perUnit picks for each unit of zoom) because their smaller
/// viewport carves the glyph into more distinct crops. Labels carry
/// the zoom and the focus so a pick can be reproduced as a named
/// vignette style.
func writeScout(base: NSColor, mark: Mark, perUnit: CGFloat, to url: URL) {
    let quota = { (zoom: CGFloat) in max(1, Int((perUnit * zoom).rounded())) }
    let columns = scoutZooms.map(quota).max()!
    var cells: [(label: String, style: Style)] = []
    for zoom in scoutZooms {
        let keep = quota(zoom)
        let picks = scoutFocuses(scale: zoom, base: base, mark: mark, keep: keep)
        print("==> zoom \(zoom): kept \(picks.count) of \(keep) requested")
        for pick in picks {
            // Three decimals: at deep zooms a two-decimal rounding of
            // the focus moves the crop by a visible fraction of the tile.
            let label = String(format: "z%g %+.3f,%+.3f",
                               Double(zoom), pick.focus.x, pick.focus.y)
            cells.append((label, vignetteStyle(
                name: label, scale: zoom, focus: pick.focus, summary: "")))
        }
        for _ in picks.count..<columns {
            cells.append(("", Style(name: "blank", summary: "") { _ in }))
        }
    }
    writeSheet(cells: cells, columns: columns, base: base, mark: mark, to: url)
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

/// `--mark <name>` is stripped off the front before the positional
/// parsing below, so every subcommand takes it without any of them
/// having to count it.
func takeMark(_ arguments: [String]) -> (mark: Mark, rest: [String]) {
    var rest = arguments
    var chosen = marks[0]
    if rest.count >= 2, rest[1] == "--mark" {
        guard rest.count >= 3 else { fail("--mark needs a mark name") }
        guard let mark = marks.first(where: { $0.name == rest[2] }) else {
            fail("unknown mark \"\(rest[2])\"; run with --list to see the choices")
        }
        chosen = mark
        rest.removeSubrange(1...2)
    }
    return (chosen, rest)
}

let (mark, arguments) = takeMark(CommandLine.arguments)

if arguments.count == 2, arguments[1] == "--list" {
    for mark in marks {
        print("mark \(mark.name)\t\(mark.summary)")
    }
    for style in styles {
        print("\(style.name)\t\(style.summary)")
    }
    exit(0)
}

if arguments.count == 4, arguments[1] == "--sheet" {
    writeSheet(cells: styles.map { ($0.name, $0) }, columns: 4,
               base: parseShade(arguments[2]), mark: mark,
               to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}

if arguments.count == 4 || arguments.count == 5, arguments[1] == "--scout" {
    let perUnit = arguments.count == 5 ? Double(arguments[4]) ?? 0 : 4
    guard perUnit > 0 else { fail("perUnit must be a positive number, got \"\(arguments[4])\"") }
    writeScout(base: parseShade(arguments[2]), mark: mark, perUnit: CGFloat(perUnit),
               to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}

if arguments.count == 5 || arguments.count == 6, arguments[1] == "--sweep" {
    guard let scale = Double(arguments[2]), scale > 0 else {
        fail("zoom must be a positive number, got \"\(arguments[2])\"")
    }
    let n = arguments.count == 6 ? Int(arguments[5]) ?? 0 : 10
    guard n >= 2 else { fail("grid must be at least 2, got \"\(arguments[5])\"") }
    writeSweep(scale: CGFloat(scale), base: parseShade(arguments[3]), mark: mark, n: n,
               to: URL(fileURLWithPath: arguments[4]))
    exit(0)
}

guard arguments.count == 4, !arguments[1].hasPrefix("--") else {
    let styleNames = styles.map(\.name).joined(separator: "|")
    let markNames = marks.map(\.name).joined(separator: "|")
    fail("""
    usage: swift render-icon.swift [--mark <mark>] <style> <rrggbb> <output.iconset>
           swift render-icon.swift [--mark <mark>] --sheet <rrggbb> <output.png>
           swift render-icon.swift [--mark <mark>] --sweep <zoom> <rrggbb> <output.png> [grid]
           swift render-icon.swift [--mark <mark>] --scout <rrggbb> <output.png> [perUnit]
           swift render-icon.swift --list
    marks:  \(markNames)
    styles: \(styleNames)
    """)
}

guard let style = styles.first(where: { $0.name == arguments[1] }) else {
    fail("unknown style \"\(arguments[1])\"; run with --list to see the choices")
}

writeIconset(style: style, base: parseShade(arguments[2]), mark: mark,
             to: URL(fileURLWithPath: arguments[3], isDirectory: true))
