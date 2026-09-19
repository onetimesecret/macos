import SwiftUI

/// Where the pages stand in the roll, how their lines fall, and how much
/// of it the reader can see: the measurement behind the rail's stream
/// navigator (issue #131, and the stream navigator that succeeded its
/// minimap).
///
/// Geometry and nothing else. An extent is a page's top and height in
/// the roll's own document coordinates, which is a fact about how much
/// page stands there, and its lines are the laid-out line fragments as
/// rectangles: where each begins down the roll and how much of the wrap
/// width it used. The viewport is the window the clip has open onto the
/// document. No text, no attributed string, no snapshot of a rendered
/// page crosses this type, and that is the load-bearing decision rather
/// than an economy: a navigator drawn from glyphs would be a second
/// surface rendering page content, it would have to reimplement how a
/// sealed block draws, and it would invite an argument about whether two
/// point text is legible. Rectangles cannot leak a word.
///
/// Measured by the roll (`DayStackView.measuredGeometry`), mapped into
/// the rail by `StreamNavigator.layout`, and carried between them as a
/// value, so the whole path is testable without a window at one end and
/// with one at the other.
public struct RollGeometry: Equatable, Sendable {
    /// One laid-out line of a page, as a rectangle and not as a line.
    public struct LineMark: Equatable, Sendable {
        /// The top of the line fragment, measured down from the top of
        /// the document.
        public let y: CGFloat
        /// How much of the wrap width the fragment used, 0 to 1. A
        /// blank line is zero, and a line that ran to the edge is one.
        public let width: CGFloat

        public init(y: CGFloat, width: CGFloat) {
            self.y = y
            self.width = width
        }
    }

    /// One row's span down the roll: a page under its gutter, or the
    /// empty place today keeps while it holds no page.
    public struct Extent: Equatable, Sendable {
        /// The day this span belongs to, 0 for today, as the projection
        /// counts them.
        public let bucket: Int
        /// The page standing here, or nil for the empty Today place,
        /// which is a place and not a page (ADR-0017).
        public let page: UInt64?
        /// The top of the row's gutter, measured down from the top of
        /// the document.
        public let top: CGFloat
        /// Down to the bottom of the row's body, the gutter included.
        /// Never negative.
        public let height: CGFloat
        /// The page's lines, in document order. Empty for a row with no
        /// text view under it.
        public let lines: [LineMark]

        public init(
            bucket: Int, page: UInt64?, top: CGFloat, height: CGFloat, lines: [LineMark] = []
        ) {
            self.bucket = bucket
            self.page = page
            self.top = top
            self.height = height
            self.lines = lines
        }

        public var bottom: CGFloat { top + height }
    }

    /// The document-proportional half of the measurement. Its revision
    /// changes only when extents, line marks, or document height change;
    /// viewport-only publications retain it so navigator layout caches do
    /// not confuse scrolling with a new document layout.
    public struct Document: Equatable, Sendable {
        public let extents: [Extent]
        public let height: CGFloat
        /// Stable for one mounted stack and distinct across replacements.
        /// Nil for hand-built geometry, which consumers do not cache.
        public let identity: UUID?
        public let revision: UInt64

        public init(
            extents: [Extent], height: CGFloat, identity: UUID? = nil, revision: UInt64 = 0
        ) {
            self.extents = extents
            self.height = height
            self.identity = identity
            self.revision = revision
        }

        public static let unmeasured = Document(extents: [], height: 0)
    }

    public let document: Document

    /// Compatibility accessors for callers interested in the complete
    /// measurement rather than its publication identity.
    public var extents: [Extent] { document.extents }
    public var documentHeight: CGFloat { document.height }

    /// Where the clip is, measured down from the top of the document.
    /// Can be negative for the length of an elastic overscroll, which
    /// the mapping clamps rather than refuses.
    public let viewportTop: CGFloat
    /// How much of the roll the clip has open.
    public let viewportHeight: CGFloat

    public init(
        extents: [Extent], documentHeight: CGFloat, viewportTop: CGFloat, viewportHeight: CGFloat,
        documentRevision: UInt64 = 0
    ) {
        document = Document(
            extents: extents, height: documentHeight, revision: documentRevision)
        self.viewportTop = viewportTop
        self.viewportHeight = viewportHeight
    }

    public init(document: Document, viewportTop: CGFloat, viewportHeight: CGFloat) {
        self.document = document
        self.viewportTop = viewportTop
        self.viewportHeight = viewportHeight
    }

    /// A roll nobody has measured: what the rail draws over before the
    /// first layout pass, and what a roll going away leaves behind. The
    /// navigator over it packs its nodes from the top and draws no band,
    /// which is the only honest reading of a document with no height.
    public static let unmeasured = RollGeometry(
        extents: [], documentHeight: 0, viewportTop: 0, viewportHeight: 0
    )
}

/// The roll's measurement, published for the rail alone, and the rail's
/// two asks of the roll, answered by whichever roll is mounted.
///
/// Its own observable rather than a field on `PageModel` because the
/// viewport moves on every scroll event, and a published change on the
/// model would redraw the header, the status stack and the page along
/// with the navigator. Observed by the navigator and by nothing else, a
/// scroll costs a few rectangles.
///
/// Every publication takes a hop through the main actor's queue, and
/// that is not a throttle for its own sake: `relayout` runs inside
/// `updateNSView`, and observable state written there is state written
/// during a SwiftUI render pass. The hop puts the change after the pass
/// that measured it. It coalesces on the way, so a burst of scroll
/// notifications inside one turn of the loop lands as one redraw.
@MainActor
public final class RollGeometryModel: ObservableObject {
    /// What the roll last measured. `unmeasured` until a roll is
    /// mounted and laid out.
    @Published public private(set) var geometry: RollGeometry = .unmeasured

    /// The measurement waiting for the hop, if one is in flight.
    private var pending: RollGeometry?

    /// The hop itself, while one is booked. Held so a roll that comes
    /// back to where it already was can call it off, rather than leaving
    /// a turn of the loop reserved for a publication that will not
    /// happen and having the next measurement book a second one.
    private var hop: Task<Void, Never>?

    /// The roll the rail is drawing, and the only one this model
    /// listens to.
    ///
    /// Two rolls share this model for as long as one is replacing the
    /// other, because SwiftUI may build a replacement before dismantling
    /// what it replaces, which is the same fact
    /// `DayScrollView.dismantleNSView` states about the editor handle.
    /// Without a name on the publication, the outgoing roll's teardown
    /// would wipe the measurement the incoming one had already taken and
    /// the navigator would draw nothing until something happened to
    /// re-measure. So a mount claims the model, and a roll that no
    /// longer holds the claim is answered with silence rather than with
    /// a redraw.
    private var publisher: ObjectIdentifier?

    /// How the mounted roll moves its clip to a document offset, set
    /// at the claim and dropped with it. The navigator asks through
    /// `scroll(toDocumentOffset:)` and never reaches the roll itself.
    private var scroller: ((CGFloat) -> Void)?

    /// How the mounted roll takes a wheel event that landed on the
    /// rail, on the same terms.
    private var wheelRelay: ((NSEvent) -> Void)?

    /// Where the mounted roll stands, on the same terms. Asked by the
    /// model at a hand off (ADR-0033), since the claim is the one handle
    /// on the roll that does not depend on an editor being mounted in
    /// it: a roll showing an empty Today has a place and no editor.
    private var placeReader: (() -> RollPlace?)?

    /// A roll has been mounted. It speaks for the rail from here on, and
    /// it has nothing laid out yet, so the rail stops drawing the shape
    /// of whatever it is replacing. Through the same hop as any other
    /// publication, for the same reason: a mount happens inside
    /// `makeNSView`.
    ///
    /// The first two closures are the roll's answers to the rail's two
    /// asks, and the third is its answer to the model's one. Nil is a
    /// roll that answers none, which is what a test's stand-in is; the
    /// surface always passes all three.
    func claim(
        by roll: AnyObject,
        scroller: ((CGFloat) -> Void)? = nil,
        wheel: ((NSEvent) -> Void)? = nil,
        place: (() -> RollPlace?)? = nil
    ) {
        publisher = ObjectIdentifier(roll)
        self.scroller = scroller
        wheelRelay = wheel
        placeReader = place
        reset(from: roll)
    }

    /// The roll measured itself. Nothing is published if the answer is
    /// the one already on screen, which is the common case: the roll
    /// re-measures on every cosmetic redraw, and a countdown ticking
    /// moves no frame.
    func publish(_ measured: RollGeometry, from roll: AnyObject) {
        guard publisher == ObjectIdentifier(roll) else { return }
        book(measured)
    }

    /// Whether this roll is the one the rail is listening to.
    func holdsClaim(_ roll: AnyObject) -> Bool {
        publisher == ObjectIdentifier(roll)
    }

    /// Ownership of the page content is moving to the other window
    /// (ADR-0033), so whichever roll holds the claim stops speaking for
    /// the rail: its measurement is withdrawn and its two answers are
    /// dropped. The roll itself may stand a moment longer, until
    /// SwiftUI takes it down, and what it says in that moment is
    /// answered with silence, as a replaced roll's is. The window that
    /// owns next claims afresh when its roll mounts.
    ///
    /// The roll's last word is where it stood, which the model keeps
    /// for the roll that mounts next. Nil from a roll at Day 0, and nil
    /// when no roll holds the claim, which is the ledger or a file
    /// showing and nothing to carry.
    @discardableResult
    func relinquish() -> RollPlace? {
        guard publisher != nil else { return nil }
        let place = placeReader?()
        publisher = nil
        scroller = nil
        wheelRelay = nil
        placeReader = nil
        book(.unmeasured)
        return place
    }

    /// A measurement on its way to the rail, through the hop.
    private func book(_ measured: RollGeometry) {
        guard measured != geometry else {
            // The roll came back to where it already was before the hop
            // could run, so there is nothing left to say and the turn of
            // the loop it booked is given back.
            pending = nil
            hop?.cancel()
            hop = nil
            return
        }
        pending = measured
        guard hop == nil else { return }
        hop = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// The roll is going away. Ignored when a replacement has already
    /// claimed the model: the surface being torn down is not the one the
    /// rail is drawing any more, and its parting word would blank a
    /// navigator that has just been measured honestly.
    func reset(from roll: AnyObject) {
        publish(.unmeasured, from: roll)
    }

    /// The rail asked for the clip to move: a node was clicked, or the
    /// track beside one. Silence when no roll is mounted, which is the
    /// ledger or a file showing, where there is no roll to move.
    public func scroll(toDocumentOffset offset: CGFloat) {
        scroller?(offset)
    }

    /// A wheel turned over the rail. The roll takes the event as if it
    /// had landed on the roll itself, momentum and all, so the column
    /// beside the page scrolls the page rather than sitting inert.
    public func relay(wheel event: NSEvent) {
        wheelRelay?(event)
    }

    private func settle() {
        hop = nil
        guard let next = pending else { return }
        pending = nil
        geometry = next
    }
}
