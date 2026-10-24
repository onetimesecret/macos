//! The shell's `MarkdownCorpusTests`: the `CommonMark` 0.31.2 and GFM 0.29 examples (`tests/README.md`)
//! read by `parse`, written back by `html::html` and compared byte for byte with the spec's HTML.

use std::collections::BTreeSet;

use serde::Deserialize;

use super::html::html;
use crate::{Dialect, Limits, parse};

const COMMONMARK_SPEC: &[u8] = include_bytes!("../../tests/commonmark-0.31.2-spec.json");
const COMMONMARK_SPEC_SHA256: &str =
    "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20";
const GFM_EXAMPLES: &[u8] = include_bytes!("../../tests/gfm-0.29-examples.json");
const GFM_EXAMPLES_SHA256: &str =
    "a651225602a1c9789c9dde3eda3a24fcc1151a14f364d77de8fd410f62616310";

/// Examples whose specification HTML the `CommonMark` reading does not produce.
const COMMONMARK_MISMATCHES: &[(usize, &str)] = &[];

/// Examples whose specification HTML the GFM reading does not produce, and what it does instead.
const GFM_MISMATCHES: &[(usize, &str)] = &[
    (
        140,
        "the tagfilter writes `<script` and `</script` as `&lt;script` and `&lt;/script`; the example shows the block unfiltered",
    ),
    (
        141,
        "the tagfilter writes `<style` and `</style` as `&lt;style` and `&lt;/style`; the example shows the block unfiltered",
    ),
    (
        142,
        "the tagfilter writes `<style` as `&lt;style`; the example shows the block unfiltered",
    ),
    (
        145,
        "the tagfilter writes `<style>` and `</style>` as `&lt;style>` and `&lt;/style>`; the example shows the block unfiltered",
    ),
    (
        147,
        "the tagfilter writes `<script>` and `</script>` as `&lt;script>` and `&lt;/script>`; the example shows the block unfiltered",
    ),
    (
        611,
        "the extended autolink links `http://foo.bar/baz` inside `<http://foo.bar/baz bim>`",
    ),
    (
        617,
        "the extended autolink links `http://foo.bar` inside `< http://foo.bar >`",
    ),
    (620, "the extended autolink links `http://example.com`"),
    (
        621,
        "the extended email autolink links `foo@bar.example.com` as `mailto:`",
    ),
    (
        634,
        "the email autolink gives up at a second `@` (`email_match`), so `xmpp:foo@bar.baz/txt@bin` stays text and only `txt@bin.com` links, as `mailto:`",
    ),
    (
        635,
        "the xmpp autolink continues past every `/` (`email_match`), so `xmpp:foo@bar.baz/txt/bin` links whole",
    ),
    (
        649,
        "`<!-- not a comment -- two hyphens -->` is raw HTML under the CommonMark 0.31 comment grammar; GFM 0.29 refuses `--` inside",
    ),
    (
        650,
        "`<!-->` is a whole comment under the CommonMark 0.31 grammar; GFM 0.29 escapes it",
    ),
];

/// One numbered example of an official specification.
#[derive(Deserialize)]
struct Example {
    example: usize,
    section: String,
    markdown: String,
    html: String,
}

struct Outcome<'a> {
    example: &'a Example,
    actual: String,
}

impl Outcome<'_> {
    fn matches(&self) -> bool {
        self.actual.as_bytes() == self.example.html.as_bytes()
    }
}

fn examples(data: &[u8]) -> Vec<Example> {
    serde_json::from_slice(data).expect("the corpus reads as the recorded examples")
}

fn sha256(data: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, data)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn outcomes(examples: &[Example], dialect: Dialect) -> Vec<Outcome<'_>> {
    examples
        .iter()
        .map(|example| Outcome {
            example,
            actual: match parse(&example.markdown, dialect, Limits::default()) {
                Ok(document) => html(&document, dialect),
                Err(error) => format!("parse refused the page: {error:?}"),
            },
        })
        .collect()
}

/// The mismatching examples must be the table's keys: a new mismatch fails, and so does a fixed one.
fn assert_mismatches(outcomes: &[Outcome<'_>], known: &[(usize, &str)], name: &str) {
    let numbers: BTreeSet<usize> = outcomes
        .iter()
        .map(|outcome| outcome.example.example)
        .collect();
    let mismatched: BTreeSet<usize> = outcomes
        .iter()
        .filter(|outcome| !outcome.matches())
        .map(|outcome| outcome.example.example)
        .collect();
    let mut failures = Vec::new();
    for outcome in outcomes {
        let number = outcome.example.example;
        if !outcome.matches() && !known.iter().any(|(known, _)| *known == number) {
            failures.push(format!(
                "{name} example {number} ({}) differs from the specification\n\
                 markdown: {:?}\nexpected: {:?}\nactual:   {:?}",
                outcome.example.section,
                outcome.example.markdown,
                outcome.example.html,
                outcome.actual,
            ));
        }
    }
    for (number, reason) in known {
        if !mismatched.contains(number) {
            let state = if numbers.contains(number) {
                "now matches the specification"
            } else {
                "is not an example"
            };
            failures.push(format!(
                "{name} example {number} {state}; drop it from the table ({reason})"
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn the_copied_specifications_are_the_recorded_files() {
    assert_eq!(sha256(COMMONMARK_SPEC), COMMONMARK_SPEC_SHA256);
    assert_eq!(sha256(GFM_EXAMPLES), GFM_EXAMPLES_SHA256);
}

#[test]
fn the_mismatch_tables_are_in_ascending_order_with_no_repeats() {
    for table in [COMMONMARK_MISMATCHES, GFM_MISMATCHES] {
        assert!(table.windows(2).all(|pair| pair[0].0 < pair[1].0));
    }
}

#[test]
fn the_commonmark_examples_are_numbered_one_to_652() {
    let numbers: Vec<usize> = examples(COMMONMARK_SPEC)
        .iter()
        .map(|example| example.example)
        .collect();
    assert_eq!(numbers, (1..=652).collect::<Vec<_>>());
}

#[test]
fn the_gfm_examples_are_numbered_one_to_677() {
    let numbers: Vec<usize> = examples(GFM_EXAMPLES)
        .iter()
        .map(|example| example.example)
        .collect();
    assert_eq!(numbers, (1..=677).collect::<Vec<_>>());
}

#[test]
fn every_commonmark_example_renders_as_the_specification_shows() {
    let examples = examples(COMMONMARK_SPEC);
    assert_mismatches(
        &outcomes(&examples, Dialect::CommonMark),
        COMMONMARK_MISMATCHES,
        "CommonMark",
    );
}

#[test]
fn every_gfm_example_renders_as_the_specification_shows_beyond_the_known_mismatches() {
    let examples = examples(GFM_EXAMPLES);
    assert_mismatches(&outcomes(&examples, Dialect::Gfm), GFM_MISMATCHES, "GFM");
}

#[test]
fn the_exact_match_counts_are_reported() {
    let commonmark_examples = examples(COMMONMARK_SPEC);
    let gfm_examples = examples(GFM_EXAMPLES);
    let commonmark = outcomes(&commonmark_examples, Dialect::CommonMark);
    let gfm = outcomes(&gfm_examples, Dialect::Gfm);
    let commonmark_exact = commonmark
        .iter()
        .filter(|outcome| outcome.matches())
        .count();
    let gfm_exact = gfm.iter().filter(|outcome| outcome.matches()).count();
    let report = format!(
        "Markdown corpus exact HTML: CommonMark 0.31.2 {commonmark_exact} of {}, GFM 0.29 {gfm_exact} of {}",
        commonmark.len(),
        gfm.len(),
    );
    println!("{report}");
    assert_eq!(commonmark.len(), 652, "{report}");
    assert_eq!(gfm.len(), 677, "{report}");
    assert_eq!(
        commonmark_exact,
        commonmark.len() - COMMONMARK_MISMATCHES.len(),
        "{report}"
    );
    assert_eq!(gfm_exact, gfm.len() - GFM_MISMATCHES.len(), "{report}");
}
