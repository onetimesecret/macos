// The onetimesecret.com logo mark, read from the SVG that ships with
// this module. The same file is the source of the app icon, which
// scripts/render-icon.swift renders with its own copy of this parser:
// the icon is built before there is an app, so the two cannot share
// code, but they must not disagree about the art. One asset, read the
// same way, is how that is kept true.
//
// Only what a hand written two path logo needs is parsed. Anything
// richer belongs in a real SVG library, and is refused here rather
// than drawn wrong.

import AppKit

/// Only here to name a class in this module for `Bundle(for:)`, which
/// is how the module finds the bundle it was linked into.
private final class BundleToken {}

/// Main actor because the art is drawn, and AppKit drawing is the main
/// thread's work; that is also what makes the parsed cache safe to hold.
@MainActor
public enum LogoMark {
    /// The mark fitted into a square image `side` points a side and
    /// filled flat black, marked as a template so the menu bar tints it
    /// for the current appearance and for selection. `inset` is the
    /// fraction of the side the art is fitted to, leaving the optical
    /// margin a status item wants.
    ///
    /// Nil when the asset is missing or unparseable, which leaves the
    /// caller to fall back rather than take the app down over an icon.
    /// `LogoMarkTests` is what actually holds the asset to its shape.
    public static func templateImage(side: CGFloat, inset: CGFloat = 0.86) -> NSImage? {
        guard let art = mark else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            fitted(art, into: rect, fraction: inset).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The mark fitted into `rect`, scaled to `fraction` of the shorter
    /// side and centred. The path arrives in SVG coordinates, y running
    /// down, so the fit flips y.
    static func fitted(_ art: (path: NSBezierPath, bounds: CGRect),
                       into rect: NSRect, fraction: CGFloat) -> NSBezierPath {
        let box = min(rect.width, rect.height) * fraction
        let k = box / max(art.bounds.width, art.bounds.height)
        let width = art.bounds.width * k, height = art.bounds.height * k

        let fit = NSAffineTransform()
        fit.translateX(by: rect.midX - width / 2, yBy: rect.midY - height / 2 + height)
        fit.scaleX(by: k, yBy: -k)
        fit.translateX(by: -art.bounds.minX, yBy: -art.bounds.minY)
        let path = fit.transform(art.path)
        path.windingRule = .nonZero
        return path
    }

    /// Parsed on first use and kept: the tray asks for its image on
    /// every appearance change.
    static let mark: (path: NSBezierPath, bounds: CGRect)? = {
        guard let url = assetURL,
              let svg = try? String(contentsOf: url, encoding: .utf8),
              let path = parse(svg: svg)
        else { return nil }
        return (path, path.bounds)
    }()

    static let assetName = "onetime-logo-v3-xl"

    /// Where the art actually is, which differs by how the code is
    /// running. `Bundle.module` is not used on purpose: SwiftPM's
    /// accessor looks for its bundle beside `Bundle.main`, which for an
    /// app is the directory holding OnetimePad.app rather than anywhere
    /// inside it, and it calls `fatalError` when the lookup misses. That
    /// is a crash on someone else's Mac in exchange for an icon.
    static let assetURL: URL? = {
        // The shipped app, where scripts/package-app.sh puts the asset.
        if let url = Bundle.main.url(forResource: assetName, withExtension: "svg") { return url }
        // `swift run` and `swift test`, where SwiftPM leaves the
        // resource bundle beside the binary or beside the test bundle
        // this module is linked into.
        let home = Bundle(for: BundleToken.self).bundleURL
        for directory in [home, home.deletingLastPathComponent()] {
            let path = directory.appendingPathComponent("OnetimePad_CompanionKit.bundle").path
            if let url = Bundle(path: path)?.url(forResource: assetName, withExtension: "svg") {
                return url
            }
        }
        return nil
    }()

    /// The mark alone: every path in the document except a full bleed
    /// plate, which is the artwork's background rather than its
    /// subject. Fills are dropped because the caller tints the mark.
    static func parse(svg: String) -> NSBezierPath? {
        guard let head = svg.range(of: "<svg[^>]*>", options: .regularExpression),
              let width = attribute("width", of: String(svg[head])).flatMap(Double.init),
              let height = attribute("height", of: String(svg[head])).flatMap(Double.init),
              width > 0, height > 0
        else { return nil }

        let mark = NSBezierPath()
        for tag in pathTags(in: svg) {
            guard let d = attribute("d", of: tag) else { continue }
            guard let path = parse(d: d) else { return nil }
            if let transform = attribute("transform", of: tag) {
                let offsets = transform.components(separatedBy: CharacterSet(charactersIn: "(,)"))
                    .compactMap(Double.init)
                guard transform.hasPrefix("translate("), offsets.count == 2 else { return nil }
                let shift = NSAffineTransform()
                shift.translateX(by: CGFloat(offsets[0]), yBy: CGFloat(offsets[1]))
                path.transform(using: shift as AffineTransform)
            }
            let box = path.bounds
            let plate = box.width >= 0.99 * width && box.height >= 0.99 * height
            if !plate { mark.append(path) }
        }
        return mark.isEmpty ? nil : mark
    }

    /// One `d` attribute as a bezier path, in the SVG's own coordinates.
    /// Moves, lines, cubics, and closes, absolute and relative, with the
    /// implicit repeat of a command's coordinate sets. Any other command
    /// gives up rather than drawing a wrong mark.
    static func parse(d: String) -> NSBezierPath? {
        let path = NSBezierPath()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\r\t")
        var command: Character = " "
        var current = NSPoint.zero, subpathStart = NSPoint.zero
        var malformed = false

        func number() -> CGFloat {
            guard let value = scanner.scanDouble() else {
                malformed = true
                return 0
            }
            return CGFloat(value)
        }
        func point(relative: Bool) -> NSPoint {
            let x = number(), y = number()
            return relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
        }

        while !malformed {
            let start = scanner.currentIndex
            guard let next = scanner.scanCharacter() else { break }
            if next.isLetter {
                command = next
            } else {
                scanner.currentIndex = start
                guard command != " " else { return nil }
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
                return nil
            }
        }
        return malformed ? nil : path
    }

    /// The value of one attribute of one tag, or nil when the tag has
    /// no such attribute.
    static func attribute(_ name: String, of tag: String) -> String? {
        guard let range = tag.range(of: "\\b\(name)=\"[^\"]*\"", options: .regularExpression),
              let open = tag[range].firstIndex(of: "\""),
              let close = tag[range].lastIndex(of: "\""), open < close
        else { return nil }
        return String(tag[range][tag.index(after: open)..<close])
    }

    /// Every `<path …>` tag in the document, in document order.
    static func pathTags(in svg: String) -> [String] {
        var tags: [String] = []
        var from = svg.startIndex
        while let range = svg.range(of: "<path[^>]*>", options: .regularExpression,
                                    range: from..<svg.endIndex) {
            tags.append(String(svg[range]))
            from = range.upperBound
        }
        return tags
    }
}
