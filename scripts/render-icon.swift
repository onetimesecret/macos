// Renders one app icon as a complete .iconset directory: the ㊙ maruhi
// in white over a rounded-rect tile in the shade given on the command
// line (scripts/build-icons.sh picks the shade).
//
// Run by scripts/build-icons.sh via `swift render-icon.swift <rrggbb>
// <out.iconset>`; not part of the Swift package.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift render-icon.swift <rrggbb> <output.iconset>")
}

let hex = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
    fail("shade must be six hex digits, got \"\(hex)\"")
}
let base = NSColor(
    calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
    green: CGFloat((rgb >> 8) & 0xFF) / 255,
    blue: CGFloat(rgb & 0xFF) / 255,
    alpha: 1
)

/// One square rendering at `px` pixels: transparent margins, the tile
/// on Apple's icon grid (824/1024 of the canvas, corners at 185/824 of
/// the tile), a slight top-lit gradient of the shade, and the maruhi
/// centred in white. U+FE0E forces the text presentation so the glyph
/// takes our colour instead of arriving as the orange emoji.
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
    let lit = base.blended(withFraction: 0.10, of: .white) ?? base
    let shaded = base.blended(withFraction: 0.14, of: .black) ?? base
    NSGradient(starting: lit, ending: shaded)?.draw(in: path, angle: -90)

    let glyph = "㊙\u{FE0E}" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: tile.height * 0.72),
        .foregroundColor: NSColor.white,
    ]
    let size = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2),
        withAttributes: attributes
    )
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
