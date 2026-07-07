//! Cryptographic primitives.
//!
//! PASETO-based auth is deliberately deferred — Basic auth ships first, and the
//! auth layer is shaped so swapping Basic for PASETO is a contained change
//! (docs/00 §12, docs/01 §12). For now this module carries only the small
//! primitives the skeleton needs; audited symmetric crypto lands with the
//! persistence and PASETO milestones.

/// Constant-time byte equality.
///
/// Compares `a` and `b` without an early return on the first differing byte, so
/// the time taken does not leak *where* they differ. Length is compared first
/// (a mismatch there is not secret), then every byte is folded into an
/// accumulator. Use this for receipts, tokens, and any secret comparison.
#[must_use]
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_slices_compare_equal() {
        assert!(constant_time_eq(b"same-token", b"same-token"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn differing_slices_compare_unequal() {
        assert!(!constant_time_eq(b"token-a", b"token-b"));
        assert!(!constant_time_eq(b"short", b"longer"));
        assert!(!constant_time_eq(b"", b"x"));
    }
}
