//! Experimental source-language detection adapter (ADR-0029).
//!
//! The thresholds below copy an external evaluation baseline. They are not
//! approved for shipping and remain subject to review against Companion's local
//! corpus. A returned slug is a model result that passed this provisional gate,
//! not proof that the input is source code.

use crate::FILE_SIZE_LIMIT;

const MINIMUM_NON_WHITESPACE_BYTES: usize = 20;
const MINIMUM_TOP_SCORE: f32 = 0.20;
const MINIMUM_TOP_TWO_MARGIN: f32 = 0.20;

/// Detect a canonical Betlang source-language slug.
///
/// This experimental production-path API abstains for oversized or ineligible
/// text and for rankings that do not pass the provisional confidence gate. The
/// `20 bytes / 0.20 score / 0.20 margin` gate is an external evaluation baseline,
/// is not approved for shipping, and remains subject to local corpus review.
/// A returned slug is not an assurance that the input is source code.
pub fn detect_source_language(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() > FILE_SIZE_LIMIT || bytes.contains(&0) {
        return None;
    }

    let source = std::str::from_utf8(bytes).ok()?;
    let evidence = bytes
        .iter()
        .filter(|byte| !byte.is_ascii_whitespace())
        .count();
    if evidence < MINIMUM_NON_WHITESPACE_BYTES {
        return None;
    }

    let detection = betlang::detect(source);
    let ranked = detection.top_languages().collect::<Vec<_>>();
    if !ranking_is_accepted(ranked.iter().map(|(score, _)| *score)) {
        return None;
    }

    ranked.first().map(|(_, language)| language.slug())
}

fn ranking_is_accepted(scores: impl IntoIterator<Item = f32>) -> bool {
    let mut scores = scores.into_iter();
    let Some(top) = scores.next() else {
        return false;
    };
    let Some(second) = scores.next() else {
        return false;
    };

    top.is_finite()
        && second.is_finite()
        && scores.all(f32::is_finite)
        && top >= MINIMUM_TOP_SCORE
        && top >= second + MINIMUM_TOP_TWO_MARGIN
}

#[cfg(test)]
mod tests {
    use super::*;

    const PYTHON: &[u8] = b"def total(values):\n    return sum(value for value in values if value > 0)\n\nprint(total([1, -2, 3]))";

    #[test]
    fn canonical_result_passes_the_provisional_gate() {
        assert_eq!(detect_source_language(PYTHON), Some("python"));
    }

    #[test]
    fn input_eligibility_abstains_before_inference() {
        assert_eq!(
            detect_source_language(&vec![b'x'; FILE_SIZE_LIMIT + 1]),
            None
        );
        assert_eq!(
            detect_source_language(b"fn main() {\0 println!(\"no\"); }"),
            None
        );
        assert_eq!(detect_source_language(&[0xff; 20]), None);
        assert_eq!(detect_source_language(b"fn x() {}"), None);
    }

    #[test]
    fn evidence_count_matches_the_evaluation_harness() {
        let unicode = "界界界界界界界".as_bytes();
        assert_eq!(
            unicode
                .iter()
                .filter(|byte| !byte.is_ascii_whitespace())
                .count(),
            unicode.len()
        );
    }

    #[test]
    fn ranking_threshold_edges_are_explicit() {
        assert!(!ranking_is_accepted([]));
        assert!(!ranking_is_accepted([0.90]));
        assert!(!ranking_is_accepted([0.199_999, 0.0]));
        assert!(ranking_is_accepted([0.20, 0.0]));
        assert!(!ranking_is_accepted([0.50, 0.300_001]));
        assert!(ranking_is_accepted([0.50, 0.30]));
    }

    #[test]
    fn ranking_rejects_nonfinite_scores() {
        assert!(!ranking_is_accepted([f32::NAN, f32::NAN]));
        assert!(!ranking_is_accepted([f32::INFINITY, 0.0]));
        assert!(!ranking_is_accepted([0.80, f32::NEG_INFINITY]));
        assert!(!ranking_is_accepted([0.80, 0.10, f32::NAN]));
    }
}
