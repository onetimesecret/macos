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
        var line: NSRect
        if layoutManager.numberOfGlyphs > 0 {
            // Use the leading margin to identify the line, independently of horizontal scroll.
            let glyph = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: max(top, 0)), in: container
            )
            var glyphs = NSRange(location: 0, length: 0)
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            characterIndex = layoutManager.characterIndexForGlyph(at: glyphs.location)
        } else {
            // Empty text may need a geometry refresh after zero-length invalidation.
            if layoutManager.extraLineFragmentRect.height == 0 {
                layoutManager.textContainerChangedGeometry(container)
                layoutManager.ensureLayout(for: container)
            }
            line = layoutManager.extraLineFragmentRect
            characterIndex = 0
        }
        // Glyph lookup can refresh an extra line invalidated by an edit.
        let extraLine = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer === container,
           extraLine.height > 0, top >= extraLine.minY {
            line = extraLine
            characterIndex = textView.textStorage?.length ?? 0
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
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let length = textView.textStorage?.length ?? 0
        let character = min(max(characterIndex, 0), length)
        var line: NSRect
        if layoutManager.numberOfGlyphs > 0 {
            let character = min(character, max(length - 1, 0))
            let glyph = min(
                layoutManager.glyphIndexForCharacter(at: character),
                layoutManager.numberOfGlyphs - 1
            )
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            if layoutManager.extraLineFragmentRect.height == 0 {
                layoutManager.textContainerChangedGeometry(container)
                layoutManager.ensureLayout(for: container)
            }
            line = layoutManager.extraLineFragmentRect
        }
        let extraLine = layoutManager.extraLineFragmentRect
        if character == length, layoutManager.extraLineFragmentTextContainer === container,
           extraLine.height > 0 {
            line = extraLine
        }
        return NSPoint(x: x, y: origin.y + line.minY + lineFraction * line.height)
    }
}

/// Where the days roll stood when the page content changed hands: the
/// page at the top of the clip, and the line of it that was there.
///
/// The roll has one clip over every day in it, so its offset belongs to
/// no single page and is kept apart from the per page scrolls. It is
/// said in the document's terms for `ScrollAnchor`'s reason and one
/// more: the two windows wrap every page above the reader differently,
/// so a distance down the roll is a different day in the other window,
/// not merely a different sentence. A top edge resting in the header
/// above a page's ink is a negative fraction of that page's first line,
/// the same way the top inset is.
///
/// The document origin needs no saved place. A horizontal offset at
/// vertical offset zero is still represented by the first page's anchor.
struct RollPlace: Equatable {
    /// The text of the page the anchor counts characters in.
    enum Reading: Equatable { case source, preview }

    var page: UInt64
    var anchor: ScrollAnchor
    var reading: Reading = .source
    /// The length of the text the anchor was read from.
    var length: Int = 0

    /// The anchor for `reading`'s text of `length` characters. No position map joins
    /// the source to its preview, so the other reading is mapped by proportion.
    func mappedAnchor(into reading: Reading, length: Int) -> ScrollAnchor {
        guard reading != self.reading else { return anchor }
        var mapped = anchor
        let scaled = self.length > 0
            ? (Double(anchor.characterIndex) * Double(length) / Double(self.length)).rounded() : 0
        mapped.characterIndex = min(max(Int(scaled), 0), length)
        return mapped
    }

    /// The same place after the text it was read from changed from `old` to `new`.
    func rebased(from old: String, to new: String) -> RollPlace {
        var place = self
        place.anchor.characterIndex = Self.rebased(anchor.characterIndex, from: old, to: new)
        place.length = new.utf16.count
        return place
    }

    /// The same place after one storage edit, said as the storage says it: the edited
    /// range and the length of the new text, and the change in length.
    func rebased(throughEdit edited: NSRange, changeInLength delta: Int, length: Int) -> RollPlace {
        var place = self
        place.anchor.characterIndex = Self.rebased(
            anchor.characterIndex, throughEdit: edited, changeInLength: delta, length: length)
        place.length = length
        return place
    }

    /// Before the edit an index stays, and past it the index moves by `delta`. Inside it an
    /// index moves by `delta` too, unless the edit restated the whole text of `length`.
    static func rebased(_ index: Int, throughEdit edited: NSRange, changeInLength delta: Int, length: Int) -> Int {
        // Text typed or pasted at the anchor stays at the top, where the reader put it.
        if index <= edited.location { return max(index, 0) }
        if index >= NSMaxRange(edited) - delta { return index + delta }
        if edited.location == 0, edited.length == length { return min(index, length) }
        // AppKit reports an insertion through to its paragraph's end, so the text after it moved.
        return max(index + delta, edited.location)
    }

    /// Rebase a UTF-16 index through unchanged text, or to its replacement's start.
    static func rebased(_ index: Int, from old: String, to new: String) -> Int {
        let oldCount = old.utf16.count
        let newCount = new.utf16.count
        guard oldCount > 0 else { return 0 }
        let index = min(max(index, 0), oldCount)
        let a = Array(old.unicodeScalars)
        let b = Array(new.unicodeScalars)
        // The suffix is matched first, so text arriving at the anchor goes above it.
        let suffix = matched(a.reversed(), b.reversed())
        let prefix = min(matched(a, b), min(a.count, b.count) - suffix)
        let prefixLength = utf16Length(a.prefix(prefix))
        let suffixLength = utf16Length(a.suffix(suffix))
        if index >= oldCount - suffixLength { return index - oldCount + newCount }
        // A shared prefix can also be an insertion into repeated text; use it only on fallback.
        return rebasedInterior(
            index, from: a[..<(a.count - suffix)], to: b[..<(b.count - suffix)])
            ?? min(index, prefixLength)
    }

    private static func utf16Length(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + $1.utf16.count }
    }

    private static func rebasedInterior(
        _ index: Int, from old: ArraySlice<Unicode.Scalar>, to new: ArraySlice<Unicode.Scalar>
    ) -> Int? {
        guard !old.isEmpty, !new.isEmpty else { return nil }
        var target = 0
        var offset = 0
        while target < old.count {
            let width = old[old.startIndex + target].utf16.count
            if offset + width > index { break }
            offset += width
            target += 1
        }
        let withinScalar = index - offset
        func position(_ scalar: Int, surviving: Bool) -> Int {
            utf16Length(new.prefix(scalar)) + (surviving ? withinScalar : 0)
        }

        // Reverse matching gives insertions at a surviving anchor the same affinity as the suffix.
        var x = old.count
        var y = new.count
        var insertionMatch: Int?
        while x > 0, y > 0 {
            y -= 1
            if old[old.startIndex + x - 1] == new[new.startIndex + y] {
                x -= 1
                if x == target { insertionMatch = y }
            }
        }
        if x == 0, let insertionMatch { return position(insertionMatch, surviving: true) }

        // For deletions only, unmatched old scalars map to the boundary before the matched right side.
        x = old.count
        y = new.count
        var deletionMatch: Int?
        var targetSurvives = false
        while x > 0, y > 0 {
            x -= 1
            if old[old.startIndex + x] == new[new.startIndex + y - 1] {
                y -= 1
                if x == target {
                    deletionMatch = y
                    targetSurvives = true
                }
            } else if x == target {
                deletionMatch = y
            }
        }
        if y == 0 { return position(deletionMatch ?? 0, surviving: targetSurvives) }

        // Reverse Myers uses the same matching direction as the insertion-only path.
        struct Step {
            var x = -1
            var mapped = 0
            var surviving = false
            var pendingDeletion = false
        }
        let reverseTarget = old.count - target - 1
        // Bound mixed-edit work even for a single long line; exhaustion uses the outer replacement.
        var budget = max(65_536, 8 * (old.count + new.count))
        let limit = min(1_024, old.count + new.count)
        let origin = limit + 1
        var frontier = Array(repeating: Step(), count: 2 * limit + 3)
        frontier[origin + 1] = Step(x: 0)
        var previousLower = 1
        var previousUpper = 1
        for edits in 0...limit {
            // Exclude paths requiring more insertions or deletions than either text permits.
            let lower = max(-edits, edits - 2 * new.count)
            let upper = min(edits, 2 * old.count - edits)
            for diagonal in stride(from: lower, through: upper, by: 2) {
                budget -= 1
                guard budget >= 0 else { return nil }
                let slot = origin + diagonal
                let left = (previousLower...previousUpper).contains(diagonal - 1)
                    ? frontier[slot - 1] : Step()
                let right = (previousLower...previousUpper).contains(diagonal + 1)
                    ? frontier[slot + 1] : Step()
                let canInsert = right.x >= 0
                    && (edits == 0 || right.x - diagonal - 1 < new.count)
                let canDelete = left.x >= 0 && left.x < old.count
                guard canInsert || canDelete else {
                    frontier[slot] = Step()
                    continue
                }
                let inserting = canInsert && (!canDelete || left.x < right.x)
                var step = inserting ? right : left
                if !inserting {
                    if step.x == reverseTarget {
                        step.pendingDeletion = true
                        step.surviving = false
                    }
                    step.x += 1
                }
                var y = step.x - diagonal
                // A deleted anchor's replacement start is known at the next match to its left.
                if step.pendingDeletion { step.mapped = new.count - y }
                while step.x < old.count, y < new.count {
                    budget -= 1
                    guard budget >= 0 else { return nil }
                    guard old[old.endIndex - step.x - 1] == new[new.endIndex - y - 1] else { break }
                    step.pendingDeletion = false
                    if step.x == reverseTarget {
                        step.mapped = new.count - y - 1
                        step.surviving = true
                    }
                    step.x += 1
                    y += 1
                }
                if step.x == old.count, y == new.count {
                    return position(step.mapped, surviving: step.surviving)
                }
                frontier[slot] = step
            }
            previousLower = lower
            previousUpper = upper
        }
        return nil
    }

    private static func matched<Units: Sequence>(_ a: Units, _ b: Units) -> Int
    where Units.Element: Equatable {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
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

    /// Where the roll stood at the last hand off, waiting for the roll
    /// that mounts in the window that owns now (ADR-0033). One, because
    /// there is one roll. Written only by a transfer of ownership: a
    /// roll rebuilt within one window (a ledger round trip, the mode
    /// toggled) opens at Day 0 as it always has.
    private(set) var rollPlace: RollPlace?

    /// The outgoing roll's answer at a hand off. Nil is a roll standing
    /// at Day 0, and it replaces whatever was waiting: the place is
    /// where the person is now.
    mutating func leaveRollPlace(_ place: RollPlace?) {
        rollPlace = place
    }

    /// The incoming roll collecting the place. Once: the roll built
    /// after it, in the same window, opens at Day 0 like any other.
    mutating func takeRollPlace() -> RollPlace? {
        defer { rollPlace = nil }
        return rollPlace
    }

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
        if let place = rollPlace, !live.contains(place.page) { rollPlace = nil }
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
