/// A page's Markdown as its dialect's pinned parser reads it, each sealed object an atom
/// (plan R1). Inline content is already the composer's events.
struct MarkdownDocument: Equatable, Codable, Sendable {
    var blocks: [MarkdownBlock]
    /// Every object of the page in source order.
    var atoms: [MarkdownAtom]
}

/// An object's identity in composer events and its UTF-16 offset in the page.
struct MarkdownAtom: Equatable, Codable, Sendable {
    let identity: String
    let offset: Int
}

enum MarkdownAlignment: Equatable, Codable, Sendable {
    case left, center, right
}

struct MarkdownListItem: Equatable, Codable, Sendable {
    /// Whether a task item's box is checked; nil for an ordinary item.
    var task: Bool?
    var blocks: [MarkdownBlock]
}

indirect enum MarkdownBlock: Equatable, Codable, Sendable {
    case paragraph([PreviewEvent])
    case heading(level: Int, [PreviewEvent])
    /// `info` is a fenced block's info string, empty for an indented block.
    case codeBlock(info: [HTMLPart], literal: [HTMLPart])
    case html([HTMLPart])
    case thematicBreak
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MarkdownListItem])
    /// One alignment per column; each row contains cells and each cell contains events.
    case table(alignments: [MarkdownAlignment?], header: [[PreviewEvent]], body: [[[PreviewEvent]]])
    /// Objects with no element of their own, placed by source position.
    case objects([String])
}
