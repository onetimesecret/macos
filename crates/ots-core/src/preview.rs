//! Redacted, non-secret previews.
//!
//! A preview is computed **in the core**, from the plaintext, under the same
//! lock/zeroize discipline as the secret it summarises — and it is explicitly
//! non-sensitive, so it is one of the few things allowed to cross the FFI
//! (docs/01 §3). Values that look like secrets are masked; everything else is
//! shown only in a short, bounded window so an open panel is not a shoulder-
//! surfing hazard (docs/00 §10).
//!
//! ## Safe-by-default classification
//!
//! The rule is deliberately conservative: **any single unbroken token of
//! [`TOKEN_MIN_LEN`] or more characters is masked, whatever characters it
//! contains** — API keys, hashes, connection strings, symbol passwords, and long
//! numeric IDs (cards/accounts) all qualify. The only long single tokens shown
//! are plain `http(s)` URLs with no embedded credentials, because recognising a
//! URL is a core use. Multi-word content is shown truncated, except BIP39-style
//! seed phrases, which are masked.
//!
//! ## Known residual limitations (best-effort, not a guarantee)
//!
//! Content-based classification cannot be perfect. A short (< [`TOKEN_MIN_LEN`])
//! secret, or an arbitrary multi-word passphrase that is structurally
//! indistinguishable from an ordinary note, may still be previewed (truncated to
//! [`MAX_TEXT_PREVIEW`] characters). The real protections are ephemerality and
//! that the user *chooses* what to park (explicit capture, docs/00 §10); this
//! de-emphasis is a shoulder-surf mitigation, not a cryptographic control. The
//! trade-off runs the other way too: some long ordinary single words are masked
//! conservatively. For a secrets tool that is the right direction to err.

use crate::cell::CellKind;

/// Longest preview we ever emit for ordinary (non-sensitive) text. Short enough
/// to bound how much of an undetected passphrase could ever show.
const MAX_TEXT_PREVIEW: usize = 24;
/// Characters of a sensitive value we reveal as a recognition hint (e.g.
/// `sk-liv…`), and only when the value is much longer than this.
const SENSITIVE_REVEAL: usize = 6;
/// At or above this length, a whitespace-free token is treated as sensitive
/// regardless of its character set.
const TOKEN_MIN_LEN: usize = 12;
/// A whitespace-separated run of at least this many short lowercase words looks
/// like a BIP39 seed phrase.
const MNEMONIC_MIN_WORDS: usize = 12;

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
/// The returned string never contains a full sensitive value it can recognise,
/// and is bounded in length. It is safe to display and to hand across the FFI.
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
        let n = collapsed.chars().count();
        // Reveal a short recognition hint only for a long, unbroken token where
        // the hint is a small fraction. Multi-word secrets and anything short
        // are masked entirely — even a passphrase's first word is identifying.
        if collapsed.contains(char::is_whitespace) || n < 3 * SENSITIVE_REVEAL {
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

/// Heuristic: does this look like something we must hide? Safe-by-default —
/// masks broadly and only exempts things confidently recognised as non-secret.
fn looks_sensitive(s: &str) -> bool {
    if has_sensitive_prefix(s) {
        return true;
    }
    // A plain http(s) URL with no embedded credentials is shown (recognising a
    // URL is a core use). A URL carrying `user:pass@` has an '@' and so is not
    // "plain" — it falls through to the length rule and is masked.
    if is_plain_url(s) {
        return false;
    }
    if !s.contains(char::is_whitespace) {
        // Any single unbroken token this long is treated as a secret, whatever
        // characters it contains: keys, hashes, connection strings, symbol
        // passwords, long numeric IDs.
        return s.chars().count() >= TOKEN_MIN_LEN;
    }
    looks_like_mnemonic(s)
}

fn has_sensitive_prefix(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    SENSITIVE_PREFIXES
        .iter()
        .any(|p| s.starts_with(p) || lower.starts_with(&p.to_ascii_lowercase()))
}

fn is_plain_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")) && !s.contains('@')
}

/// Looks like a BIP39 seed phrase: many short, all-lowercase alphabetic words.
fn looks_like_mnemonic(s: &str) -> bool {
    let words: Vec<&str> = s.split_whitespace().collect();
    if words.len() < MNEMONIC_MIN_WORDS {
        return false;
    }
    words.iter().all(|w| {
        let n = w.chars().count();
        (3..=9).contains(&n) && w.chars().all(|c| c.is_ascii_lowercase())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordinary_short_text_is_shown_in_full() {
        assert_eq!(redact(b"call me later", CellKind::Text), "call me later");
    }

    #[test]
    fn ordinary_long_text_is_truncated() {
        let p = redact(
            b"Reminder buy milk eggs bread and coffee for the weekend trip",
            CellKind::Text,
        );
        assert!(p.starts_with("Reminder"));
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
    fn short_known_prefix_token_reveals_nothing() {
        // Known-prefix but short: masking a hint would leak most of it.
        assert_eq!(redact(b"ghp_abc", CellKind::Text), "•••");
    }

    #[test]
    fn connection_string_password_is_masked() {
        let p = redact(
            b"postgres://admin:s3cr3tP4ssw0rd@db.internal:5432/prod",
            CellKind::Text,
        );
        assert_eq!(p, "postgr…");
        assert!(
            !p.contains("s3cr3t"),
            "must not reveal the embedded password"
        );
    }

    #[test]
    fn symbol_password_is_masked() {
        // Symbols used to make a value LESS likely to be masked — no longer.
        let p = redact(b"Tr0ub4dor&3xperience!", CellKind::Text);
        assert!(p.ends_with('…'));
        assert!(
            !p.contains("xperience"),
            "must not reveal the password body"
        );
    }

    #[test]
    fn short_mixed_token_is_masked() {
        // 12 chars, mixed case + digits: sensitive, and too short to hint.
        assert_eq!(redact(b"aB3dE7gH1jK9", CellKind::Text), "•••");
    }

    #[test]
    fn long_numeric_id_is_masked() {
        // A 16-digit value (card/account) must not be shown in full.
        let p = redact(b"1234567890123456", CellKind::Text);
        assert_eq!(p, "•••");
    }

    #[test]
    fn seed_phrase_is_masked() {
        let phrase = "witch collapse practice feed shame open despair creek road again ice least";
        assert_eq!(redact(phrase.as_bytes(), CellKind::Text), "•••");
    }

    #[test]
    fn plain_url_is_shown_truncated() {
        let p = redact(b"https://example.com/path?q=1", CellKind::Text);
        assert!(p.starts_with("https://example.com"));
    }

    #[test]
    fn url_with_embedded_credentials_is_masked() {
        let p = redact(b"https://user:s3cret@example.com/x", CellKind::Text);
        assert!(p.ends_with('…'));
        assert!(
            !p.contains("s3cret"),
            "must not reveal embedded credentials"
        );
    }

    #[test]
    fn whitespace_is_collapsed() {
        assert_eq!(redact(b"  hello\n\tworld  ", CellKind::Text), "hello world");
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
