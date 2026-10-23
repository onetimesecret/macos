import AppKit
import XCTest

@testable import CompanionKit

// Throwaway adversarial probes; prints results, asserts nothing. Delete before finishing.
@MainActor
final class ZZAdversarialProbeTests: XCTestCase {
    private func page(_ parts: [String?]) -> (String, [Int]) {
        var text = ""
        var offsets: [Int] = []
        var length = 0
        for part in parts {
            if let part {
                text += part
                length += part.utf16.count
            } else {
                offsets.append(length)
                text += "\u{FFFC}"
                length += 1
            }
        }
        return (text, offsets)
    }

    private func esc(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0A: out += "\\n"
            case 0xFFFC: out += "<FFFC>"
            case 0x2028: out += "<LS>"
            case 0x100000...0x10FFFF: out += String(format: "<U+%X>", scalar.value)
            case 0..<0x20: out += String(format: "<%02X>", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func d(_ parts: [HTMLPart]?) -> String {
        guard let parts else { return "nil" }
        return "[" + parts.map { part -> String in
            switch part {
            case .text(let t): return "'" + esc(t) + "'"
            case .object(let id): return "#" + id
            }
        }.joined(separator: ",") + "]"
    }

    private func d(_ events: [PreviewEvent]) -> String {
        events.map { event -> String in
            switch event {
            case .text(let t): return "'" + esc(t) + "'"
            case .object(let id): return "#" + id
            case .enterMarkdown(let t): return "<\(t)>"
            case .leaveMarkdown(let t): return "</\(t)>"
            case .blockBoundary: return "|bb|"
            case .softBreak: return "~s"
            case .hardBreak: return "~h"
            case .rawHTML(let p): return "raw" + d(p)
            case .markdownImage(let alt, let dest, let title):
                return "img(alt=\(d(alt)) dest=\(d(dest)) title=\(d(title)))"
            case .enterLink(let dest, let title): return "<a dest=\(d(dest)) title=\(d(title))>"
            case .leaveLink: return "</a>"
            }
        }.joined(separator: " ")
    }

    private func d(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let e): return "P{" + d(e) + "}"
            case .heading(let l, let e): return "H\(l){" + d(e) + "}"
            case .codeBlock(let info, let lit): return "CODE{info=\(d(info)) lit=\(d(lit))}"
            case .html(let p): return "HTML{" + d(p) + "}"
            case .thematicBreak: return "HR"
            case .quote(let c): return "Q{" + d(c) + "}"
            case .list(let o, let s, let t, let items):
                return "L(\(o ? "ol" : "ul"),\(s),\(t ? "tight" : "loose")){"
                    + items.map { "I(\($0.task.map { "\($0)" } ?? "-")){" + d($0.blocks) + "}" }.joined(separator: " ")
                    + "}"
            case .table(let a, let h, let b):
                return "T(\(a.count)){h=" + h.map { "[" + d($0) + "]" }.joined() + " b="
                    + b.map { "{" + $0.map { "[" + d($0) + "]" }.joined() + "}" }.joined() + "}"
            case .objects(let ids): return "OBJ" + ids.description
            }
        }.joined(separator: " ")
    }

    private func probe(_ name: String, _ parts: [String?], dialects: [PreviewDialect] = PreviewDialect.allCases) {
        let (text, offsets) = page(parts)
        for dialect in dialects {
            do {
                let doc = try MarkdownParser.parse(text, objects: offsets, dialect: dialect)
                print("PROBE|\(name)|\(dialect)|\(d(doc.blocks))")
            } catch {
                print("PROBE|\(name)|\(dialect)|THROW \(error)")
            }
        }
    }

    private func chips(_ parts: [String?]) -> (NSAttributedString, [ChipAttachment]) {
        let text = NSMutableAttributedString(string: "")
        var chips: [ChipAttachment] = []
        for part in parts {
            if let part {
                text.append(NSAttributedString(string: part))
            } else {
                let chip = ChipAttachment(info: ChipInfo(
                    chipId: UInt64(chips.count), kind: "text", excerpt: "f", sizeLabel: "small", concealed: false
                ))
                chips.append(chip)
                text.append(NSAttributedString(attachment: chip))
            }
        }
        return (text, chips)
    }

    private func dumpRendered(_ r: NSAttributedString) -> String {
        var out = ""
        let ns = r.string as NSString
        var i = 0
        while i < r.length {
            let c = ns.character(at: i)
            if let chip = r.attribute(.attachment, at: i, effectiveRange: nil) as? ChipAttachment {
                out += "[c\(chip.info.chipId)\(r.attribute(.link, at: i, effectiveRange: nil) != nil ? "+LINK" : "")]"
            } else if c == 0xFFFC {
                out += "<bareFFFC>"
            } else {
                out += esc(ns.substring(with: NSRange(location: i, length: 1)))
            }
            i += 1
        }
        var links: [String] = []
        r.enumerateAttribute(.link, in: NSRange(location: 0, length: r.length)) { v, range, _ in
            if let v { links.append("'\(esc(ns.substring(with: range)))'->\(v)") }
        }
        var images: [String] = []
        r.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: r.length)) { v, range, _ in
            if let v = v as? PreviewImageDescriptor { images.append("'\(esc(ns.substring(with: range)))'=\(v.destination)") }
        }
        return out + " LINKS=\(links) IMAGES=\(images)"
    }

    private func probeRender(_ name: String, _ parts: [String?], dialects: [PreviewDialect] = PreviewDialect.allCases) {
        let (source, _) = chips(parts)
        for dialect in dialects {
            let rendered = MarkdownPreviewView.render(source, dialect: dialect)
            print("RENDER|\(name)|\(dialect)|\(dumpRendered(rendered))")
        }
    }

    // MARK: Placement and order

    func testP01Placement() {
        probe("tablepara-order-1", ["X\n\n[a]: /u \"", nil, "\"\n\nA\n\nB\n| h |\n|---|\n"])
        probe("tablepara-order-2", ["[a]: /u \"", nil, "\"\n\nB\n| h |\n|---|\n| c | ", nil, " |\n"])
        probe("tablepara-def-same-para", ["[a]: /u \"", nil, "\"\nB\n| h |\n|---|\n\n[x][a]"])
        probe("tablepara-3blocks", ["X\n\n[a]: /u \"", nil, "\"\n\nA\n\nB\n| h |\n|---|\n\nC\n\nD\n| h |\n|---|\n"])
        probe("list-multipara-def", ["- a\n\n  [b]: /u \"", nil, "\"\n\n  c ", nil, "\n- d\n"])
        probe("quote-lazy-title", ["> [a]: /u\n\"", nil, "\"\n\nafter ", nil])
        probe("list-lazy-title", ["- [a]: /u\n\"", nil, "\"\n- b"])
        probe("quote-in-list-def", ["- > [a]: /u \"", nil, "\"\n  > q\n\n  tail\n- next"])
        probe("setext-def", ["[a]: /u \"", nil, "\"\nFoo ", nil, "\n===\n"])
        probe("def-after-table-line", ["| h |\n|---|\n[a]: /u \"", nil, "\"\n"])
        probe("excess-quote", ["> | a |\n> |---|\n> | b | ", nil, " |\n\nafter"])
        probe("excess-list", ["- | a |\n  |---|\n  | b | ", nil, " |\n\n  more\n- next"])
        probe("excess-then-def", ["| a |\n|---|\n| b | ", nil, " |\n\n[r]: /u ", nil, "\n\nz"])
        probe("def-in-quote-after-para", ["> para\n>\n> [a]: /u \"", nil, "\"\n\nout"])
        probe("two-defs-dup", ["[a]: /u", nil, "\n[a]: /v", nil, "\n\n[a]"])
        probe("def-heading-atx", ["# H\n[a]: /u", nil, "\nz"])
        probe("def-in-list-item-second-para-start", ["1. x\n\n   [a]: /u \"", nil, "\"\n2. y"])
        probe("def-lazy-multiline-title", ["[a]: /u \"line1\n", nil, "\nline3\"\n\nz"])
        probe("def-lazy-quote-multiline-title", ["> [a]: /u \"line1\n", nil, "\nline3\"\n\nz"])
        probe("html-block-def", ["<div>\n[a]: /u \"", nil, "\"\n</div>"])
        probe("code-fence-def", ["```\n[a]: /u \"", nil, "\"\n```"])
        probe("tablepara-quote", ["> X\n>\n> [a]: /u \"", nil, "\"\n>\n> A\n>\n> B\n> | h |\n> |---|\n"])
        probe("tablepara-escaped-pipe", ["B \\| ", nil, "\n| h |\n|---|\n"])
    }

    func testP01Render() {
        probeRender("tablepara-order-1", ["X\n\n[a]: /u \"", nil, "\"\n\nA\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        probeRender("tablepara-3blocks", ["X\n\n[a]: /u \"", nil, "\"\n\nA\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
    }

    // MARK: Forgery

    func testP02Forgery() {
        let refs = ["&#x100000;", "&#X100000;", "&#1048576;", "&#01048576;", "&#x0100000;", "&#0000001048576;"]
        for (i, r) in refs.enumerated() {
            probe("ref\(i)-text", ["a \(r) ", nil, " z"])
            probe("ref\(i)-dest", ["[x](\(r)) ", nil])
            probe("ref\(i)-dest-angle", ["[x](<\(r)>) ", nil])
            probe("ref\(i)-title", ["[x](/u \"\(r)\") ", nil])
            probe("ref\(i)-code", ["`\(r)` ", nil])
            probe("ref\(i)-html", ["<a href=\"\(r)\">x</a> ", nil])
            probe("ref\(i)-label", ["[\(r)]: /u\n\n[\(r)] ", nil])
            probe("ref\(i)-info", ["```\(r)\nx\n```\n", nil])
            probe("ref\(i)-autolink", ["<http://a/\(r)> ", nil])
            probe("ref\(i)-alt", ["![\(r)](/u) ", nil])
            probe("ref\(i)-defurl", ["[a]: \(r)\n\n[a] ", nil])
        }
        probe("literal-adjacent", ["\u{100000}", nil, "\u{100001}", nil, "\u{100002}"])
        probe("bare-fffc", ["a \u{FFFC} ", nil, " [x](http://e.example/\u{FFFC}) [y]: <\u{FFFC}>"])
        probe("bare-fffc-def", ["[r]: http://e.example/\u{FFFC}\n\n[q][r] ", nil])
        probe("nul", ["a\u{0}", nil, "\u{0}b"])
        probe("bom", ["\u{FEFF}[a]: /u \"", nil, "\"\n\ntext"])
        probe("bom2", ["\u{FEFF}\u{FEFF}[a]: /u \"", nil, "\"\n\ntext"])
        probe("cr", ["[a]: /u\r\"", nil, "\"\r\rtext\r", nil, "\r"])
        probe("crlf-obj", ["x\r", nil, "\ny"])
        probe("plane16-noncharacter", ["\u{10FFFE}\u{10FFFF}", nil])
        probe("plane15", ["\u{F0001}", nil, "\u{FFFFD}"])
        probe("hexref-uppercase-digits", ["&#X10000A; &#x10000a; ", nil])
        probe("ref-noncharacter", ["&#x10FFFE; ", nil])
    }

    func testP02ForgeryRender() {
        probeRender("bare-fffc", ["a \u{FFFC} ", nil, " [x](http://e.example/\u{FFFC}) z"])
        probeRender("bare-only", ["a \u{FFFC} [x](http://e.example/) z"])
        probeRender("bare-in-def", ["[r]: http://e.example/\u{FFFC}\n\n[q][r] ", nil])
        probeRender("ots-token", ["[x](http://e.example/OTSAttachment) ", nil])
    }

    // MARK: Links

    func testP03Links() {
        probeRender("refused-md-with-html-a", ["[<a href=\"https://evil.example/\">x</a>](javascript:alert) ", nil])
        probeRender("html-a-around-obj-md", ["<a href=\"https://evil.example/\">[x](", nil, ")</a>"])
        probeRender("html-a-around-refused-md", ["<a href=\"https://evil.example/\">[x](/rel) y</a>"])
        probeRender("def-title-obj", ["[x][r]\n\n[r]: https://e.example/ \"t ", nil, "\""])
        probeRender("inline-title-obj", ["[x](https://e.example/ \"", nil, "\")"])
        probeRender("img-title-obj", ["![x](https://e.example/i.png \"", nil, "\")"])
        probeRender("refimg-def-title-obj", ["![x][r]\n\n[r]: https://e.example/i.png \"", nil, "\""])
        probeRender("obj-label-only", ["[", nil, "](https://e.example/)"])
        probeRender("obj-in-label", ["[a ", nil, " b](https://e.example/)"])
        probeRender("www-after-obj", [nil, "www.example.com"], dialects: [.gfm])
        probeRender("www-obj-path", ["www.example.com/", nil, "path"], dialects: [.gfm])
        probeRender("http-obj", ["http://", nil, "x.com"], dialects: [.gfm])
        probeRender("http-host-obj", ["http://x", nil, ".com"], dialects: [.gfm])
        probeRender("email-obj", ["a", nil, "@b.com x", nil, "@y.org"], dialects: [.gfm])
        probeRender("mailto-obj", ["mailto:a", nil, "@b.com"], dialects: [.gfm])
        probeRender("angle-dest-obj", ["[x](<https://e.example/", nil, ">)"])
        probeRender("nested-img-link-img", ["[![a](https://e.example/i \"", nil, "\")](https://e.example/ \"", nil, "\")"])
        probeRender("img-in-img-in-link", ["[![a ![b](https://e.example/j", nil, ") c](https://e.example/i)](https://e.example/)"])
        probeRender("link-in-img-alt", ["![a [b](https://e.example/", nil, ") c](https://e.example/i)"])
        probeRender("link-in-link", ["[a [b](https://e.example/", nil, ") c](https://e.example/z", nil, ")"])
        probeRender("autolink-in-link", ["[a <https://e.example/", nil, "> b](https://e.example/)"])
        probeRender("www-in-link-text", ["[www.a.com", nil, "](https://e.example/)"], dialects: [.gfm])
        probeRender("ref-with-obj-label-text", ["[a ", nil, "][r]\n\n[r]: https://e.example/"])
        probeRender("html-a-inside-md-link-closes-outside", ["[x <a href=\"https://evil.example/\">y](https://e.example/) z</a>"])
        probeRender("md-link-inside-html-a-href-obj", ["<a href=\"https://e.example/", nil, "\">[x](https://ok.example/) y</a>"])
        probeRender("html-img-src-obj", ["<img src=\"https://e.example/", nil, "\" alt=\"q\">"])
        probeRender("html-img-src-entity-fffc", ["<img src=\"https://e.example/&#xFFFC;\" alt=\"q\"> ", nil])
        probeRender("md-img-dest-entity-fffc", ["![q](https://e.example/&#xFFFC;) ", nil])
        probeRender("md-img-dest-entity-plane16", ["![q](https://e.example/&#x100000;) ", nil])
        probeRender("md-link-dest-bare-ffc-entity", ["[q](https://e.example/&#65532;) ", nil])
        probeRender("link-title-only-bare", ["[q](https://e.example/ \"\u{FFFC}\") ", nil])
        probeRender("autolink-angle-email-obj", ["<a", nil, "@b.com>"])
        probeRender("javascript", ["[x](javascript:alert(1)) <a href=\"javascript:alert(1)\">y</a> ", nil])
        probeRender("data-uri-img", ["![x](data:image/png;base64,AAAA) ", nil])
    }

    func testP04Dialects() {
        probe("dialect-gfm-only", ["~~s~~ ", nil, " www.a.com\n\n- [ ] t\n\n| a |\n|---|\n| b |\n"])
        probeRender("dialect-render", ["~~s~~ ", nil, " www.a.com\n\n- [ ] t\n\n| a |\n|---|\n| b |\n"])
        probe("tilde-single", ["~a~ ", nil])
        probe("tagfilter", ["<script>x", nil, "</script>\n\n<title>", nil, "</title>"])
        probeRender("tagfilter-render", ["<script>x", nil, "</script>\n\n<title>", nil, "</title>"])
    }

    // MARK: Batch 2

    func testP05OrderDisplacement() {
        var parts: [String?] = ["[a]: /u \"", nil, "\"\n\nFIRST\n\n"]
        for i in 0..<8 { parts.append("B\(i)\n| h |\n|---|\n\n") }
        probe("disp-8tables", parts, dialects: [.gfm])
        var far: [String?] = ["[a]: /u \"", nil, "\"\n\n"]
        for i in 0..<8 { far.append("B\(i)\n| h\(i) |\n|---|\n\n") }
        probe("disp-far", far, dialects: [.gfm])
        probeRender("disp-far", far, dialects: [.gfm])
        var parts2: [String?] = ["X\n\n"]
        for i in 0..<6 { parts2.append("A\(i)\n\n") }
        parts2 += ["[a]: /u \"", nil, "\"\n\n"]
        for i in 0..<6 { parts2.append("C\(i)\n\n") }
        parts2.append("B\n| h |\n|---|\n")
        probe("disp-mid", parts2, dialects: [.gfm])
        probeRender("def-title-obj-cm", ["[x][r]\n\n[r]: https://e.example/ \"t ", nil, "\""], dialects: [.commonMark])
        // excess cell objects and a later table-with-paragraph
        probe("disp-excess", ["| a |\n|---|\n| b | ", nil, " |\n\nM\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        // definition objects inside list item before table paragraph
        probe("disp-item", ["- X\n\n  [a]: /u \"", nil, "\"\n\n  A\n\n  B\n  | h |\n  |---|\n"], dialects: [.gfm])
    }

    private func timed(_ name: String, _ text: String, objects: [Int] = [], render: Bool = true, layout: Bool = false,
                       dialects: [PreviewDialect] = PreviewDialect.allCases) {
        for dialect in dialects {
            let t0 = Date()
            var outcome = ""
            do {
                let doc = try MarkdownParser.parse(text, objects: objects, dialect: dialect)
                outcome = "blocks=\(doc.blocks.count)"
            } catch { outcome = "THROW \(error)" }
            let parse = Date().timeIntervalSince(t0)
            var rendered = -1.0
            var laid = -1.0
            var info = ""
            if render {
                let source = NSMutableAttributedString(string: text)
                for offset in objects {
                    let chip = ChipAttachment(info: ChipInfo(
                        chipId: UInt64(offset), kind: "text", excerpt: "f", sizeLabel: "small", concealed: false))
                    source.addAttribute(.attachment, value: chip, range: NSRange(location: offset, length: 1))
                }
                let t2 = Date()
                let r = MarkdownPreviewView.render(source, dialect: dialect)
                rendered = Date().timeIntervalSince(t2)
                var count = 0
                r.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.length)) { v, range, _ in
                    if v != nil { count += range.length }
                }
                info = "len=\(r.length) attachments=\(count)/\(objects.count)"
                if layout {
                    let storage = NSTextStorage(attributedString: r)
                    let manager = NSLayoutManager()
                    storage.addLayoutManager(manager)
                    let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
                    manager.addTextContainer(container)
                    let t4 = Date()
                    manager.ensureLayout(for: container)
                    laid = Date().timeIntervalSince(t4)
                }
            }
            print("PERF|\(name)|\(dialect)|scalars=\(text.unicodeScalars.count) parse=\(String(format: "%.3f", parse))s \(outcome) render=\(String(format: "%.3f", rendered))s layout=\(String(format: "%.3f", laid))s \(info)")
        }
    }

    private func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

    func testP06PathoInline() {
        timed("nested-strong-emph", rep("*a **a ", 40_000) + "b" + rep(" a** a*", 40_000))
        timed("emph-closers", rep("a_ ", 300_000))
        timed("emph-openers", rep("_a ", 300_000))
        timed("link-closers", rep("a]", 400_000))
        timed("link-openers", rep("[a", 400_000))
        timed("mismatched", rep("*a_ ", 200_000))
        timed("mult3", "a**b" + rep("c* ", 300_000))
        timed("linkopen-emphclose", rep("[ a_", 200_000))
        timed("bracket-paren", rep("[ (](", 150_000))
        timed("nested-brackets", rep("[", 300_000) + "a" + rep("]", 300_000))
        timed("unclosed-link-a", rep("[a](<b", 150_000))
        timed("unclosed-link-b", rep("[a](b", 150_000))
        timed("unclosed-comment", "</" + rep("<!--", 200_000))
        var ticks = ""
        for i in 1..<1000 { ticks += "e" + rep("`", i) }
        timed("backticks", ticks)
        timed("nested-images", rep("![", 200_000) + "a" + rep("](u)", 200_000))
    }

    func testP07PathoBlock() {
        timed("nested-quotes", rep("> ", 300_000) + "a")
        timed("nested-bullets", rep("- ", 300_000) + "a")
        timed("nested-ordered", rep("1. ", 200_000) + "a")
        var indented = ""
        for i in 0..<1000 { indented += rep(" ", i) + "* a\n" }
        timed("nested-lists-indented", indented)
        timed("quote-lines", rep("> > > > > > > > > > a\n", 40_000))
        timed("list-items", rep("- a\n", 200_000))
        timed("soft-breaks", rep("a\n", 400_000))
        timed("amp-entities", rep("&amp;", 190_000))
        timed("headings", rep("# h\n", 200_000))
        timed("fences", rep("```\na\n```\n", 90_000))
        timed("html-blocks", rep("<div>\n\n", 120_000))
        timed("br-tags", rep("<br>", 200_000))
        timed("links", rep("[a](http://e.example/) ", 40_000))
        timed("images", rep("![a](http://e.example/) ", 40_000))
    }

    func testP08PathoRefs() {
        var defs = ""
        for i in 0..<50_000 { defs += "[r\(i)]: /u\n" }
        timed("many-defs", defs + "\n" + rep("[r0] ", 50_000))
        timed("long-url-many-uses", "[r]: /" + rep("a", 300_000) + "\n\n" + rep("[r]", 200_000))
        timed("dup-defs", rep("[r]: /u\n", 100_000) + "\n[r]")
        var defsObj = ""
        var offsets: [Int] = []
        for i in 0..<30_000 {
            let line = "[r\(i)]: /u \""
            offsets.append(defsObj.utf16.count + line.utf16.count)
            defsObj += line + "\u{FFFC}\"\n"
        }
        timed("defs-with-objects", defsObj + "\ntext", objects: offsets)
        var deep = rep("> ", 60)
        var deepText = ""
        var deepOffsets: [Int] = []
        for i in 0..<20_000 {
            let line = deep + "[r\(i)]: /u \""
            deepOffsets.append(deepText.utf16.count + line.utf16.count)
            deepText += line + "\u{FFFC}\"\n"
        }
        deep = ""
        timed("deep-defs-with-objects", deepText + "\ntext", objects: deepOffsets)
    }

    func testP09PathoObjects() {
        let n = 65_534
        let text = rep("\u{FFFC} ", n)
        timed("max-objects", text, objects: (0..<n).map { $0 * 2 })
        let over = rep("\u{FFFC} ", 65_535)
        timed("over-objects", over, objects: (0..<65_535).map { $0 * 2 }, render: true)
        var all = ""
        for v in 0x10_0000...0x10_FFFD { all.unicodeScalars.append(Unicode.Scalar(UInt32(v))!) }
        timed("all-plane16-one-object", all + "\u{FFFC}", objects: [all.utf16.count])
        timed("numeric-ref-scan", rep("&#", 300_000) + "&#" + rep("1", 300_000) + ";")
        timed("objects-in-link-dests", rep("[a](http://e.example/\u{FFFC}) ", 20_000),
              objects: (0..<20_000).map { $0 * 24 + 21 })
    }

    func testP10PathoGFM() {
        let cols = 1000
        let header = "|" + rep("a|", cols) + "\n|" + rep("-|", cols) + "\n"
        timed("table-1000x500", header + rep("x\n", 500), layout: false, dialects: [.gfm])
        timed("table-200x200", "|" + rep("a|", 200) + "\n|" + rep("-|", 200) + "\n" + rep("x\n", 200), layout: true, dialects: [.gfm])
        timed("table-rows", "| a |\n|---|\n" + rep("| b |\n", 150_000), dialects: [.gfm])
        timed("table-wide-row", "| a |\n|---|\n" + rep("|", 900_000), dialects: [.gfm])
        timed("autolink-at", rep("a@", 300_000), dialects: [.gfm])
        timed("autolink-at-dot", rep("a.b@", 200_000), dialects: [.gfm])
        timed("autolink-www", rep("www.a ", 150_000), dialects: [.gfm])
        timed("autolink-http", rep("http://a ", 100_000), dialects: [.gfm])
        timed("autolink-colon", rep(":", 900_000), dialects: [.gfm])
        timed("strike", rep("~~a ", 200_000), dialects: [.gfm])
        timed("tildes", rep("~", 900_000), dialects: [.gfm])
        timed("pipes", rep("|", 900_000), dialects: [.gfm])
        timed("tasks", rep("- [ ] a\n", 100_000), dialects: [.gfm])
        timed("www-placeholder", rep("www.a\u{FFFC}", 100_000), objects: (0..<65_000).map { $0 * 6 + 5 }, dialects: [.gfm])
    }
}

extension ZZAdversarialProbeTests {
    func testP12Batch3() {
        probe("out-of-quote", ["> [a]: /u \"", nil, "\"\n> q\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        probeRender("out-of-quote", ["> [a]: /u \"", nil, "\"\n> q\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        probe("out-of-list", ["- [a]: /u \"", nil, "\"\n  q\n- r\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        probe("excess-out-of-quote", ["> | a |\n> |---|\n> | b | ", nil, " |\n\nB\n| h |\n|---|\n"], dialects: [.gfm])
        probeRender("fallback-crlf", [rep("> ", 70), "x\r\n", nil, "\r\nz\r", nil])
        probeRender("task-object-first", ["- [ ] ", nil, "\n- ", nil, " b"], dialects: [.gfm])
        probeRender("item-objects-first", ["- [a]: /u ", nil, "\n  text\n- b"])
        probe("header-para-object", ["B ", nil, "\n| h |\n|---|\n| c | ", nil, " | ", nil, " |\n"], dialects: [.gfm])
        probeRender("header-para-object", ["B ", nil, "\n| h |\n|---|\n| c | ", nil, " | ", nil, " |\n"], dialects: [.gfm])
        timed("nested-images-200k", rep("![", 100_000) + "a" + rep("](u)", 100_000))
        var deepText = ""
        var deepOffsets: [Int] = []
        let deep = rep("> ", 60)
        for i in 0..<5_000 {
            let line = deep + "[r\(i)]: /u \""
            deepOffsets.append(deepText.utf16.count + line.utf16.count)
            deepText += line + "\u{FFFC}\"\n"
        }
        timed("deep-defs-with-objects", deepText + "\ntext", objects: deepOffsets)
    }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private func identitiesOf(_ blocks: [MarkdownBlock]) -> [String] {
        func ev(_ events: [PreviewEvent]) -> [String] {
            events.flatMap { e -> [String] in
                switch e {
                case .object(let i): return [i]
                case .rawHTML(let p): return p.objectIdentities
                case .markdownImage(let a, let d, let t): return (a + (d ?? []) + t).objectIdentities
                case .enterLink(let d, let t): return ((d ?? []) + t).objectIdentities
                default: return []
                }
            }
        }
        return blocks.flatMap { b -> [String] in
            switch b {
            case .paragraph(let e), .heading(_, let e): return ev(e)
            case .codeBlock(let i, let l): return (i + l).objectIdentities
            case .html(let p): return p.objectIdentities
            case .thematicBreak: return []
            case .quote(let c): return identitiesOf(c)
            case .list(_, _, _, let items): return items.flatMap { identitiesOf($0.blocks) }
            case .table(_, let h, let body): return (h + body.flatMap { $0 }).flatMap(ev)
            case .objects(let o): return o
            }
        }
    }

    /// The renderer's event order, approximately, through a fresh composer.
    private func compose(_ blocks: [MarkdownBlock], _ stream: inout PreviewCompositionStream) throws {
        for b in blocks {
            stream.beginBlock()
            switch b {
            case .paragraph(let e), .heading(_, let e): for x in e { _ = try stream.consume(x) }
            case .codeBlock(let i, let l):
                for p in i.objectIdentities.map(HTMLPart.object) + l {
                    switch p {
                    case .text(let t): _ = try stream.consume(.text(t))
                    case .object(let o): _ = try stream.consume(.object(o))
                    }
                }
            case .html(let p): _ = try stream.consume(.rawHTML(p))
            case .thematicBreak: break
            case .quote(let c): try compose(c, &stream)
            case .list(_, _, _, let items): for item in items { try compose(item.blocks, &stream) }
            case .table(_, let h, let body):
                for row in [h] + body { for cell in row { stream.beginBlock(); for x in cell { _ = try stream.consume(x) } } }
            case .objects(let o): for x in o { stream.beginBlock(); _ = try stream.consume(.object(x)) }
            }
        }
    }

    func testP14RandomPages() {
        let tokens = ["[", "]", "(", ")", "<", ">", "!", "*", "_", "~", "`", "|", "\\", "&#x10000;", "&amp;", "\n",
                      "\n\n", "> ", "- ", "1. ", "- [ ] ", "```\n", "    ", "[a]: ", "[b]: ", "/u", " \"t\"", " 't'",
                      "http://e.example/", "www.e.example", "a@b.co", "<a href=\"", "\">", "</a>", "<div>", "</div>",
                      "<!--", "-->", "---", "===", "| a |", "|---|", "| b | c |", "x", " ", "#", "[a]", "[x][b]",
                      "<img src=\"", "<b>", "</b>", "<script>", "\t", "\r\n", "\r", ":", "\"", "'", "**", "~~"]
        var rng = SplitMix(state: 0x5EED)
        var failures: [String: Int] = [:]
        var samples: [String: [String]] = [:]
        for _ in 0..<15_000 {
            var parts: [String?] = []
            let n = 3 + rng.below(30)
            for _ in 0..<n {
                if rng.below(5) == 0 { parts.append(nil) } else { parts.append(tokens[rng.below(tokens.count)]) }
            }
            let (text, offsets) = page(parts)
            for dialect in PreviewDialect.allCases {
                var key = ""
                do {
                    let doc = try MarkdownParser.parse(text, objects: offsets, dialect: dialect)
                    let ids = identitiesOf(doc.blocks)
                    if ids.sorted() != (0..<offsets.count).map(String.init).sorted() {
                        key = "IDS-MISMATCH"
                    } else {
                        var stream = PreviewComposer(dialect: dialect).start()
                        do { try compose(doc.blocks, &stream); try stream.finish() } catch { key = "COMPOSE \(error)" }
                    }
                } catch {
                    key = "PARSE \(error)"
                }
                guard !key.isEmpty else { continue }
                let k = "\(dialect) \(key)"
                failures[k, default: 0] += 1
                if samples[k, default: []].count < 4 {
                    samples[k, default: []].append(parts.map { $0.map { esc($0) } ?? "<OBJ>" }.joined())
                }
            }
        }
        for (k, v) in failures.sorted(by: { $0.key < $1.key }) {
            print("FUZZ|\(k)|count=\(v)|samples=\(samples[k] ?? [])")
        }
        print("FUZZ|done")
    }

    func testP15RandomOrder() {
        let tokens = ["*", "_", "~", "`", "|", "\\", "\n", "\n\n", "> ", "- ", "1. ", "- [ ] ", "```\n", "    ",
                      "[a]: /u \"", "[b]: /v '", "\"", "'", "---", "===", "| a |", "|---|", "| b |", "x", " ", "#",
                      "<div>", "</div>", "\t", "**", "~~", "B\n| h |\n|---|\n"]
        var rng = SplitMix(state: 0xC0FFEE)
        var counts: [String: Int] = [:]
        var samples: [String: [String]] = [:]
        for _ in 0..<20_000 {
            var parts: [String?] = []
            let n = 3 + rng.below(25)
            for _ in 0..<n {
                if rng.below(4) == 0 { parts.append(nil) } else { parts.append(tokens[rng.below(tokens.count)]) }
            }
            let (text, offsets) = page(parts)
            for dialect in PreviewDialect.allCases {
                guard let doc = try? MarkdownParser.parse(text, objects: offsets, dialect: dialect) else { continue }
                let ids = identitiesOf(doc.blocks)
                guard ids != (0..<offsets.count).map(String.init) else { continue }
                let joined = parts.map { $0.map { esc($0) } ?? "<OBJ>" }.joined()
                let k = "\(dialect) \(joined.contains("| h |") ? "with-header-para" : joined.contains("|") ? "pipes" : "other")"
                counts[k, default: 0] += 1
                if samples[k, default: []].count < 6 { samples[k, default: []].append(joined + "  => " + ids.joined(separator: ",")) }
            }
        }
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) {
            print("ORDER|\(k)|count=\(v)")
            for s in samples[k] ?? [] { print("ORDER|  \(s)") }
        }
        print("ORDER|done")
    }

    func testP16LastLinks() {
        probeRender("autolink-in-refused-md", ["[http://e.example/](<http://x/", nil, ">)"], dialects: [.gfm])
        probe("autolink-in-refused-md", ["[http://e.example/](<http://x/", nil, ">)"], dialects: [.gfm])
        probeRender("www-in-refused-html", ["<a href=\"", nil, "\">www.e.example</a>"], dialects: [.gfm])
        probeRender("www-in-image-alt", ["![www.e.example ", nil, "](https://e.example/i)"], dialects: [.gfm])
        probe("www-in-image-alt", ["![www.e.example ", nil, "](https://e.example/i)"], dialects: [.gfm])
        probeRender("setext-eq-def-table", ["[a]: /u \"", nil, "\"\n===\n| h |\n|---|\n"], dialects: [.gfm])
        probe("setext-eq-def-table", ["[a]: /u \"", nil, "\"\n===\n| h |\n|---|\n"], dialects: [.gfm])
    }

    func testP17Scaling() {
        for n in [50_000, 100_000, 200_000] { timed("headings-\(n)", rep("# h\n", n), dialects: [.gfm]) }
        for n in [100_000, 200_000, 400_000] { timed("softbreaks-\(n)", rep("a\n", n), dialects: [.gfm]) }
        for n in [10_000, 20_000, 40_000] { timed("www-obj-\(n)", rep("www.a\u{FFFC} ", n),
                                                 objects: (0..<n).map { $0 * 7 + 5 }, dialects: [.gfm]) }
        for c in [50, 100, 200] {
            timed("table-\(c)x\(c)", "|" + rep("a|", c) + "\n|" + rep("-|", c) + "\n" + rep("x\n", c),
                  layout: true, dialects: [.gfm])
        }
    }

    func testP13TableLayout() {
        timed("table-400x250", "|" + rep("a|", 400) + "\n|" + rep("-|", 400) + "\n" + rep("x\n", 250),
              layout: true, dialects: [.gfm])
    }
}

/// Concurrency probe helpers, outside the main actor.
enum ZZProbeConcurrency {
    static func run(_ samples: [String], dialect: PreviewDialect) -> (Int, Int) {
        let serial = samples.map { sample -> String in
            (try? MarkdownParser.parse(sample, dialect: dialect)).map { String(describing: $0.blocks) } ?? "THROW"
        }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var mismatches = 0
            var runs = 0
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let k = i % samples.count
            let result = (try? MarkdownParser.parse(samples[k], dialect: dialect)).map { String(describing: $0.blocks) } ?? "THROW"
            box.lock.lock()
            box.runs += 1
            if result != serial[k] { box.mismatches += 1 }
            box.lock.unlock()
        }
        return (box.runs, box.mismatches)
    }
}

extension ZZAdversarialProbeTests {
    func testP11Concurrency() {
        let samples = [
            "| a | b |\n|---|---|\n| c | d |\n\n~~x~~ www.e.example *y*",
            "[r]: /u \"t\"\n\n[x][r] `c` <b>h</b> **s** _e_",
            "- [ ] task\n- [x] done\n\n> quote www.a.com/x",
            "plain *text* with ~strike~ and http://e.example/z and a@b.com",
        ]
        for dialect in PreviewDialect.allCases {
            let (runs, mismatches) = ZZProbeConcurrency.run(samples, dialect: dialect)
            print("CONC|\(dialect)|runs=\(runs) mismatches=\(mismatches)")
        }
    }
}
