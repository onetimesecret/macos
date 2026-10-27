//! The page as comrak reads it: LF line endings, and object k the plane 16 scalar `base + k`.

use crate::{Atom, Limits, ParseError};
use zeroize::Zeroizing;

const PLANE_16_FIRST: u32 = 0x10_0000;
const PLANE_16_LAST: u32 = 0x10_FFFD;

/// A block source position: a 1 based line and a 1 based UTF-8 byte column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Position {
    pub(crate) line: usize,
    pub(crate) column: usize,
}

/// Literal text split at this page's placeholders.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Piece<'t> {
    Text(&'t str),
    Atom(usize),
}

pub(crate) struct Source {
    base: u32,
    object_count: usize,
    /// Exactly the text handed to comrak.
    pub(crate) text: Zeroizing<String>,
    pub(crate) atoms: Vec<Atom>,
    /// Where each object's placeholder starts in `text`.
    pub(crate) positions: Vec<Position>,
}

impl Source {
    /// `objects` are the UTF-16 offsets in `text` of the U+FFFC characters that are sealed
    /// objects, ascending.
    pub(crate) fn new(text: &str, objects: &[usize], limits: &Limits) -> Result<Self, ParseError> {
        let mut taken = Vec::new();
        let mut nul_count = 0usize;
        for (index, scalar) in text.chars().enumerate() {
            if index >= limits.maximum_input_scalars {
                return Err(ParseError::InputLimit);
            }
            if is_plane_16(u32::from(scalar)) {
                taken.push(u32::from(scalar));
            }
            if scalar == '\0' {
                nul_count += 1;
            }
        }
        if objects.windows(2).any(|pair| pair[0] >= pair[1]) {
            return Err(ParseError::ObjectOffset);
        }
        taken.extend(numeric_reference_values(text).filter(|value| is_plane_16(*value)));
        let base = window(objects.len(), &mut taken)?;
        let capacity = text
            .len()
            .checked_add(nul_count.saturating_mul(2))
            .and_then(|capacity| capacity.checked_add(objects.len()))
            .and_then(|capacity| capacity.checked_add(1))
            .ok_or(ParseError::InputLimit)?;
        let mut source = Self {
            base,
            object_count: objects.len(),
            text: Zeroizing::new(String::with_capacity(capacity)),
            atoms: Vec::with_capacity(objects.len()),
            positions: Vec::with_capacity(objects.len()),
        };
        source.build(text, objects)?;
        Ok(source)
    }

    /// CR and CRLF become LF, NUL becomes U+FFFD and a leading byte order mark is dropped before
    /// any column is counted; the last line gets the LF cmark's line reader gives every line.
    fn build(&mut self, text: &str, objects: &[usize]) -> Result<(), ParseError> {
        let mut line = 1;
        let mut column = 1;
        let mut offset = 0;
        let mut next = 0;
        let mut after_carriage_return = false;
        for scalar in text.chars() {
            let here = offset;
            offset += scalar.len_utf16();
            let newline = after_carriage_return;
            after_carriage_return = false;
            if let Some(&object) = objects.get(next).filter(|&&object| object <= here) {
                if object != here || scalar != '\u{FFFC}' {
                    return Err(ParseError::ObjectOffset);
                }
                self.atoms.push(Atom {
                    identity: next.to_string(),
                    offset: here,
                });
                self.positions.push(Position { line, column });
                let placeholder = self
                    .placeholder(next)
                    .ok_or(ParseError::NoPlaceholderWindow)?;
                self.text.push(placeholder);
                column += placeholder.len_utf8();
                next += 1;
                continue;
            }
            match scalar {
                '\n' if newline => {}
                '\r' | '\n' => {
                    self.text.push('\n');
                    line += 1;
                    column = 1;
                    after_carriage_return = scalar == '\r';
                }
                '\u{0}' => {
                    self.text.push('\u{FFFD}');
                    column += '\u{FFFD}'.len_utf8();
                }
                '\u{FEFF}' if here == 0 => {}
                _ => {
                    self.text.push(scalar);
                    column += scalar.len_utf8();
                }
            }
        }
        if !self.text.is_empty() && !self.text.ends_with('\n') {
            self.text.push('\n');
        }
        if next == objects.len() {
            Ok(())
        } else {
            Err(ParseError::ObjectOffset)
        }
    }

    fn placeholder(&self, object: usize) -> Option<char> {
        let value = self.base.checked_add(u32::try_from(object).ok()?)?;
        char::from_u32(value).filter(|_| is_plane_16(value))
    }

    pub(crate) fn object_count(&self) -> usize {
        self.object_count
    }

    pub(crate) fn atom(&self, scalar: char) -> Option<usize> {
        let index = u32::from(scalar).checked_sub(self.base)?;
        let index = usize::try_from(index).ok()?;
        (index < self.object_count).then_some(index)
    }

    pub(crate) fn pieces<'t>(&self, text: &'t str) -> Vec<Piece<'t>> {
        let mut pieces = Vec::new();
        let mut start = 0;
        for (index, scalar) in text.char_indices() {
            if let Some(atom) = self.atom(scalar) {
                if start < index {
                    pieces.push(Piece::Text(&text[start..index]));
                }
                pieces.push(Piece::Atom(atom));
                start = index + scalar.len_utf8();
            }
        }
        if start < text.len() {
            pieces.push(Piece::Text(&text[start..]));
        }
        pieces
    }
}

fn is_plane_16(value: u32) -> bool {
    (PLANE_16_FIRST..=PLANE_16_LAST).contains(&value)
}

/// The lowest base whose `count` scalars are all plane 16 and none of them `taken`.
fn window(count: usize, taken: &mut [u32]) -> Result<u32, ParseError> {
    taken.sort_unstable();
    let count = u64::try_from(count).map_err(|_| ParseError::NoPlaceholderWindow)?;
    let mut base = u64::from(PLANE_16_FIRST);
    for &value in taken.iter() {
        let value = u64::from(value);
        if value >= base + count {
            break;
        }
        if value >= base {
            base = value + 1;
        }
    }
    if count > 0 && base + count - 1 > u64::from(PLANE_16_LAST) {
        return Err(ParseError::NoPlaceholderWindow);
    }
    u32::try_from(base).map_err(|_| ParseError::NoPlaceholderWindow)
}

/// The value of every terminated `&#digits;` and `&#xhex;` in `text`, any digit count, up to
/// U+10FFFF.
fn numeric_reference_values(text: &str) -> impl Iterator<Item = u32> {
    let bytes = text.as_bytes();
    let mut values = Vec::new();
    let mut index = 0;
    while index + 3 < bytes.len() {
        if bytes[index] != b'&' || bytes[index + 1] != b'#' {
            index += 1;
            continue;
        }
        let mut cursor = index + 2;
        let hex = (bytes[cursor] | 0x20) == b'x';
        if hex {
            cursor += 1;
        }
        let digits = cursor;
        let mut value: u32 = 0;
        let mut in_range = true;
        while let Some(digit) = bytes.get(cursor).and_then(|&byte| digit(byte, hex)) {
            if in_range {
                value = value * if hex { 16 } else { 10 } + digit;
                in_range = value <= 0x10_FFFF;
            }
            cursor += 1;
        }
        if cursor > digits && bytes.get(cursor) == Some(&b';') && in_range {
            values.push(value);
        }
        index = cursor;
    }
    values.into_iter()
}

fn digit(byte: u8, hex: bool) -> Option<u32> {
    match byte {
        b'0'..=b'9' => Some(u32::from(byte - b'0')),
        b'a'..=b'f' if hex => Some(u32::from(byte - b'a') + 10),
        b'A'..=b'F' if hex => Some(u32::from(byte - b'A') + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(text: &str, objects: &[usize]) -> Result<Source, ParseError> {
        Source::new(text, objects, &Limits::default())
    }

    #[test]
    fn numeric_references_of_any_length_and_either_case_are_read() {
        let values: Vec<u32> =
            numeric_reference_values("&#65; &#x41; &#X41; &#0000000065; &#x110000; &#; &#x; &#12")
                .collect();
        assert_eq!(values, [65, 65, 65, 65]);
    }

    #[test]
    fn the_window_skips_each_taken_scalar_below_its_end() {
        assert_eq!(window(2, &mut [0x10_0001]), Ok(0x10_0002));
        assert_eq!(window(1, &mut [0x10_0001]), Ok(0x10_0000));
        assert_eq!(window(0, &mut []), Ok(0x10_0000));
        assert_eq!(window(65_534, &mut []), Ok(0x10_0000));
        assert_eq!(
            window(65_535, &mut []),
            Err(ParseError::NoPlaceholderWindow)
        );
        assert_eq!(window(2, &mut [0x10_FFFC]), Ok(0x10_0000));
        assert_eq!(window(65_533, &mut [0x10_0000]), Ok(0x10_0001));
        assert_eq!(
            window(65_534, &mut [0x10_0000]),
            Err(ParseError::NoPlaceholderWindow)
        );
    }

    #[test]
    fn line_endings_nul_and_a_leading_byte_order_mark_read_as_comrak_reads_them() {
        let page = source("\u{FEFF}a\r\nb\rc\0\u{FEFF}\n\u{FFFC}", &[10]).unwrap();
        assert_eq!(page.text.as_str(), "a\nb\nc\u{FFFD}\u{FEFF}\n\u{100000}\n");
        assert_eq!(page.positions, [Position { line: 4, column: 1 }]);
        assert_eq!(
            page.atoms,
            [Atom {
                identity: "0".into(),
                offset: 10
            }]
        );
        assert_eq!(source("a\r", &[]).unwrap().text.as_str(), "a\n");
        assert_eq!(source("", &[]).unwrap().text.as_str(), "");
    }

    #[test]
    fn normalized_text_uses_a_wiping_owner_sized_for_nul_and_object_expansion() {
        use zeroize::{Zeroize, ZeroizeOnDrop};

        fn wiping_owner<T: ZeroizeOnDrop>(_: &T) {}

        let text = format!("{}\u{FFFC}", "\0".repeat(8192));
        let mut page = source(&text, &[8192]).unwrap();
        wiping_owner(&page.text);
        assert_eq!(
            page.text.as_str(),
            format!("{}\u{100000}\n", "\u{FFFD}".repeat(8192))
        );
        assert_eq!(page.text.capacity(), page.text.len());
        let pointer = page.text.as_ptr();
        page.text.as_mut_str().zeroize();
        assert!(page.text.as_bytes().iter().all(|byte| *byte == 0));
        assert_eq!(page.text.as_ptr(), pointer);
    }

    #[test]
    fn a_position_counts_utf8_bytes_before_the_placeholder() {
        let page = source("é\t😀\u{FFFC}\u{FFFC}", &[4, 5]).unwrap();
        assert_eq!(
            page.positions,
            [
                Position { line: 1, column: 8 },
                Position {
                    line: 1,
                    column: 12
                }
            ]
        );
    }

    #[test]
    fn pieces_split_at_this_pages_placeholders_only() {
        let page = source("\u{100000} \u{FFFC}", &[3]).unwrap();
        assert_eq!(page.text.as_str(), "\u{100000} \u{100001}\n");
        assert_eq!(
            page.pieces(&page.text),
            [
                Piece::Text("\u{100000} "),
                Piece::Atom(0),
                Piece::Text("\n")
            ]
        );
        assert_eq!(page.pieces("\u{100002}"), [Piece::Text("\u{100002}")]);
    }
}
