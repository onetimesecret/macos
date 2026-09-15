//! Experimental source-language detection adapter (ADR-0029).
//!
//! The thresholds below copy an external evaluation baseline. They are not
//! approved for shipping and remain subject to review against Companion's local
//! corpus. A returned slug is a model result that passed this provisional gate,
//! not proof that the input is source code.

use companion_language_detection_policy::{
    PRODUCTION_POLICY, eligibility_rejection, ranking_rejection,
};

/// Detect a canonical Betlang source-language slug.
///
/// This experimental production-path API abstains for oversized or ineligible
/// text and for rankings that do not pass the provisional confidence gate. The
/// `20 bytes / 0.20 score / 0.20 margin` gate is an external evaluation baseline,
/// is not approved for shipping, and remains subject to local corpus review.
/// A returned slug is not an assurance that the input is source code.
pub fn detect_source_language(bytes: &[u8]) -> Option<&'static str> {
    if eligibility_rejection(bytes, PRODUCTION_POLICY).is_some() {
        return None;
    }

    let source = std::str::from_utf8(bytes).ok()?;
    let detection = betlang::detect(source);
    let ranked = detection.top_languages().collect::<Vec<_>>();
    if ranking_rejection(ranked.iter().map(|(score, _)| *score), PRODUCTION_POLICY).is_some() {
        return None;
    }

    ranked.first().map(|(_, language)| language.slug())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PYTHON: &[u8] = b"def total(values):\n    return sum(value for value in values if value > 0)\n\nprint(total([1, -2, 3]))";

    #[test]
    fn production_policy_uses_the_file_size_limit() {
        assert_eq!(
            PRODUCTION_POLICY.maximum_input_bytes,
            crate::FILE_SIZE_LIMIT
        );
    }

    #[test]
    fn canonical_result_passes_the_provisional_gate() {
        assert_eq!(detect_source_language(PYTHON), Some("python"));
    }

    #[test]
    fn input_eligibility_abstains_before_inference() {
        assert_eq!(
            detect_source_language(&vec![b'x'; PRODUCTION_POLICY.maximum_input_bytes + 1]),
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
        assert!(ranking_rejection([], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.90], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.199_999, 0.0], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.20, 0.0], PRODUCTION_POLICY).is_none());
        assert!(ranking_rejection([0.50, 0.300_001], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.50, 0.30], PRODUCTION_POLICY).is_none());
    }

    #[test]
    fn ranking_rejects_nonfinite_scores() {
        assert!(ranking_rejection([f32::NAN, f32::NAN], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([f32::INFINITY, 0.0], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.80, f32::NEG_INFINITY], PRODUCTION_POLICY).is_some());
        assert!(ranking_rejection([0.80, 0.10, f32::NAN], PRODUCTION_POLICY).is_some());
    }
}
