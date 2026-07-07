//! Redacted, non-secret previews.
//!
//! A preview is computed **in the core**, from the plaintext, under the same
//! lock/zeroize discipline as the secret it summarises — and it is explicitly
//! non-sensitive, so it is one of the few things allowed to cross the FFI
//! (docs/01 §3). Values that look like secrets are truncated and de-emphasised
//! so an open panel is not a shoulder-surfing hazard (docs/00 §10).

use crate::cell::CellKind;

/// Longest preview we ever emit for ordinary (non-sensitive) text.
const MAX_TEXT_PREVIEW: usize = 48;
/// Characters of a sensitive value we are willing to reveal as a recognition
/// hint (e.g. `sk-liv…`). Kept small on purpose.
const SENSITIVE_REVEAL: usize = 6;
/// At or above this length, a whitespace-free token is treated as sensitive.
const TOKEN_MIN_LEN: usize = 16;

/// Prefixes that mark a value as a credential regardless of length.
const SENSITIVE_PREFIXES: &[&str] = &[
    "sk-",
    "sk_",
    "pk_",
    "rk_",
    "ghp_",
    "gho_",
    "ghs_",
    "ghu_",
    "github_pat_",
    "xox",
    "AKIA",
    "ASIA",
    "AIza",
    "ya29.",
    "eyJ",
    "-----BEGIN",
    "Bearer ",
    "glpat-",
    "shpat_",
    "npm_",
    "dop_v1_",
    "sk-ant-",
];

/// Build a redacted preview of `bytes` for a cell of the given `kind`.
///
/// The returned string never contains a full sensitive value and is bounded in
/// length. It is safe to display and to hand across the FFI.
#[must_use]
pub fn redact(bytes: &[u8], kind: CellKind) -> String {
    match kind {
        CellKind::Image => format!("image · {} bytes", bytes.len()),
        CellKind::Text => redact_text(bytes),
    }
}

fn redact_text(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    let collapsed = collapse_whitespace(&text);
    if collapsed.is_empty() {
        return "(empty)".to_string();
    }

    if looks_sensitive(&collapsed) {
        // Only reveal a recognition hint when the value is long enough that the
        // hint is a small fraction of it (at least as many chars hidden as
        // shown). Otherwise mask entirely — a short secret would leak.
        if collapsed.chars().count() < 2 * SENSITIVE_REVEAL {
            return "•••".to_string();
        }
        let hint: String = collapsed.chars().take(SENSITIVE_REVEAL).collect();
        return format!("{hint}…");
    }

    truncate_chars(&collapsed, MAX_TEXT_PREVIEW)
}

/// Collapse all runs of whitespace to single spaces and trim the ends, so a
/// multi-line paste previews as one tidy line.
fn collapse_whitespace(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Truncate to at most `max` characters (never mid-codepoint), appending an
/// ellipsis when anything was dropped.
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let head: String = s.chars().take(max).collect();
    format!("{head}…")
}

/// Heuristic: does this look like a credential we should hide?
///
/// True when it carries a known credential prefix, or when it is a single
/// whitespace-free token of at least [`TOKEN_MIN_LEN`] made up of the character
/// set typical of keys and tokens.
fn looks_sensitive(s: &str) -> bool {
    if SENSITIVE_PREFIXES
        .iter()
        .any(|p| s.starts_with(p) || s.to_ascii_lowercase().starts_with(&p.to_ascii_lowercase()))
    {
        return true;
    }

    let single_token = !s.chars().any(char::is_whitespace);
    if single_token && s.chars().count() >= TOKEN_MIN_LEN {
        let tokenish = s
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '+' | '/' | '=' | '.'));
        if tokenish {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordinary_text_is_truncated_not_masked() {
        let p = redact(b"meet me by the fountain at noon", CellKind::Text);
        assert_eq!(p, "meet me by the fountain at noon");
    }

    #[test]
    fn long_text_gets_an_ellipsis() {
        let long = "a".repeat(100);
        let p = redact(long.as_bytes(), CellKind::Text);
        assert!(p.ends_with('…'));
        assert!(p.chars().count() <= MAX_TEXT_PREVIEW + 1);
    }

    #[test]
    fn api_token_is_masked_to_a_short_hint() {
        let p = redact(b"sk-live_4f9c2a7e9b1d3c5e7f9a1b3d5c7e9f", CellKind::Text);
        assert_eq!(p, "sk-liv…");
        assert!(!p.contains("4f9c"), "must not reveal the secret body");
    }

    #[test]
    fn long_random_token_without_prefix_is_masked() {
        let p = redact(b"4f9c2a7e9b1d3c5e7f9a1b3d5c7e9f01", CellKind::Text);
        assert!(p.ends_with('…'));
        assert!(p.chars().count() <= SENSITIVE_REVEAL + 1);
    }

    #[test]
    fn short_token_reveals_nothing() {
        let p = redact(b"ghp_abc", CellKind::Text);
        // Known-prefix but short: the hint would be most of it, so mask fully.
        assert_eq!(p, "•••");
    }

    #[test]
    fn urls_are_shown_they_are_not_treated_as_secret() {
        let p = redact(b"https://example.com/path?q=1", CellKind::Text);
        assert!(p.starts_with("https://example.com"));
    }

    #[test]
    fn whitespace_is_collapsed() {
        let p = redact(b"  hello\n\tworld  ", CellKind::Text);
        assert_eq!(p, "hello world");
    }

    #[test]
    fn empty_text_reads_as_empty() {
        assert_eq!(redact(b"   ", CellKind::Text), "(empty)");
    }

    #[test]
    fn image_preview_reports_size_only() {
        assert_eq!(redact(&[0u8; 2048], CellKind::Image), "image · 2048 bytes");
    }
}
