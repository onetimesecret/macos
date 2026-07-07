//! Secret-shape heuristics.
//!
//! How much detection is honest is open question №7. The stance here:
//! only precise, well-known shapes (documented token prefixes, PEM
//! blocks, URLs carrying a password, JWTs). No entropy guessing — a
//! false "this is safe" is worse than no claim, and a false "this is a
//! secret" teaches users to ignore the masking. Detection only ever
//! *adds* masking; content arriving marked `ConcealedType` is masked
//! regardless of what these heuristics think.

/// Returns the reason the text looks secret-shaped, or `None`.
///
/// The reason is UI-facing vocabulary ("GitHub token"), phrased as a
/// shape, never a certainty.
#[must_use]
pub fn secret_shape(text: &str) -> Option<&'static str> {
    if is_pem_block(text) {
        return Some("private key");
    }
    if has_url_password(text) {
        return Some("URL with password");
    }
    text.split(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ',' | ';' | '(' | ')'))
        .find_map(token_shape)
}

fn token_shape(token: &str) -> Option<&'static str> {
    known_prefix(token)
        .or_else(|| aws_access_key(token))
        .or_else(|| google_api_key(token))
        .or_else(|| jwt(token))
        .or_else(|| credential_assignment(token))
}

/// Documented, unambiguous vendor token prefixes. Each requires a
/// plausible payload length so prose like "sk-learn" never matches.
fn known_prefix(token: &str) -> Option<&'static str> {
    const PREFIXES: &[(&str, usize, &str)] = &[
        ("github_pat_", 22, "GitHub token"),
        ("ghp_", 20, "GitHub token"),
        ("gho_", 20, "GitHub token"),
        ("ghu_", 20, "GitHub token"),
        ("ghs_", 20, "GitHub token"),
        ("ghr_", 20, "GitHub token"),
        ("glpat-", 20, "GitLab token"),
        ("xoxb-", 20, "Slack token"),
        ("xoxp-", 20, "Slack token"),
        ("xoxs-", 20, "Slack token"),
        ("xoxa-", 20, "Slack token"),
        ("sk_live_", 20, "Stripe secret key"),
        ("sk_test_", 20, "Stripe secret key"),
        ("rk_live_", 20, "Stripe secret key"),
        ("sk-", 32, "API secret key"),
    ];
    PREFIXES.iter().find_map(|&(prefix, min_payload, reason)| {
        let payload = token.strip_prefix(prefix)?;
        (payload.len() >= min_payload
            && payload
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'))
        .then_some(reason)
    })
}

fn aws_access_key(token: &str) -> Option<&'static str> {
    ((token.starts_with("AKIA") || token.starts_with("ASIA"))
        && token.len() == 20
        && token
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
    .then_some("AWS access key")
}

fn google_api_key(token: &str) -> Option<&'static str> {
    (token.starts_with("AIza")
        && token.len() == 39
        && token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'))
    .then_some("Google API key")
}

/// Three dot-separated base64url segments, the first a `{"…` header.
fn jwt(token: &str) -> Option<&'static str> {
    let mut parts = token.split('.');
    let (header, payload, signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let b64url = |s: &str| {
        s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    (header.starts_with("eyJ")
        && header.len() >= 8
        && payload.len() >= 8
        && !signature.is_empty()
        && b64url(header)
        && b64url(payload)
        && b64url(signature))
    .then_some("JSON Web Token")
}

/// `password=…`, `secret=…`, `token=…`, `api_key=…` with a substantial
/// value. The length guard keeps documentation prose ("pass token=id")
/// from tripping it.
fn credential_assignment(token: &str) -> Option<&'static str> {
    const KEYS: &[&str] = &["password", "passwd", "secret", "token", "api_key", "apikey"];
    let (key, value) = token.split_once('=')?;
    (KEYS.contains(&key.to_ascii_lowercase().as_str()) && value.len() >= 8)
        .then_some("credential assignment")
}

fn is_pem_block(text: &str) -> bool {
    text.contains("-----BEGIN ") && text.contains("PRIVATE KEY-----")
}

/// `scheme://user:password@host` — a connection string carrying its
/// credential, the canonical thing to stage briefly and never archive.
fn has_url_password(text: &str) -> bool {
    text.split("://").skip(1).any(|rest| {
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        authority.split_once('@').is_some_and(|(userinfo, _)| {
            userinfo
                .split_once(':')
                .is_some_and(|(_, pw)| !pw.is_empty())
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_connection_url_with_password() {
        assert_eq!(
            secret_shape("postgres://ops:hunter2@db-3.internal:5432/prod"),
            Some("URL with password")
        );
        assert_eq!(
            secret_shape("redis://default:s3cret@cache.internal:6379"),
            Some("URL with password")
        );
    }

    #[test]
    fn plain_urls_and_emails_pass() {
        assert_eq!(secret_shape("https://onetimesecret.com/pricing"), None);
        assert_eq!(secret_shape("https://user@example.com/profile"), None);
        assert_eq!(secret_shape("write to ops@example.com today"), None);
    }

    #[test]
    fn detects_vendor_tokens() {
        assert_eq!(
            secret_shape("ghp_16C7e42F292c6912E7710c838347Ae178B4a"),
            Some("GitHub token")
        );
        assert_eq!(
            secret_shape("deploy key: glpat-XyZ123abcDEF456ghi789"),
            Some("GitLab token")
        );
        assert_eq!(
            secret_shape("xoxb-1234567890-abcdefghijklmnop"),
            Some("Slack token")
        );
        assert_eq!(
            secret_shape("sk_live_4eC39HqLyjWDarjtT1zdp7dc"),
            Some("Stripe secret key")
        );
        assert_eq!(secret_shape("AKIAIOSFODNN7EXAMPLE"), Some("AWS access key"));
        assert_eq!(
            secret_shape("AIzaSyA1234567890abcdefghijklmnopqrstu1"),
            Some("Google API key")
        );
    }

    #[test]
    fn prose_with_token_like_words_passes() {
        assert_eq!(secret_shape("sk-learn is a python library"), None);
        assert_eq!(secret_shape("the ghp_ prefix marks GitHub tokens"), None);
        assert_eq!(secret_shape("AKIA keys are twenty chars"), None);
    }

    #[test]
    fn detects_pem_and_jwt() {
        assert_eq!(
            secret_shape("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk...\n"),
            Some("private key")
        );
        assert_eq!(
            secret_shape(
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
            ),
            Some("JSON Web Token")
        );
    }

    #[test]
    fn sentences_with_dots_are_not_jwts() {
        assert_eq!(secret_shape("eyJust.a.sentence"), None);
        assert_eq!(secret_shape("version 1.2.3 released"), None);
    }

    #[test]
    fn detects_credential_assignment_conservatively() {
        assert_eq!(
            secret_shape("PASSWORD=correcthorsebatterystaple"),
            Some("credential assignment")
        );
        assert_eq!(secret_shape("token=abc"), None);
        assert_eq!(secret_shape("passwords are important"), None);
    }

    #[test]
    fn ordinary_prose_passes() {
        assert_eq!(secret_shape("14 Rue de la Paix, 75002 Paris"), None);
        assert_eq!(secret_shape("Meet at 15:30 — bring the deck"), None);
    }
}
