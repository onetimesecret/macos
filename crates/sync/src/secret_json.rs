//! Two-pass JSON encoding into a fixed-size zeroizing allocation.

use std::io::{self, Write};

use serde::Serialize;
use zeroize::Zeroizing;

/// Serialize twice: first count, then write into an exactly sized buffer.
///
/// Capture exports and other changing values before calling this function.
/// This controls the output allocation, not allocations inside `Serialize`.
///
/// # Errors
///
/// Returns serialization errors, size overflow, or a different output length
/// on the second pass. A second pass cannot grow the destination.
pub fn to_zeroizing_vec<T: Serialize + ?Sized>(
    value: &T,
) -> serde_json::Result<Zeroizing<Vec<u8>>> {
    let mut count = Count(0);
    serde_json::to_writer(&mut count, value)?;
    let mut output = Zeroizing::new(vec![0; count.0]);
    let mut remaining = output.as_mut_slice();
    serde_json::to_writer(&mut remaining, value)?;
    if !remaining.is_empty() {
        return Err(serde_json::Error::io(io::Error::other(
            "JSON size changed between passes",
        )));
    }
    Ok(output)
}

struct Count(usize);

impl Write for Count {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 = self
            .0
            .checked_add(bytes.len())
            .ok_or_else(|| io::Error::other("JSON size overflow"))?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    struct Changing<'a> {
        first: &'a str,
        second: &'a str,
        calls: Cell<usize>,
        fail_on: Option<usize>,
    }

    impl Serialize for Changing<'_> {
        fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            let call = self.calls.get();
            self.calls.set(call + 1);
            if self.fail_on == Some(call) {
                return Err(serde::ser::Error::custom("refused"));
            }
            serializer.serialize_str(if call == 0 { self.first } else { self.second })
        }
    }

    #[test]
    fn escaped_json_matches_serde_at_exact_capacity() {
        for text in ["", "\"\\\n\r\t\0\u{001f}", "café 🦀 / <tag>"] {
            let output = to_zeroizing_vec(&[text, text]).unwrap();
            assert_eq!(
                output.as_slice(),
                serde_json::to_vec(&[text, text]).unwrap()
            );
            assert_eq!(output.len(), output.capacity());
        }
    }

    #[test]
    fn both_directions_of_size_drift_are_errors() {
        for (first, second) in [("short", "much longer"), ("much longer", "short")] {
            let value = Changing {
                first,
                second,
                calls: Cell::new(0),
                fail_on: None,
            };
            assert!(to_zeroizing_vec(&value).is_err());
            assert_eq!(value.calls.get(), 2);
        }
    }

    #[test]
    fn errors_in_either_pass_are_returned() {
        for pass in 0..2 {
            let value = Changing {
                first: "secret",
                second: "secret",
                calls: Cell::new(0),
                fail_on: Some(pass),
            };
            assert!(
                to_zeroizing_vec(&value)
                    .unwrap_err()
                    .to_string()
                    .contains("refused")
            );
            assert_eq!(value.calls.get(), pass + 1);
        }
    }

    #[test]
    fn count_refuses_overflow() {
        assert!(Count(usize::MAX).write_all(b"x").is_err());
    }
}
