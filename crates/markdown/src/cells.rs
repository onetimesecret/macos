//! An upper bound on the table cells comrak makes of a GFM page, read before it parses.

/// The cells every table of `text` can make together, header rows and padding included: each
/// line is charged the widest delimiter row candidate since the last blank line.
pub(crate) fn bound(text: &str) -> u64 {
    let mut total = 0u64;
    let mut widest = 0u64;
    for line in lines(text.as_bytes()) {
        if line.iter().all(|byte| matches!(byte, b' ' | b'\t')) {
            widest = 0;
            continue;
        }
        if let Some(runs) = delimiter_runs(line) {
            widest = widest.max(runs);
        }
        total = total.saturating_add(widest);
    }
    total
}

/// Lines as comrak splits them: LF, CR or CRLF ends one.
fn lines(text: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut start = 0;
    std::iter::from_fn(move || {
        if start > text.len() {
            return None;
        }
        let rest = &text[start..];
        let length = rest
            .iter()
            .position(|byte| matches!(byte, b'\n' | b'\r'))
            .unwrap_or(rest.len());
        let ending = match rest.get(length..length + 2) {
            Some(b"\r\n") => 2,
            _ => 1,
        };
        start += length + ending;
        Some(&rest[..length])
    })
}

/// A line of container prefixes and delimiter row bytes alone, with a `-`: its count of `-` runs.
fn delimiter_runs(line: &[u8]) -> Option<u64> {
    let mut runs = 0u64;
    let mut previous = 0u8;
    for &byte in line {
        match byte {
            b'-' if previous != b'-' => runs += 1,
            b'-' | b' ' | b'\t' | b'\x0b' | b'\x0c' | b'>' | b'|' | b':' => {}
            _ => return None,
        }
        previous = byte;
    }
    (runs > 0).then_some(runs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Dialect, options};
    use comrak::nodes::NodeValue;
    use comrak::{Arena, parse_document};

    fn cells(text: &str) -> u64 {
        let arena = Arena::new();
        let root = parse_document(&arena, text, &options(Dialect::Gfm));
        let count = root
            .descendants()
            .filter(|node| matches!(node.data().value, NodeValue::TableCell))
            .count();
        u64::try_from(count).unwrap()
    }

    #[test]
    fn lines_end_at_lf_cr_or_crlf() {
        let split: Vec<&[u8]> = lines(b"a\nb\rc\r\nd\n\re").collect();
        assert_eq!(split, [&b"a"[..], b"b", b"c", b"d", b"", b"e"]);
        assert_eq!(lines(b"").count(), 1);
    }

    #[test]
    fn a_delimiter_row_candidate_counts_its_dash_runs() {
        assert_eq!(delimiter_runs(b"| - | :--: |"), Some(2));
        assert_eq!(delimiter_runs(b"> \t|-|-|-"), Some(3));
        assert_eq!(delimiter_runs(b"| \x0b- | \x0c- |"), Some(2));
        assert_eq!(delimiter_runs(b"| : |"), None);
        assert_eq!(delimiter_runs(b"| - | a |"), None);
        assert_eq!(delimiter_runs(b"1. | - |"), None);
    }

    #[test]
    fn each_line_after_a_delimiter_row_is_charged_its_width_until_a_blank_line() {
        let six = "| a | b |\n| - | - |\n| c |\n| d |";
        assert_eq!(bound(six), 6);
        assert_eq!(cells(six), 6);
        assert_eq!(bound(&format!("{six}\n| e |")), 8);
        let two = "| a | b |\n| - | - |\n| c |\n\n| a | b |\n| - | - |\n| d |";
        assert_eq!(bound(two), 8);
        assert_eq!(cells(two), 8);
        assert_eq!(bound("| a | b |\r\n| - | - |\r\n| c |\r \t\r| d |"), 4);
    }

    #[test]
    fn an_objects_placeholder_prevents_a_delimiter_row_after_normalization() {
        for template in [
            "| a |\r\n| -{obj} |\r\n| b |",
            "> | a |\r> | -{obj} |\r> | b |",
        ] {
            let (text, offsets) = crate::tests::page(template);
            let source =
                crate::source::Source::new(&text, &offsets, &crate::Limits::default()).unwrap();
            assert!(!source.text.contains('\r'));
            assert_eq!(cells(&source.text), 0);
            assert_eq!(bound(&source.text), 0);
        }
    }

    /// Issue 332's work bound: 2,000 columns by 262 rows ask for 526,000 cells.
    #[test]
    fn the_wide_table_fixture_is_over_the_default_budget_before_any_parse() {
        let wide = format!(
            "|{}\n|{}\n{}",
            " a |".repeat(2_000),
            " - |".repeat(2_000),
            "x\n".repeat(262)
        );
        assert_eq!(bound(&wide), 526_000);
        assert_eq!(bound(&format!("{wide}\n").repeat(3)), 3 * 526_000);
    }

    /// splitmix64, so the corpus is the same on every run.
    struct Random(u64);

    impl Random {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }

        fn below(&mut self, count: usize) -> usize {
            usize::try_from(self.next() % u64::try_from(count).unwrap()).unwrap()
        }

        fn between(&mut self, low: usize, high: usize) -> usize {
            low + self.below(high - low + 1)
        }

        fn chance(&mut self, percent: usize) -> bool {
            self.below(100) < percent
        }

        fn pick<'a>(&mut self, choices: &[&'a str]) -> &'a str {
            choices[self.below(choices.len())]
        }
    }

    const CELLS: &[&str] = &[
        "a",
        "",
        " ",
        "b c",
        "a\\|b",
        "`x|y`",
        "`a\\|b`",
        "**s**",
        "-",
        ":",
        "--",
        "x-y",
        "\\",
        "\t",
        "&#124;",
        "<b>|</b>",
        "~z~",
        "\u{100000}",
    ];

    fn row(random: &mut Random, count: usize) -> String {
        let mut lead = random.chance(70);
        let trail = random.chance(60);
        let cells: Vec<&str> = (0..count).map(|_| random.pick(CELLS)).collect();
        if count == 1 && !lead && !trail {
            lead = true;
        }
        format!(
            "{}{}{}",
            if lead { "|" } else { "" },
            cells.join("|"),
            if trail { "|" } else { "" }
        )
    }

    fn delimiter(random: &mut Random, count: usize) -> String {
        let parts: Vec<String> = (0..count)
            .map(|_| {
                let before = random.pick(&["", " ", "\t", "\x0b"]);
                let marker = random.pick(&["-", "--", "---", ":-", "-:", ":-:", ":---:"]);
                let after = random.pick(&["", " ", "  "]);
                format!("{before}{marker}{after}")
            })
            .collect();
        let lead = random.chance(70) || count == 1;
        let trail = random.chance(60);
        format!(
            "{}{}{}",
            if lead { "|" } else { "" },
            parts.join("|"),
            if trail { "|" } else { "" }
        )
    }

    fn table(random: &mut Random) -> Vec<String> {
        let columns = random.between(1, 9);
        let header = if random.chance(85) {
            columns
        } else if random.chance(50) {
            columns.saturating_sub(1).max(1)
        } else {
            columns + 1
        };
        let mut lines = vec![row(random, header), delimiter(random, columns)];
        for _ in 0..random.between(0, 12) {
            let kind = random.below(10);
            lines.push(match kind {
                0..=4 => {
                    let count = random.between(1, columns + 3);
                    row(random, count)
                }
                5 => random
                    .pick(&[
                        "x",
                        "plain text",
                        "a | b",
                        "\\|",
                        "`|`",
                        "-",
                        "|",
                        "\x0b",
                        "  x",
                    ])
                    .to_owned(),
                6 => random
                    .pick(&["# h", "> q", "- li", "1. li", "***", "```", "<div>"])
                    .to_owned(),
                _ => {
                    let count = random.between(columns, columns + 2);
                    row(random, count)
                }
            });
        }
        lines
    }

    fn other(random: &mut Random) -> Vec<String> {
        let blocks: &[&[&str]] = &[
            &["para - with - dashes"],
            &["---"],
            &["Title", "---"],
            &["# h"],
            &["```", "|a|", "|-|", "```"],
            &["a", "-|-", "b"],
            &["text"],
            &["- a", "- b"],
            &["<div>", "|x|", "|-|", "</div>"],
            &["|"],
            &["\x0b"],
            &["-|-|-|-|-|-|-|-|-"],
            &["a|b", "-|-"],
        ];
        let block = blocks[random.below(blocks.len())];
        block.iter().map(|&line| line.to_owned()).collect()
    }

    fn wrap(random: &mut Random, lines: Vec<String>) -> Vec<String> {
        let kind = random.below(100);
        match kind {
            0..45 => lines,
            45..65 => lines.iter().map(|line| format!("> {line}")).collect(),
            65..75 => {
                let cut = random.between(1, lines.len());
                let (quoted, lazy) = lines.split_at(cut);
                quoted
                    .iter()
                    .map(|line| format!("> {line}"))
                    .chain(lazy.iter().cloned())
                    .collect()
            }
            75..90 => {
                let indent = random.pick(&["  ", "   ", "\t"]);
                let mut wrapped = vec![format!("- {}", lines[0])];
                wrapped.extend(lines[1..].iter().map(|line| format!("{indent}{line}")));
                wrapped
            }
            _ => {
                let mut wrapped = vec![format!("> - {}", lines[0])];
                wrapped.extend(lines[1..].iter().map(|line| format!(">   {line}")));
                wrapped
            }
        }
    }

    fn page(random: &mut Random) -> String {
        let mut page = String::new();
        for _ in 0..random.between(1, 6) {
            let lines = if random.chance(60) {
                table(random)
            } else {
                other(random)
            };
            page.push_str(&wrap(random, lines).join("\n"));
            page.push_str(random.pick(&["\n", "\n\n", "\n\n", "\n  \n"]));
        }
        let ending = random.pick(&["\n", "\n", "\n", "\n", "\n", "\n", "\n", "\n", "\r\n", "\r"]);
        page.replace('\n', ending)
    }

    /// The scratchpad probe's corpus generator (issue 332), ported with a fixed seed.
    #[test]
    fn no_generated_page_makes_more_cells_than_its_bound() {
        let count = std::env::var("COMPANION_MARKDOWN_TABLE_FUZZ_PAGES")
            .map(|value| value.parse::<usize>().expect("a decimal page count"))
            .unwrap_or(4_000);
        let seed = std::env::var("COMPANION_MARKDOWN_TABLE_FUZZ_SEED")
            .map(|value| value.parse::<u64>().expect("a decimal seed"))
            .unwrap_or(332);
        assert!(count >= 4_000, "at least 4,000 generated pages");
        let mut random = Random(seed);
        let mut tables = 0;
        for index in 0..count {
            let text = page(&mut random);
            let made = cells(&text);
            assert!(
                made <= bound(&text),
                "seed {seed}, page {index}: {text:?}: {made} > {}",
                bound(&text),
            );
            tables += usize::from(made > 0);
        }
        assert!(tables > 1_000, "the corpus makes tables: {tables}");
    }
}
