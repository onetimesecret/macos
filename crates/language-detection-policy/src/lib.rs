//! Shared pure policy for production and source-language evaluation adapters.

/// Eligibility and confidence thresholds for source-language detection.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DetectionPolicy {
    /// Minimum count of non-ASCII-whitespace bytes.
    pub minimum_non_whitespace_bytes: usize,
    /// Inclusive minimum score for the first ranked language.
    pub minimum_top_score: f32,
    /// Inclusive minimum gap between the first two ranked scores.
    pub minimum_top_two_margin: f32,
    /// Maximum accepted input length in bytes.
    pub maximum_input_bytes: usize,
}

/// Reason input bytes are ineligible for inference.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EligibilityRejection {
    /// Input exceeds the configured byte limit.
    InputExceedsMaximumBytes,
    /// Input contains an embedded NUL byte.
    InputContainsNul,
    /// Input is not valid UTF-8.
    InputIsNotUtf8,
    /// Input contains too little non-whitespace evidence.
    InsufficientNonWhitespaceBytes,
}

/// Reason a model ranking does not satisfy the confidence policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RankingRejection {
    /// Fewer than two ranked candidates were returned.
    FewerThanTwoRankings,
    /// At least one score is NaN or infinite.
    NonFiniteScore,
    /// The leading score is below the configured minimum.
    TopScoreBelowMinimum,
    /// The leading score is too close to the second score.
    TopTwoMarginBelowMinimum,
}

/// Provisional policy currently used by the production adapter.
pub const PRODUCTION_POLICY: DetectionPolicy = DetectionPolicy {
    minimum_non_whitespace_bytes: 20,
    minimum_top_score: 0.20,
    minimum_top_two_margin: 0.20,
    maximum_input_bytes: 4 * 1024 * 1024,
};

/// Count bytes other than ASCII whitespace.
pub fn count_non_whitespace(input: &[u8]) -> usize {
    input
        .iter()
        .filter(|byte| !byte.is_ascii_whitespace())
        .count()
}

/// Return why an input is ineligible, or `None` when inference may run.
pub fn eligibility_rejection(
    input: &[u8],
    policy: DetectionPolicy,
) -> Option<EligibilityRejection> {
    if input.len() > policy.maximum_input_bytes {
        Some(EligibilityRejection::InputExceedsMaximumBytes)
    } else if input.contains(&0) {
        Some(EligibilityRejection::InputContainsNul)
    } else if std::str::from_utf8(input).is_err() {
        Some(EligibilityRejection::InputIsNotUtf8)
    } else if count_non_whitespace(input) < policy.minimum_non_whitespace_bytes {
        Some(EligibilityRejection::InsufficientNonWhitespaceBytes)
    } else {
        None
    }
}

/// Return why ranked scores fail confidence checks, or `None` when accepted.
pub fn ranking_rejection(
    scores: impl IntoIterator<Item = f32>,
    policy: DetectionPolicy,
) -> Option<RankingRejection> {
    let mut scores = scores.into_iter();
    let Some(top) = scores.next() else {
        return Some(RankingRejection::FewerThanTwoRankings);
    };
    let Some(second) = scores.next() else {
        return Some(RankingRejection::FewerThanTwoRankings);
    };
    if !top.is_finite() || !second.is_finite() || !scores.all(f32::is_finite) {
        return Some(RankingRejection::NonFiniteScore);
    }
    if top < policy.minimum_top_score {
        return Some(RankingRejection::TopScoreBelowMinimum);
    }
    if top < second + policy.minimum_top_two_margin {
        return Some(RankingRejection::TopTwoMarginBelowMinimum);
    }
    None
}
