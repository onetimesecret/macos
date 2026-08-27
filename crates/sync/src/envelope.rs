//! The plaintext inside a sealed delta blob (relay-protocol.md §4-5).
//! Everything the channel replicates travels in this one shape —
//! document ops, the expiry policy and hold register, terminal
//! markers, and the ceremony ballots — so control and content share
//! the stream and the relay cannot distinguish them.
//!
//! This module encodes and decodes strictly on the client side of the
//! seal: the bytes it produces exist only as input to
//! `GopKeyChain::seal` and output of `open`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The ceremony messages of §5, riding the same stream as content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ControlPayload {
    /// A ceremony proposal: entropy minted by the proposer, sealed per
    /// surviving device to that device's static key package (§6) —
    /// never under the current GOP key, which a just-revoked device
    /// still holds.
    Propose {
        /// The ballot this proposal opens.
        ballot_id: String,
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
    /// The page's expiry policy: the policy, never the deadline
    /// (ADR-0021 §6, `companion_core::ExpiryPolicy`).
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
    /// A signed terminal marker (ADR-0021 §6): the page is dead
    /// everywhere, and a ceremony proposal follows immediately.
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
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        // Serialization of these shapes cannot fail; the expect is a
        // programming-error tripwire, not a runtime path.
        serde_json::to_vec(self).expect("envelope shapes always serialize")
    }

    /// Decode an opened delta. `None` refuses anything that is not an
    /// envelope — a peer speaking a shape this build does not know is
    /// skipped, never guessed at.
    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }
}

/// Bytes that travel as base64 inside envelope JSON, so ops and
/// markers do not balloon into number arrays before padding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ByteBlob(pub Vec<u8>);

impl Serialize for ByteBlob {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&crate::b64::encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for ByteBlob {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let encoded = String::deserialize(deserializer)?;
        crate::b64::decode(&encoded)
            .map(ByteBlob)
            .ok_or_else(|| serde::de::Error::custom("invalid base64"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_variant_round_trips() {
        let mut entropy = BTreeMap::new();
        entropy.insert("fp-2".to_owned(), ByteBlob(vec![9, 9, 9]));
        let envelopes = [
            DeltaEnvelope::Ops {
                page: "page-1".into(),
                ops: ByteBlob(vec![1, 2, 3]),
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
            DeltaEnvelope::Terminal {
                page: "page-1".into(),
                marker: ByteBlob(vec![4, 5]),
            },
            DeltaEnvelope::Control {
                payload: ControlPayload::Propose {
                    ballot_id: "ballot-1".into(),
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
        for envelope in envelopes {
            assert_eq!(DeltaEnvelope::decode(&envelope.encode()), Some(envelope));
        }
    }

    #[test]
    fn bytes_travel_as_base64_not_number_arrays() {
        let encoded = DeltaEnvelope::Ops {
            page: "p".into(),
            ops: ByteBlob(vec![255; 32]),
        }
        .encode();
        let text = String::from_utf8(encoded).unwrap();
        assert!(!text.contains("255"));
    }

    #[test]
    fn an_unknown_shape_is_refused() {
        assert!(DeltaEnvelope::decode(br#"{"kind":"future_thing"}"#).is_none());
        assert!(DeltaEnvelope::decode(b"not json").is_none());
    }
}
