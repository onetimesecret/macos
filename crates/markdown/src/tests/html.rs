//! The shell's `MarkdownHTMLSerializer`: a page written as cmark 0.31.2 writes the spec examples
//! (unsafe mode), with cmark-gfm's table, strikethrough and tagfilter output under GFM.

use crate::{Alignment, Block, Dialect, Document, Event, HtmlPart, Trait};

/// `document` as the HTML its dialect's spec examples show.
pub(super) fn html(document: &Document, dialect: Dialect) -> String {
    let mut writer = Writer {
        dialect,
        html: String::new(),
    };
    writer.blocks(&document.blocks, false);
    writer.html
}

struct Writer {
    dialect: Dialect,
    html: String,
}

impl Writer {
    /// cmark's `cr()`: a newline unless the output is empty or already ends in one.
    fn cr(&mut self) {
        if !self.html.is_empty() && !self.html.ends_with('\n') {
            self.html.push('\n');
        }
    }

    /// `tight` is the enclosing list's, for blocks that are an item's own children.
    fn blocks(&mut self, blocks: &[Block], tight: bool) {
        for block in blocks {
            self.block(block, tight);
        }
    }

    fn block(&mut self, block: &Block, tight: bool) {
        match block {
            Block::Paragraph(events) => {
                if tight {
                    self.inlines(events);
                } else {
                    self.cr();
                    self.html.push_str("<p>");
                    self.inlines(events);
                    self.html.push_str("</p>\n");
                }
            }
            Block::Heading { level, events } => {
                self.cr();
                self.html.push_str(&format!("<h{level}>"));
                self.inlines(events);
                self.html.push_str(&format!("</h{level}>\n"));
            }
            Block::CodeBlock { info, literal } => {
                self.cr();
                let info = joined(info);
                if info.is_empty() {
                    self.html.push_str("<pre><code>");
                } else {
                    self.html.push_str("<pre><code class=\"");
                    // cmark 0.31.2 keeps an info string that already starts `language-`; cmark-gfm always prefixes.
                    if self.dialect == Dialect::Gfm || !info.starts_with("language-") {
                        self.html.push_str("language-");
                    }
                    let word = info.bytes().position(is_space).unwrap_or(info.len());
                    self.html.push_str(&escape_html(&info[..word]));
                    self.html.push_str("\">");
                }
                self.html.push_str(&escape_html(&joined(literal)));
                self.html.push_str("</code></pre>\n");
            }
            Block::Html(parts) => {
                self.cr();
                let literal = joined(parts);
                if self.dialect == Dialect::Gfm {
                    self.html.push_str(&filter_block(&literal));
                } else {
                    self.html.push_str(&literal);
                }
                self.cr();
            }
            Block::ThematicBreak => {
                self.cr();
                self.html.push_str("<hr />\n");
            }
            Block::Quote(children) => {
                self.cr();
                self.html.push_str("<blockquote>\n");
                self.blocks(children, false);
                self.cr();
                self.html.push_str("</blockquote>\n");
            }
            Block::List {
                ordered,
                start,
                tight,
                items,
            } => {
                self.cr();
                if !ordered {
                    self.html.push_str("<ul>\n");
                } else if *start == 1 {
                    self.html.push_str("<ol>\n");
                } else {
                    self.html.push_str(&format!("<ol start=\"{start}\">\n"));
                }
                for item in items {
                    self.cr();
                    self.html.push_str("<li>");
                    // The GFM spec's form of the box, not cmark-gfm's (examples 279 and 280).
                    match item.task {
                        Some(true) => self
                            .html
                            .push_str("<input checked=\"\" disabled=\"\" type=\"checkbox\"> "),
                        Some(false) => self
                            .html
                            .push_str("<input disabled=\"\" type=\"checkbox\"> "),
                        None => {}
                    }
                    self.blocks(&item.blocks, *tight);
                    self.html.push_str("</li>\n");
                }
                self.html
                    .push_str(if *ordered { "</ol>\n" } else { "</ul>\n" });
            }
            Block::Table {
                alignments,
                header,
                body,
            } => {
                self.cr();
                self.html.push_str("<table>");
                self.row(header, alignments, true, false);
                for (index, cells) in body.iter().enumerate() {
                    self.row(cells, alignments, false, index == 0);
                }
                if !body.is_empty() {
                    self.cr();
                    self.html.push_str("</tbody>");
                    self.cr();
                }
                self.cr();
                self.html.push_str("</table>");
                self.cr();
            }
            Block::Objects(identities) => {
                self.html.push_str(&"\u{FFFC}".repeat(identities.len()));
            }
        }
    }

    fn row(
        &mut self,
        cells: &[Vec<Event>],
        alignments: &[Option<Alignment>],
        is_header: bool,
        opens_body: bool,
    ) {
        self.cr();
        if is_header {
            self.html.push_str("<thead>");
            self.cr();
        } else if opens_body {
            self.html.push_str("<tbody>");
            self.cr();
        }
        self.html.push_str("<tr>");
        for (column, events) in cells.iter().enumerate() {
            self.cr();
            self.html.push_str(if is_header { "<th" } else { "<td" });
            match alignments.get(column).copied().flatten() {
                Some(Alignment::Left) => self.html.push_str(" align=\"left\""),
                Some(Alignment::Center) => self.html.push_str(" align=\"center\""),
                Some(Alignment::Right) => self.html.push_str(" align=\"right\""),
                None => {}
            }
            self.html.push('>');
            self.inlines(events);
            self.html
                .push_str(if is_header { "</th>" } else { "</td>" });
        }
        self.cr();
        self.html.push_str("</tr>");
        if is_header {
            self.cr();
            self.html.push_str("</thead>");
        }
    }

    fn inlines(&mut self, events: &[Event]) {
        for event in events {
            match event {
                Event::Text(text) => self.html.push_str(&escape_html(text)),
                Event::Object(_) => self.html.push('\u{FFFC}'),
                Event::EnterMarkdown(style) => self.html.push_str(&format!("<{}>", tag(*style))),
                Event::LeaveMarkdown(style) => self.html.push_str(&format!("</{}>", tag(*style))),
                Event::SoftBreak => self.html.push('\n'),
                Event::HardBreak => self.html.push_str("<br />\n"),
                Event::RawHtml(parts) => {
                    let literal = joined(parts);
                    if self.dialect == Dialect::Gfm && is_disallowed_tag(literal.as_bytes(), 0) {
                        self.html.push_str("&lt;");
                        self.html.push_str(&literal[1..]);
                    } else {
                        self.html.push_str(&literal);
                    }
                }
                Event::MarkdownImage {
                    alt,
                    destination,
                    title,
                } => {
                    self.html.push_str("<img src=\"");
                    self.html.push_str(&escape_href(destination));
                    self.html.push_str("\" alt=\"");
                    self.html.push_str(&escape_html(&joined(alt)));
                    let title = joined(title);
                    if !title.is_empty() {
                        self.html.push_str("\" title=\"");
                        self.html.push_str(&escape_html(&title));
                    }
                    self.html.push_str("\" />");
                }
                Event::EnterLink { destination, title } => {
                    self.html.push_str("<a href=\"");
                    self.html.push_str(&escape_href(destination));
                    let title = joined(title);
                    if !title.is_empty() {
                        self.html.push_str("\" title=\"");
                        self.html.push_str(&escape_html(&title));
                    }
                    self.html.push_str("\">");
                }
                Event::LeaveLink => self.html.push_str("</a>"),
            }
        }
    }
}

fn tag(style: Trait) -> &'static str {
    match style {
        Trait::Emphasis => "em",
        Trait::Strong => "strong",
        Trait::Deletion => "del",
        Trait::Code => "code",
    }
}

fn joined(parts: &[HtmlPart]) -> String {
    let mut text = String::new();
    for part in parts {
        match part {
            HtmlPart::Text(piece) => text.push_str(piece),
            HtmlPart::Object(_) => text.push('\u{FFFC}'),
        }
    }
    text
}

/// cmark's `cmark_isspace`: tab, line feed, carriage return and space.
fn is_space(byte: u8) -> bool {
    matches!(byte, 0x09 | 0x0A | 0x0D | 0x20)
}

/// `houdini_escape_html` without its secure mode: `'` and `/` pass.
fn escape_html(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for scalar in text.chars() {
        match scalar {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            _ => escaped.push(scalar),
        }
    }
    escaped
}

/// houdini's `HREF_SAFE` table, byte for byte (`src/houdini_href_e.c`).
#[rustfmt::skip]
const HREF_SAFE: [u8; 256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// `houdini_escape_href` over each text part's UTF-8; an object part is written as U+FFFC.
fn escape_href(parts: &[HtmlPart]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut escaped: Vec<u8> = Vec::new();
    for part in parts {
        let HtmlPart::Text(text) = part else {
            escaped.extend_from_slice("\u{FFFC}".as_bytes());
            continue;
        };
        for byte in text.bytes() {
            if HREF_SAFE[usize::from(byte)] != 0 {
                escaped.push(byte);
            } else if byte == b'&' {
                escaped.extend_from_slice(b"&amp;");
            } else if byte == b'\'' {
                escaped.extend_from_slice(b"&#x27;");
            } else {
                escaped.extend_from_slice(&[
                    b'%',
                    HEX[usize::from(byte >> 4)],
                    HEX[usize::from(byte & 0xF)],
                ]);
            }
        }
    }
    String::from_utf8_lossy(&escaped).into_owned()
}

const DISALLOWED: [&[u8]; 9] = [
    b"title",
    b"textarea",
    b"style",
    b"xmp",
    b"iframe",
    b"noembed",
    b"noframes",
    b"script",
    b"plaintext",
];

/// cmark-gfm's `filter_html_block`: every `<` that opens a disallowed tag becomes `&lt;`.
fn filter_block(literal: &str) -> String {
    let bytes = literal.as_bytes();
    let mut filtered: Vec<u8> = Vec::with_capacity(bytes.len());
    for (index, &byte) in bytes.iter().enumerate() {
        if byte == b'<' && is_disallowed_tag(bytes, index) {
            filtered.extend_from_slice(b"&lt;");
        } else {
            filtered.push(byte);
        }
    }
    String::from_utf8_lossy(&filtered).into_owned()
}

fn is_disallowed_tag(bytes: &[u8], start: usize) -> bool {
    DISALLOWED.iter().any(|name| is_tag(bytes, start, name))
}

/// cmark-gfm tagfilter's `is_tag`, reading `bytes` from `start` to the end.
fn is_tag(bytes: &[u8], start: usize, name: &[u8]) -> bool {
    let size = bytes.len() - start;
    if size < 3 || bytes[start] != b'<' {
        return false;
    }
    let mut index = 1;
    if bytes[start + index] == b'/' {
        index += 1;
    }
    let mut matched = 0;
    while index < size && matched < name.len() {
        if bytes[start + index].to_ascii_lowercase() != name[matched] {
            return false;
        }
        index += 1;
        matched += 1;
    }
    if index == size {
        return false;
    }
    let next = bytes[start + index];
    if is_space(next) || next == b'>' {
        return true;
    }
    next == b'/' && size >= index + 2 && bytes[start + index + 1] == b'>'
}
