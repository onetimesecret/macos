//! Experimental source-language detection (ADR-0029); thresholds are
//! provisional and not approved for shipping.

use companion_language_detection_policy::{
    PRODUCTION_POLICY, eligibility_rejection, ranking_rejection,
};

/// A canonical Betlang language slug, or `None` when the input or the
/// ranking fails the provisional gate.
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
    fn evidence_is_counted_in_bytes_less_ascii_whitespace() {
        use companion_language_detection_policy::count_non_whitespace;
        assert_eq!(count_non_whitespace("界界界".as_bytes()), 9);
        assert_eq!(count_non_whitespace(b" \t\r\n"), 0);
        assert_eq!(count_non_whitespace("界 界\t界\n".as_bytes()), 9);
        assert_eq!(count_non_whitespace("a\u{a0}b".as_bytes()), 4);
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
