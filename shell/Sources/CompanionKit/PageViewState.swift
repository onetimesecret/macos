import AppKit

/// How far a page was read to, said in a way that means the same thing
/// in a view of any width: the line at the top of the visible rect,
/// named by its first character, and how far into that line the top
/// edge sat.
///
/// A pixel offset is only a place on the page for the measure it was
/// read from. The panel and the editor window wrap the same paragraph
/// into different numbers of lines (ADR-0033), so 400 points down one
/// of them is some other sentence in the other, and a place handed
/// across as pixels would open the page where nobody had been. A
/// character is the same character in both, so the anchor is kept in
/// the document's terms and turned back into pixels by whichever view
/// restores it, against its own layout.
///
/// The fraction keeps the restore exact where exactness is possible.
/// Through one view at one width the round trip returns the offset it
/// started from and not merely the top of the right line, and the few
/// points of the top inset above the first line are a negative
/// fraction of that line, so a page left at the very top comes back at
/// the very top. `x` stays in points: a wrapped page never scrolls
/// sideways, and an unwrapped one is laid out alike at every width.
struct ScrollAnchor: Equatable {
    var characterIndex: Int
    var lineFraction: CGFloat
    var x: CGFloat

    init(characterIndex: Int, lineFraction: CGFloat = 0, x: CGFloat = 0) {
        self.characterIndex = characterIndex
        self.lineFraction = lineFraction
        self.x = x
    }

    /// Read the anchor off a view whose clip stands at `clipOrigin`, in
    /// the view's own coordinates. Nil only when the TextKit stack is
    /// missing, in which case there is no place to speak of.
    @MainActor
    init?(topOf textView: NSTextView, clipOrigin: NSPoint) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let top = clipOrigin.y - textView.textContainerOrigin.y
        let line: NSRect
        if layoutManager.numberOfGlyphs > 0 {
            // The nearest glyph to a point is always on the line the
            // point's height falls in, so x is left at the margin. A
            // top edge inside the inset is asked about as the first
            // line and told apart from it by the fraction below.
            let glyph = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: max(top, 0)), in: container
            )
            var glyphs = NSRange(location: 0, length: 0)
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            characterIndex = layoutManager.characterIndexForGlyph(at: glyphs.location)
        } else {
            // An empty page has one line all the same, the one the
            // caret waits on.
            line = layoutManager.extraLineFragmentRect
            characterIndex = 0
        }
        lineFraction = line.height > 0 ? (top - line.minY) / line.height : 0
        x = clipOrigin.x
    }

    /// The clip origin that puts this anchor's line back at the top of
    /// `textView`, measured against the layout the view has now. Not
    /// clamped: content can shrink while a page is in the background,
    /// and what the document can actually scroll to is the caller's
    /// question. The character is clamped, since it is asked of a
    /// layout manager that raises on an index it does not have.
    @MainActor
    func offset(in textView: NSTextView) -> NSPoint? {
        guard let layoutManager = textView.layoutManager else { return nil }
        let origin = textView.textContainerOrigin
        let line: NSRect
        if layoutManager.numberOfGlyphs > 0 {
            let length = textView.textStorage?.length ?? 0
            let character = min(max(characterIndex, 0), max(length - 1, 0))
            let glyph = min(
                layoutManager.glyphIndexForCharacter(at: character),
                layoutManager.numberOfGlyphs - 1
            )
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            line = layoutManager.extraLineFragmentRect
        }
        return NSPoint(x: x, y: origin.y + line.minY + lineFraction * line.height)
    }
}

/// Where the person was on each page: the caret, and how far the page
/// was read to.
///
/// Both are view state, and with one editor serving every page
/// (ADR-0006) they no longer die with a torn down view, so they are
/// carried per page by hand: saved before the storage swap takes the
/// page away, restored after its return. They used to be carried by the
/// editor's own coordinator, which was enough while one editor was the
/// only thing that ever stood over a page. Two windows can show the
/// same page now (ADR-0033), each with a coordinator of its own, and a
/// place kept by one of them is a place the other cannot find. So the
/// table is the model's, and whichever editor mounts a page next reads
/// what the last one wrote.
///
/// Keyed by page identity and never by tab, for the reason the storage
/// map is (ADR-0017): a tab outlives its pages, so a slot's id would
/// keep a dead page's caret and scroll alive for whatever page came
/// next. A file's id is a key here too, under the tag that keeps it
/// apart from every page.
///
/// A value type with no clock and no view in it, so its few laws can be
/// asserted directly.
struct PageViewStates {
    private(set) var carets: [UInt64: NSRange] = [:]
    private(set) var scrolls: [UInt64: ScrollAnchor] = [:]

    mutating func saveCaret(_ caret: NSRange, for id: UInt64) {
        carets[id] = caret
    }

    mutating func saveScroll(_ anchor: ScrollAnchor, for id: UInt64) {
        scrolls[id] = anchor
    }

    /// Put back a scroll position that a save made too early wrote
    /// over, and only that. An id with no entry stays without one: a
    /// page pruned in the interim stays gone, because the repair mends
    /// entries and never resurrects them. A nil anchor is the page that
    /// had no entry before the early save: what is put back is the
    /// absence, which restores as the top of the page.
    mutating func repairScroll(_ anchor: ScrollAnchor?, for id: UInt64) {
        guard scrolls[id] != nil else { return }
        scrolls[id] = anchor
    }

    /// Dead pages take their view state with them, on the same set and
    /// at the same moment `refresh()` prunes the storage cache.
    mutating func prune(keeping live: Set<UInt64>) {
        carets = Self.pruned(carets, keeping: live)
        scrolls = Self.pruned(scrolls, keeping: live)
    }

    /// Forget one id's caret and scroll outright.
    ///
    /// The counterpart to the tag exemption in `pruned`. A file is
    /// exempt from the page prune because it is never in the live page
    /// set, so something has to drop its entries when it actually goes,
    /// and this is that something. Called when a file leaves the
    /// roster, never on a page: a page's entries are the prune's
    /// business.
    mutating func forget(_ id: UInt64) {
        carets[id] = nil
        scrolls[id] = nil
    }

    /// Every id holding a caret, a scroll position, or both.
    var keys: Set<UInt64> {
        Set(carets.keys).union(scrolls.keys)
    }

    /// The pure half of `prune`: keep only the entries whose keys are
    /// still live.
    ///
    /// A file id is always live here. The set is built from page
    /// identities and a file is never among them, so without the
    /// exemption a file's caret and scroll are thrown away on the first
    /// refresh after it opens, and page to file to page returns the
    /// file to the top with the caret at zero. A file's entries go
    /// when the file closes, which drops the whole id.
    static func pruned<Value>(
        _ table: [UInt64: Value], keeping live: Set<UInt64>
    ) -> [UInt64: Value] {
        table.filter { $0.key.isFileID || live.contains($0.key) }
    }
}
