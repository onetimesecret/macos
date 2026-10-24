//! The plaintext inside a sealed delta blob (relay-protocol.md §4-5).
//! Everything the channel replicates travels in this one shape:
//! document ops, sealed objects' metadata, the expiry policy and hold
//! register, terminal markers, and the ceremony ballots. Control and
//! content share the stream, so the relay cannot distinguish them.
//!
//! This module encodes and decodes strictly on the client side of the
//! seal: the bytes it produces exist only as input to
//! `GopKeyChain::seal` and output of `open`.

use std::{collections::BTreeMap, fmt};

use serde::{Deserialize, Serialize, de::Visitor};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

/// The ceremony messages of §5, riding the same stream as content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ControlPayload {
    /// A ceremony proposal: entropy minted by the proposer, sealed per
    /// named device to that device's one-shot key package, never under
    /// the current GOP key, which a just-revoked device still holds
    /// (client protocol §5, §7.3).
    Propose {
        /// The ballot this proposal opens.
        ballot_id: String,
        /// The page to compact, named so a follower joins the right
        /// ballot; only this page compacts (client protocol §7.6).
        page: String,
        /// Per-device sealed entropy, keyed by identity fingerprint.
        /// A `BTreeMap` so the encoding is deterministic.
        entropy_sealed: BTreeMap<String, ByteBlob>,
    },
    /// A device's acceptance of a ballot.
    Accept {
        /// The ballot accepted.
        ballot_id: String,
        /// The accepting device's identity fingerprint.
        device_fingerprint: String,
    },
}

/// One delta's plaintext, before sealing and padding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DeltaEnvelope {
    /// Document updates for one page
    /// (`SheetStore::export_document_updates`).
    Ops {
        /// The page the ops belong to.
        page: String,
        /// The exported update bytes.
        ops: ByteBlob,
    },
    /// What a peer learns of a page's sealed objects beside its ops: each
    /// one's identity, kind, size class and versioned name, never its value
    /// (ADR-0058 point 5).
    Metadata {
        /// The page the objects stand on.
        page: String,
        /// At most [`METADATA_ENTRY_CAP`], one per object.
        entries: Vec<MetadataEntry>,
    },
    /// The page's expiry policy: the policy, never the deadline
    /// (relay decision background §6, `companion_core::ExpiryPolicy`).
    Expiry {
        /// The page the policy governs.
        page: String,
        /// Unix epoch ms the countdown was anchored.
        anchor_wall_ms: u64,
        /// Life remaining at the anchor, ms.
        ttl_ms: u64,
    },
    /// The hold register's replicated state
    /// (`companion_core::HoldRegister`): `None` for released, the pair
    /// for a standing hold.
    Hold {
        /// The page the register belongs to.
        page: String,
        /// `Some((frozen_ms, until_wall_ms, topped_up))` while a hold
        /// stands.
        hold: Option<(u64, u64, bool)>,
    },
    /// A signed terminal marker (relay decision background §6): the page
    /// is dead everywhere, and a ceremony proposal follows immediately.
    Terminal {
        /// The dead page.
        page: String,
        /// The signed marker bytes.
        marker: ByteBlob,
    },
    /// A ceremony message (its own `op` tag inside the shared
    /// `kind`).
    Control {
        /// The ceremony message itself.
        #[serde(flatten)]
        payload: ControlPayload,
    },
}

impl DeltaEnvelope {
    /// Encode for sealing.
    ///
    /// # Errors
    ///
    /// Returns [`crate::secret_json::to_zeroizing_vec`]'s errors.
    pub fn encode(&self) -> serde_json::Result<Zeroizing<Vec<u8>>> {
        crate::secret_json::to_zeroizing_vec(self)
    }

    /// Decode an opened delta. `None` refuses anything that is not an
    /// envelope — a peer speaking a shape this build does not know is
    /// skipped, never guessed at.
    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }
}

/// The most entries one [`DeltaEnvelope::Metadata`] names: a sender
/// chunks at it, and a receiver ignores an envelope past it (ADR-0058
/// point 5).
pub const METADATA_ENTRY_CAP: usize = 128;

/// One object in a [`DeltaEnvelope::Metadata`], as it travels; the
/// receiver judges each field on its own.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetadataEntry {
    /// The object's identity, 32 lowercase hex characters, as a page id is.
    pub object: String,
    /// `text` or `image`, when known.
    pub kind: Option<String>,
    /// The ledger's size class word, `tiny` to `huge`, when known.
    pub size: Option<String>,
    /// The versioned name; `None` for a name never set.
    pub name: Option<NameField>,
}

/// A name and its version: the greater `(counter, writer)` wins.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NameField {
    /// One more than the highest counter the writer knew.
    pub counter: u64,
    /// The writing device's fingerprint, 64 lowercase hex characters.
    pub writer: String,
    /// The name's UTF-8 bytes; `None` for a clear.
    pub value: Option<ByteBlob>,
}

/// Bytes that travel as base64 inside envelope JSON, so ops and
/// markers do not balloon into number arrays before padding.
#[derive(Clone, PartialEq, Eq)]
pub struct ByteBlob(Zeroizing<Vec<u8>>);

impl ByteBlob {
    /// Borrow the bytes without exposing the backing vector for growth.
    #[must_use]
    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }
}

impl From<Zeroizing<Vec<u8>>> for ByteBlob {
    fn from(bytes: Zeroizing<Vec<u8>>) -> Self {
        Self(bytes)
    }
}

impl From<Vec<u8>> for ByteBlob {
    fn from(bytes: Vec<u8>) -> Self {
        Self(Zeroizing::new(bytes))
    }
}

impl From<&[u8]> for ByteBlob {
    fn from(bytes: &[u8]) -> Self {
        Self::from(bytes.to_vec())
    }
}

impl AsRef<[u8]> for ByteBlob {
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl Zeroize for ByteBlob {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl ZeroizeOnDrop for ByteBlob {}

impl fmt::Debug for ByteBlob {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ByteBlob([REDACTED])")
    }
}

impl Serialize for ByteBlob {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&crate::b64::encode_zeroizing(self.as_slice()))
    }
}

impl<'de> Deserialize<'de> for ByteBlob {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct BytesVisitor;

        impl Visitor<'_> for BytesVisitor {
            type Value = ByteBlob;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a base64 string")
            }

            fn visit_str<E: serde::de::Error>(self, encoded: &str) -> Result<ByteBlob, E> {
                crate::b64::decode_zeroizing(encoded)
                    .map(ByteBlob)
                    .ok_or_else(|| E::custom("invalid base64"))
            }

            fn visit_string<E: serde::de::Error>(self, encoded: String) -> Result<ByteBlob, E> {
                let encoded = Zeroizing::new(encoded);
                self.visit_str(&encoded)
            }
        }

        deserializer.deserialize_str(BytesVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OBJECT: &str = "0123456789abcdef0123456789abcdef";
    const WRITER: &str = "abababababababababababababababababababababababababababababababab";

    /// The envelope set a build from before `Metadata` decodes.
    #[derive(Debug, Deserialize)]
    #[serde(tag = "kind", rename_all = "snake_case")]
    #[expect(dead_code, reason = "only whether a shape decodes is read")]
    enum Earlier {
        Ops {
            page: String,
            ops: ByteBlob,
        },
        Expiry {
            page: String,
            anchor_wall_ms: u64,
            ttl_ms: u64,
        },
        Hold {
            page: String,
            hold: Option<(u64, u64, bool)>,
        },
        Terminal {
            page: String,
            marker: ByteBlob,
        },
        Control {
            #[serde(flatten)]
            payload: ControlPayload,
        },
    }

    #[test]
    fn every_variant_round_trips() {
        let mut entropy = BTreeMap::new();
        entropy.insert("fp-2".to_owned(), ByteBlob::from(vec![9, 9, 9]));
        let envelopes = [
            DeltaEnvelope::Ops {
                page: "page-1".into(),
                ops: ByteBlob::from(vec![1, 2, 3]),
            },
            DeltaEnvelope::Metadata {
                page: "page-1".into(),
                entries: vec![
                    MetadataEntry {
                        object: OBJECT.into(),
                        kind: Some("text".into()),
                        size: Some("tiny".into()),
                        name: Some(NameField {
                            counter: 2,
                            writer: WRITER.into(),
                            value: Some(ByteBlob::from(b"DEPLOY_KEY".as_slice())),
                        }),
                    },
                    MetadataEntry {
                        object: OBJECT.into(),
                        kind: None,
                        size: None,
                        name: Some(NameField {
                            counter: 3,
                            writer: WRITER.into(),
                            value: None,
                        }),
                    },
                ],
            },
            DeltaEnvelope::Metadata {
                page: "page-1".into(),
                entries: vec![MetadataEntry {
                    object: OBJECT.into(),
                    kind: Some("image".into()),
                    size: Some("huge".into()),
                    name: None,
                }],
            },
            DeltaEnvelope::Expiry {
                page: "page-1".into(),
                anchor_wall_ms: 1_000,
                ttl_ms: 60_000,
            },
            DeltaEnvelope::Hold {
                page: "page-1".into(),
                hold: Some((30_000, 90_000, false)),
            },
            DeltaEnvelope::Hold {
                page: "page-1".into(),
                hold: None,
            },
            DeltaEnvelope::Terminal {
                page: "page-1".into(),
                marker: ByteBlob::from(vec![4, 5]),
            },
            DeltaEnvelope::Control {
                payload: ControlPayload::Propose {
                    ballot_id: "ballot-1".into(),
                    page: "page-1".into(),
                    entropy_sealed: entropy,
                },
            },
            DeltaEnvelope::Control {
                payload: ControlPayload::Accept {
                    ballot_id: "ballot-1".into(),
                    device_fingerprint: "fp-2".into(),
                },
            },
        ];
        let wire = [
            r#"{"kind":"ops","page":"page-1","ops":"AQID"}"#,
            r#"{"kind":"metadata","page":"page-1","entries":[{"object":"0123456789abcdef0123456789abcdef","kind":"text","size":"tiny","name":{"counter":2,"writer":"abababababababababababababababababababababababababababababababab","value":"REVQTE9ZX0tFWQ=="}},{"object":"0123456789abcdef0123456789abcdef","kind":null,"size":null,"name":{"counter":3,"writer":"abababababababababababababababababababababababababababababababab","value":null}}]}"#,
            r#"{"kind":"metadata","page":"page-1","entries":[{"object":"0123456789abcdef0123456789abcdef","kind":"image","size":"huge","name":null}]}"#,
            r#"{"kind":"expiry","page":"page-1","anchor_wall_ms":1000,"ttl_ms":60000}"#,
            r#"{"kind":"hold","page":"page-1","hold":[30000,90000,false]}"#,
            r#"{"kind":"hold","page":"page-1","hold":null}"#,
            r#"{"kind":"terminal","page":"page-1","marker":"BAU="}"#,
            r#"{"kind":"control","op":"propose","ballot_id":"ballot-1","page":"page-1","entropy_sealed":{"fp-2":"CQkJ"}}"#,
            r#"{"kind":"control","op":"accept","ballot_id":"ballot-1","device_fingerprint":"fp-2"}"#,
        ];
        for (envelope, wire) in envelopes.into_iter().zip(wire) {
            let encoded = envelope.encode().unwrap();
            assert_eq!(encoded.as_slice(), wire.as_bytes());
            assert_eq!(encoded.len(), encoded.capacity());
            assert_eq!(DeltaEnvelope::decode(&encoded), Some(envelope));
        }
    }

    #[test]
    fn bytes_travel_as_base64_not_number_arrays() {
        let encoded = DeltaEnvelope::Ops {
            page: "p".into(),
            ops: ByteBlob::from(vec![255; 32]),
        }
        .encode()
        .unwrap();
        let text = std::str::from_utf8(&encoded).unwrap();
        assert!(!text.contains("255"));
    }

    #[test]
    fn escaped_fields_and_base64_still_decode() {
        let wire = br#"{"kind":"ops","page":"p\"\\\n\u00e9","ops":"\/\u0077=="}"#;
        let envelope = DeltaEnvelope::decode(wire).unwrap();
        assert_eq!(
            envelope,
            DeltaEnvelope::Ops {
                page: "p\"\\\né".into(),
                ops: ByteBlob::from(vec![255]),
            }
        );
        assert_eq!(
            envelope.encode().unwrap().as_slice(),
            "{\"kind\":\"ops\",\"page\":\"p\\\"\\\\\\né\",\"ops\":\"/w==\"}".as_bytes()
        );
        assert_eq!(
            DeltaEnvelope::decode(br#"{"ops":"\/w==","page":"p","kind":"ops"}"#),
            Some(DeltaEnvelope::Ops {
                page: "p".into(),
                ops: ByteBlob::from(vec![255]),
            })
        );
    }

    #[test]
    fn blob_clones_are_independent_zeroizing_owners_with_redacted_debug() {
        fn zeroizing_owner<T: ZeroizeOnDrop>() {}
        zeroizing_owner::<ByteBlob>();
        let bytes = Zeroizing::new(b"secret bytes".to_vec());
        let allocation = bytes.as_ptr();
        let mut original = ByteBlob::from(bytes);
        assert_eq!(original.as_slice().as_ptr(), allocation);
        let mut cloned = original.clone();
        assert_eq!(cloned.0.len(), cloned.0.capacity());
        assert_ne!(original.as_slice().as_ptr(), cloned.as_slice().as_ptr());
        assert_eq!(format!("{original:?}"), "ByteBlob([REDACTED])");
        original.zeroize();
        assert!(original.as_slice().is_empty());
        assert_eq!(cloned.as_slice(), b"secret bytes");
        cloned.clone_from(&ByteBlob::from(b"replacement".as_slice()));
        assert_eq!(cloned.as_slice(), b"replacement");
        let envelope = DeltaEnvelope::Ops {
            page: "p".into(),
            ops: cloned,
        };
        let debug = format!("{envelope:?}");
        assert!(!debug.contains("replacement"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn invalid_base64_and_truncated_envelopes_are_refused() {
        for wire in [
            r#"{"kind":"ops","page":"p","ops":"c2VjcmV0!"}"#,
            r#"{"kind":"ops","page":"p","ops":"/x=="}"#,
            r#"{"kind":"ops","page":"p","ops":"c2VjcmV0""#,
            r#"{"kind":"metadata","page":"p","entries":[{"object":"0f","name":{"counter":1,"writer":"ab","value":"c2VjcmV0!"}}]}"#,
        ] {
            assert!(DeltaEnvelope::decode(wire.as_bytes()).is_none());
        }
    }

    #[test]
    fn an_unknown_shape_is_refused() {
        assert!(DeltaEnvelope::decode(br#"{"kind":"future_thing"}"#).is_none());
        assert!(DeltaEnvelope::decode(b"not json").is_none());
    }

    #[test]
    fn a_build_from_before_metadata_skips_it_and_still_reads_ops() {
        let metadata = DeltaEnvelope::Metadata {
            page: "p".into(),
            entries: vec![MetadataEntry {
                object: OBJECT.into(),
                kind: Some("text".into()),
                size: None,
                name: None,
            }],
        }
        .encode()
        .unwrap();
        assert!(serde_json::from_slice::<Earlier>(&metadata).is_err());
        let ops = DeltaEnvelope::Ops {
            page: "p".into(),
            ops: ByteBlob::from(vec![1]),
        }
        .encode()
        .unwrap();
        assert!(serde_json::from_slice::<Earlier>(&ops).is_ok());
    }

    #[test]
    fn a_metadata_envelope_decodes_escapes_and_absent_fields_and_redacts_its_names() {
        let wire = br#"{"entries":[{"name":{"value":"U0VDUkVUX05BTUU=","writer":"ab","counter":1},"object":"0f"}],"page":"p","kind":"metadata"}"#;
        let envelope = DeltaEnvelope::decode(wire).unwrap();
        assert_eq!(
            envelope,
            DeltaEnvelope::Metadata {
                page: "p".into(),
                entries: vec![MetadataEntry {
                    object: "0f".into(),
                    kind: None,
                    size: None,
                    name: Some(NameField {
                        counter: 1,
                        writer: "ab".into(),
                        value: Some(ByteBlob::from(b"SECRET_NAME".as_slice())),
                    }),
                }],
            }
        );
        let debug = format!("{envelope:?}");
        assert!(!debug.contains("SECRET_NAME"));
        assert!(!debug.contains("U0VDUkVUX05BTUU"));
        assert!(debug.contains("[REDACTED]"));
        let encoded = envelope.encode().unwrap();
        assert_eq!(encoded.len(), encoded.capacity());
        assert_eq!(
            encoded.as_slice(),
            br#"{"kind":"metadata","page":"p","entries":[{"object":"0f","kind":null,"size":null,"name":{"counter":1,"writer":"ab","value":"U0VDUkVUX05BTUU="}}]}"#
        );
    }
}
