//! Wire-size padding (relay-protocol.md §8): the exact length of a
//! sealed blob is a weak fingerprint of its content, so the relay gets
//! buckets — the ledger's `SizeClass` discipline applied to the wire.
//!
//! Padding happens on the plaintext side of the seal: a 4-byte length
//! prefix, the content, then zeros to the bucket boundary. The AEAD's
//! fixed overhead rides on top, which shifts every bucket by the same
//! constant and fingerprints nothing.

/// The smallest bucket, bytes.
pub const FLOOR: usize = 256;
/// Above this, buckets stop doubling and grow linearly — a 65 KiB and a
/// 100 KiB payload should not be one doubling apart.
pub const CEILING: usize = 64 * 1024;

const PREFIX: usize = 4;

/// The bucket a payload of `len` content bytes lands in: the next
/// power of two from [`FLOOR`] to [`CEILING`], then multiples of
/// [`CEILING`].
#[must_use]
pub fn bucket(len: usize) -> usize {
    let needed = len + PREFIX;
    if needed <= FLOOR {
        return FLOOR;
    }
    if needed <= CEILING {
        return needed.next_power_of_two();
    }
    needed.div_ceil(CEILING) * CEILING
}

/// Frame and pad `content` to its bucket.
#[must_use]
pub fn pad(content: &[u8]) -> Vec<u8> {
    let size = bucket(content.len());
    let mut out = Vec::with_capacity(size);
    #[allow(clippy::cast_possible_truncation)]
    out.extend_from_slice(&(content.len() as u32).to_be_bytes());
    out.extend_from_slice(content);
    out.resize(size, 0);
    out
}

/// Recover the content from a padded frame. `None` when the prefix
/// claims more than the frame holds — a corrupt frame is refused, not
/// truncated.
#[must_use]
pub fn unpad(frame: &[u8]) -> Option<&[u8]> {
    let prefix: [u8; PREFIX] = frame.get(..PREFIX)?.try_into().ok()?;
    let len = u32::from_be_bytes(prefix) as usize;
    frame.get(PREFIX..PREFIX + len)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_are_powers_of_two_with_a_floor_and_a_linear_tail() {
        assert_eq!(bucket(0), 256);
        assert_eq!(bucket(200), 256);
        assert_eq!(bucket(253), 512); // 253 + 4-byte prefix crosses 256
        assert_eq!(bucket(1000), 1024);
        assert_eq!(bucket(40_000), 65_536);
        assert_eq!(bucket(70_000), 2 * 65_536);
    }

    #[test]
    fn round_trips_and_pads_to_the_bucket() {
        let content = vec![7u8; 1000];
        let framed = pad(&content);
        assert_eq!(framed.len(), 1024);
        assert_eq!(unpad(&framed).unwrap(), content.as_slice());
    }

    #[test]
    fn two_different_lengths_share_a_bucket() {
        assert_eq!(pad(&[1u8; 300]).len(), pad(&[1u8; 500]).len());
    }

    #[test]
    fn a_lying_prefix_is_refused() {
        let mut framed = pad(b"honest");
        framed[0..4].copy_from_slice(&10_000u32.to_be_bytes());
        assert!(unpad(&framed).is_none());
    }
}
