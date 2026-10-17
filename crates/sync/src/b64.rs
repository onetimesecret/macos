//! Base64, both alphabets this crate needs and nothing more: standard
//! (RFC 4648 §4) for sealed blobs travelling in relay JSON, and
//! URL-safe without padding (§5) for PKCE material, whose grammar
//! RFC 7636 fixes.

use zeroize::Zeroizing;

const STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_SAFE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn encode_with(alphabet: &[u8; 64], input: &[u8], pad: bool) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    encode_into(alphabet, input, pad, &mut out);
    out
}

fn encode_into(alphabet: &[u8; 64], input: &[u8], pad: bool, out: &mut String) {
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(alphabet[(n >> 18) as usize & 63] as char);
        out.push(alphabet[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(alphabet[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(alphabet[n as usize & 63] as char);
        }
    }
    if pad {
        while !out.len().is_multiple_of(4) {
            out.push('=');
        }
    }
}

pub(crate) fn encode_zeroizing(input: &[u8]) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::with_capacity(input.len().div_ceil(3) * 4));
    encode_into(STANDARD, input, true, &mut out);
    out
}

/// Standard-alphabet, padded — the form sealed blobs travel in.
pub fn encode(input: &[u8]) -> String {
    encode_with(STANDARD, input, true)
}

/// URL-safe, unpadded — the PKCE verifier/challenge form (RFC 7636 §4).
pub fn encode_url_nopad(input: &[u8]) -> String {
    encode_with(URL_SAFE, input, false)
}

/// Decode the standard alphabet, padding optional. `None` on any byte
/// outside the alphabet, on a length no encoding produces, or on more
/// padding than an encoding carries — a relay handing back garbage is
/// refused, not guessed at.
pub fn decode(input: &str) -> Option<Vec<u8>> {
    let len = decoded_len(input)?;
    let mut out = vec![0; len];
    decode_into(input, &mut out)?;
    Some(out)
}

pub(crate) fn decode_zeroizing(input: &str) -> Option<Zeroizing<Vec<u8>>> {
    let len = decoded_len(input)?;
    let mut out = Zeroizing::new(vec![0; len]);
    decode_into(input, &mut out)?;
    Some(out)
}

fn decoded_len(input: &str) -> Option<usize> {
    let trimmed = input.trim_end_matches('=');
    let pad = input.len() - trimmed.len();
    let tail = trimmed.len() % 4;
    // An encoder emits four characters per three bytes, two or three
    // for a final one or two, and pads only that final group, to
    // exactly four: a lone trailing character is no byte at all, and
    // padding after a whole group, short of four or past it, is none
    // an encoder wrote.
    if tail == 1 || (pad > 0 && (tail == 0 || tail + pad != 4)) {
        return None;
    }
    Some(trimmed.len() / 4 * 3 + tail * 3 / 4)
}

fn decode_into(input: &str, out: &mut [u8]) -> Option<()> {
    let trimmed = input.trim_end_matches('=');
    let mut at = 0;
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for byte in trimmed.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out[at] = (acc >> bits) as u8;
            at += 1;
        }
    }
    // A valid encoding never leaves non-zero bits behind.
    if acc & ((1 << bits) - 1) != 0 {
        return None;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_the_rfc4648_vectors() {
        for (plain, encoded) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"fooba", "Zm9vYmE="),
            (b"foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(encode(plain), encoded);
            assert_eq!(decode(encoded).unwrap(), plain);
            let secret = encode_zeroizing(plain);
            assert_eq!(secret.as_str(), encoded);
            assert_eq!(secret.len(), secret.capacity());
            let decoded = decode_zeroizing(encoded).unwrap();
            assert_eq!(decoded.as_slice(), plain);
            assert_eq!(decoded.len(), decoded.capacity());
        }
    }

    #[test]
    fn zeroizing_buffers_match_public_encoding_across_chunk_boundaries() {
        for len in 0..=257 {
            let bytes: Vec<u8> = (0u8..=255).cycle().take(len).collect();
            let encoded = encode_zeroizing(&bytes);
            assert_eq!(encoded.as_str(), encode(&bytes));
            assert_eq!(encoded.len(), encoded.capacity());
            for text in [encoded.as_str(), encoded.trim_end_matches('=')] {
                let decoded = decode_zeroizing(text).unwrap();
                assert_eq!(decoded.as_slice(), bytes);
                assert_eq!(decoded.len(), decoded.capacity());
            }
        }
        for invalid in ["c2VjcmV0!", "Zg=A", "Zh", "A", "Zg=", "Zm9v===="] {
            assert!(decode_zeroizing(invalid).is_none());
        }
    }

    #[test]
    fn url_safe_matches_the_rfc7636_appendix_b_challenge() {
        // RFC 7636 appendix B: the S256 challenge of the example
        // verifier, base64url of the given SHA-256 digest.
        let digest: &[u8] = &[
            19, 211, 30, 150, 26, 26, 216, 236, 47, 22, 177, 12, 76, 152, 46, 8, 118, 168, 120,
            173, 109, 241, 68, 86, 110, 225, 137, 74, 203, 112, 249, 195,
        ];
        assert_eq!(
            encode_url_nopad(digest),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn refuses_bytes_outside_the_alphabet() {
        assert!(decode("Zm9v!").is_none());
        assert!(decode("Zg=A").is_none());
    }

    #[test]
    fn refuses_lengths_and_padding_no_encoder_produces() {
        // A dangling character carries six bits, which is not a byte.
        assert!(decode("A").is_none());
        assert!(decode("Zm9vA").is_none());
        assert!(decode("AAAAA").is_none());
        // Padding past the two characters an encoder can need.
        assert!(decode("Zg=====").is_none());
        assert!(decode("Zm9v===").is_none());
        // Padding with no group to finish, or more than finishing it
        // takes.
        assert!(decode("=").is_none());
        assert!(decode("==").is_none());
        assert!(decode("====").is_none());
        assert!(decode("Zm9v====").is_none());
        assert!(decode("Zm9v=").is_none());
        assert!(decode("Zm8==").is_none());
        assert!(decode("Zg=").is_none());
        // Non-zero leftover bits were already refused; still are.
        assert!(decode("Zh").is_none());
        assert!(decode("Zm9vB").is_none());
        // Optional padding stays optional.
        assert_eq!(decode("Zg").unwrap(), b"f");
        assert_eq!(decode("Zm8").unwrap(), b"fo");
        assert_eq!(decode("Zg==").unwrap(), b"f");
        assert_eq!(decode("Zm8=").unwrap(), b"fo");
    }
}
