import Foundation

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
    private(set) var scrolls: [UInt64: NSPoint] = [:]

    mutating func saveCaret(_ caret: NSRange, for id: UInt64) {
        carets[id] = caret
    }

    mutating func saveScroll(_ offset: NSPoint, for id: UInt64) {
        scrolls[id] = offset
    }

    /// Put back a scroll position that a save made too early wrote
    /// over, and only that. An id with no entry stays without one: a
    /// page pruned in the interim stays gone, because the repair mends
    /// entries and never resurrects them.
    mutating func repairScroll(_ offset: NSPoint, for id: UInt64) {
        guard scrolls[id] != nil else { return }
        scrolls[id] = offset
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
