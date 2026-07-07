//! The `conceal` call: turn a cell's text into a one-time Onetime Secret link.

use base64::Engine;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// HTTP Basic credentials for the API. The `extid` is the username (not
/// secret); the `token` is the password and wipes on drop.
pub struct Credentials {
    pub extid: String,
    pub token: Zeroizing<String>,
}

impl Credentials {
    #[must_use]
    pub fn new(extid: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            extid: extid.into(),
            token: Zeroizing::new(token.into()),
        }
    }
}

/// Options for a conceal call. `ttl_secs` is the **link's** server-side lifespan
/// (§6.3) — a different clock from the cell's local TTL.
pub struct ConcealOpts {
    pub ttl_secs: u64,
    pub share_domain: Option<String>,
    pub passphrase: Option<Zeroizing<String>>,
    pub recipient: Option<String>,
}

impl ConcealOpts {
    /// Minimal options: just a link lifespan, no passphrase or recipient.
    #[must_use]
    pub fn new(ttl_secs: u64) -> Self {
        Self {
            ttl_secs,
            share_domain: None,
            passphrase: None,
            recipient: None,
        }
    }
}

/// The outputs of a successful conceal — a share link for the recipient and a
/// private receipt for the creator. These are *outputs*, never the secret: the
/// plaintext was consumed in the core and wiped (docs/01 §3).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ShareLink {
    /// The URL to hand to the recipient. Reveals the secret exactly once.
    pub share_url: String,
    /// The one-time secret key embedded in `share_url`.
    pub secret_key: String,
    /// The creator's private receipt URL (manage/burn the secret).
    pub metadata_url: String,
    /// The private metadata key. Must not be shared.
    pub metadata_key: String,
    /// The link's server-side lifespan in seconds, if the server reported it.
    pub ttl_secs: Option<u64>,
}

/// Errors from a conceal call. No variant embeds secret material; `Api.message`
/// is server-supplied text, never local plaintext.
#[derive(Debug, thiserror::Error)]
pub enum ConcealError {
    #[error("cell content is not text and cannot be concealed")]
    NotText,
    #[error("no API configuration set")]
    MissingConfig,
    #[error("no API credentials stored")]
    MissingCredentials,
    #[error("no such cell")]
    UnknownCell,
    #[error("built without the `http` feature; the network send is unavailable")]
    HttpUnavailable,
    #[error("request transport error: {0}")]
    Http(String),
    #[error("server returned {status}: {message}")]
    Api { status: u16, message: String },
    #[error("could not parse the server response: {0}")]
    Parse(String),
}

/// A client bound to one API base URL.
pub struct ConcealClient {
    base_url: String,
    #[cfg(feature = "http")]
    http: reqwest::blocking::Client,
}

impl ConcealClient {
    /// Build a client for `base_url` (e.g. `https://onetimesecret.com`).
    #[must_use]
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            #[cfg(feature = "http")]
            http: build_http_client(),
        }
    }

    /// The base URL this client targets.
    #[must_use]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Conceal `secret` (UTF-8 text) with `opts`, authenticating with `creds`.
    /// Builds the request wholly in-core, sends it, and returns the resulting
    /// [`ShareLink`].
    pub fn conceal(
        &self,
        secret: &str,
        opts: &ConcealOpts,
        creds: &Credentials,
    ) -> Result<ShareLink, ConcealError> {
        let body = build_body(secret, opts);
        let auth = auth_header(creds);
        self.send(&body, &auth)
    }

    #[cfg(feature = "http")]
    fn send(&self, body: &str, auth: &str) -> Result<ShareLink, ConcealError> {
        let endpoint = format!(
            "{}/api/v3/secret/conceal",
            self.base_url.trim_end_matches('/')
        );
        let resp = self
            .http
            .post(endpoint)
            .header(reqwest::header::AUTHORIZATION, auth)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body.to_owned())
            .send()
            .map_err(|e| ConcealError::Http(e.to_string()))?;

        let status = resp.status();
        let text = resp.text().map_err(|e| ConcealError::Http(e.to_string()))?;
        if !status.is_success() {
            return Err(ConcealError::Api {
                status: status.as_u16(),
                message: truncate(&text, 300),
            });
        }
        parse_response(&self.base_url, &text)
    }

    #[cfg(not(feature = "http"))]
    #[allow(clippy::unused_self)]
    fn send(&self, _body: &str, _auth: &str) -> Result<ShareLink, ConcealError> {
        Err(ConcealError::HttpUnavailable)
    }
}

#[cfg(feature = "http")]
fn build_http_client() -> reqwest::blocking::Client {
    reqwest::blocking::Client::builder()
        .user_agent(concat!("ots-cache/", env!("CARGO_PKG_VERSION")))
        .build()
        .unwrap_or_else(|_| reqwest::blocking::Client::new())
}

/// The v3 request envelope: the payload is nested under a `secret` key
/// (docs/00 §12). Optional fields are omitted when absent.
#[derive(Serialize)]
struct ConcealEnvelope<'a> {
    secret: ConcealPayload<'a>,
}

#[derive(Serialize)]
struct ConcealPayload<'a> {
    kind: &'static str,
    secret: &'a str,
    ttl: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    share_domain: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    passphrase: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    recipient: Option<&'a str>,
}

/// Build the JSON request body. Returned wrapped in [`Zeroizing`] so the
/// plaintext-bearing string wipes on drop.
///
/// Known limitation: `serde_json`'s internal buffer makes a transient copy that
/// is not itself zeroized. Full zeroization through the HTTP stack is tracked
/// for a later hardening pass; the boundary law (no plaintext into the UI) is
/// unaffected.
#[must_use]
pub fn build_body(secret: &str, opts: &ConcealOpts) -> Zeroizing<String> {
    let envelope = ConcealEnvelope {
        secret: ConcealPayload {
            kind: "conceal",
            secret,
            ttl: opts.ttl_secs,
            share_domain: opts.share_domain.as_deref(),
            passphrase: opts.passphrase.as_ref().map(|p| p.as_str()),
            recipient: opts.recipient.as_deref(),
        },
    };
    Zeroizing::new(serde_json::to_string(&envelope).unwrap_or_default())
}

/// Build the `Authorization: Basic <base64(extid:token)>` header. Returned in
/// [`Zeroizing`] so the credential-bearing string wipes on drop.
#[must_use]
pub fn auth_header(creds: &Credentials) -> Zeroizing<String> {
    let raw = Zeroizing::new(format!("{}:{}", creds.extid, creds.token.as_str()));
    let encoded = base64::engine::general_purpose::STANDARD.encode(raw.as_bytes());
    Zeroizing::new(format!("Basic {encoded}"))
}

/// Parse a conceal response into a [`ShareLink`], tolerant of the v2/v3 `record`
/// envelope and of whether explicit URLs or bare keys are returned.
pub fn parse_response(base_url: &str, body: &str) -> Result<ShareLink, ConcealError> {
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|e| ConcealError::Parse(e.to_string()))?;

    // The keys may sit at the top level or under a "record" envelope (v2/v3).
    let record = value
        .get("record")
        .into_iter()
        .chain(std::iter::once(&value))
        .find(|obj| obj.get("secret_key").is_some() || obj.get("metadata_key").is_some())
        .ok_or_else(|| {
            ConcealError::Parse("response had no secret_key or metadata_key".to_string())
        })?;

    let secret_key = str_field(record, "secret_key");
    let metadata_key = str_field(record, "metadata_key");

    let share_url = str_field(record, "share_link")
        .or_else(|| str_field(record, "secret_url"))
        .or_else(|| secret_key.as_ref().map(|k| join_url(base_url, "secret", k)))
        .ok_or_else(|| ConcealError::Parse("no share link and no secret_key".to_string()))?;

    let metadata_url = str_field(record, "metadata_url")
        .or_else(|| {
            metadata_key
                .as_ref()
                .map(|k| join_url(base_url, "private", k))
        })
        .unwrap_or_default();

    let ttl_secs = record.get("ttl").and_then(serde_json::Value::as_u64);

    Ok(ShareLink {
        share_url,
        secret_key: secret_key.unwrap_or_default(),
        metadata_url,
        metadata_key: metadata_key.unwrap_or_default(),
        ttl_secs,
    })
}

fn str_field(obj: &serde_json::Value, key: &str) -> Option<String> {
    obj.get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
}

fn join_url(base: &str, segment: &str, key: &str) -> String {
    format!("{}/{segment}/{key}", base.trim_end_matches('/'))
}

#[cfg(feature = "http")]
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        s.chars().take(max).collect::<String>() + "…"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_matches_v3_shape_with_only_required_fields() {
        let opts = ConcealOpts::new(3600);
        let body = build_body("hunter2", &opts);
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["secret"]["kind"], "conceal");
        assert_eq!(v["secret"]["secret"], "hunter2");
        assert_eq!(v["secret"]["ttl"], 3600);
        // Optional fields are omitted, not null.
        assert!(v["secret"].get("share_domain").is_none());
        assert!(v["secret"].get("passphrase").is_none());
        assert!(v["secret"].get("recipient").is_none());
    }

    #[test]
    fn body_includes_optional_fields_when_present() {
        let opts = ConcealOpts {
            ttl_secs: 86_400,
            share_domain: Some("https://secrets.example.com".to_string()),
            passphrase: Some(Zeroizing::new("open-sesame".to_string())),
            recipient: Some("ops@example.com".to_string()),
        };
        let body = build_body("payload", &opts);
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["secret"]["share_domain"], "https://secrets.example.com");
        assert_eq!(v["secret"]["passphrase"], "open-sesame");
        assert_eq!(v["secret"]["recipient"], "ops@example.com");
        assert_eq!(v["secret"]["ttl"], 86_400);
    }

    #[test]
    fn body_escapes_special_characters() {
        let opts = ConcealOpts::new(60);
        let secret = "line1\nline2\t\"quoted\" \\backslash\\";
        let body = build_body(secret, &opts);
        // Round-trips back to exactly the same bytes -> escaping is correct.
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["secret"]["secret"], secret);
    }

    #[test]
    fn auth_header_is_basic_base64_of_extid_colon_token() {
        let creds = Credentials::new("cust_ext_123", "tok_abc");
        let header = auth_header(&creds);
        // base64("cust_ext_123:tok_abc")
        let expected = base64::engine::general_purpose::STANDARD.encode(b"cust_ext_123:tok_abc");
        assert_eq!(&*header, &format!("Basic {expected}"));
    }

    #[test]
    fn parse_flat_response_builds_urls_from_keys() {
        let body = r#"{
            "secret_key": "skey123",
            "metadata_key": "mkey456",
            "ttl": 604800
        }"#;
        let link = parse_response("https://onetimesecret.com/", body).unwrap();
        assert_eq!(link.share_url, "https://onetimesecret.com/secret/skey123");
        assert_eq!(
            link.metadata_url,
            "https://onetimesecret.com/private/mkey456"
        );
        assert_eq!(link.secret_key, "skey123");
        assert_eq!(link.metadata_key, "mkey456");
        assert_eq!(link.ttl_secs, Some(604_800));
    }

    #[test]
    fn parse_nested_record_envelope() {
        let body = r#"{
            "success": true,
            "record": { "secret_key": "abc", "metadata_key": "def" }
        }"#;
        let link = parse_response("https://example.com", body).unwrap();
        assert_eq!(link.share_url, "https://example.com/secret/abc");
        assert_eq!(link.metadata_url, "https://example.com/private/def");
    }

    #[test]
    fn parse_prefers_explicit_share_link() {
        let body = r#"{
            "secret_key": "abc",
            "metadata_key": "def",
            "share_link": "https://custom.example/s/abc"
        }"#;
        let link = parse_response("https://example.com", body).unwrap();
        assert_eq!(link.share_url, "https://custom.example/s/abc");
    }

    #[test]
    fn parse_rejects_a_response_with_no_keys() {
        let err = parse_response("https://example.com", r#"{"error":"nope"}"#).unwrap_err();
        assert!(matches!(err, ConcealError::Parse(_)));
    }

    #[cfg(not(feature = "http"))]
    #[test]
    fn conceal_without_http_feature_reports_unavailable() {
        let client = ConcealClient::new("https://example.com");
        let err = client
            .conceal("s", &ConcealOpts::new(60), &Credentials::new("x", "y"))
            .unwrap_err();
        assert!(matches!(err, ConcealError::HttpUnavailable));
    }
}
