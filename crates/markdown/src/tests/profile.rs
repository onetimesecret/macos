//! Synthetic integration timings; run explicitly with --ignored --nocapture.

use std::io::{self, Write};
use std::time::{Duration, Instant};

use super::*;

#[derive(Default)]
struct Count(usize);

impl Write for Count {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
#[ignore = "manual synthetic integration profile"]
fn preview_pipeline_profile() {
    for repetitions in [100, 1_000] {
        let template =
            "## Heading **bold**\n\nText &amp; &#x100000; {obj} [link](https://example.com).\n\n";
        let (text, offsets) = page(&template.repeat(repetitions));
        for dialect in BOTH {
            let mut elapsed = [Duration::ZERO; 5];
            let mut json_bytes = 0;
            for _ in 0..10 {
                let start = Instant::now();
                let source =
                    crate::source::Source::new(&text, &offsets, &Limits::default()).unwrap();
                elapsed[0] += start.elapsed();
                let start = Instant::now();
                if dialect == Dialect::Gfm {
                    assert!(
                        crate::cells::bound(&source.text) <= Limits::default().maximum_table_cells
                    );
                }
                elapsed[1] += start.elapsed();
                let start = Instant::now();
                let arena = comrak::Arena::new();
                let root = comrak::parse_document(&arena, &source.text, &crate::options(dialect));
                if dialect == Dialect::Gfm {
                    assert!(!crate::cells::exceeds_limit(
                        root,
                        Limits::default().maximum_table_cells
                    ));
                }
                let blocks = crate::walker::walk(root, &source, crate::MAXIMUM_DEPTH).unwrap();
                let document = Document {
                    blocks,
                    atoms: source.atoms,
                };
                elapsed[2] += start.elapsed();
                let start = Instant::now();
                let mut count = Count::default();
                serde_json::to_writer(&mut count, &document).unwrap();
                elapsed[3] += start.elapsed();
                let start = Instant::now();
                let mut output = vec![0; count.0];
                let mut remaining = output.as_mut_slice();
                serde_json::to_writer(&mut remaining, &document).unwrap();
                assert!(remaining.is_empty());
                elapsed[4] += start.elapsed();
                json_bytes = output.len();
                std::hint::black_box(output);
            }
            eprintln!(
                "preview-profile {dialect:?} input={} objects={} json={} mean_us: source={} cells={} parse_walk={} json_count={} json_write={}",
                text.len(),
                offsets.len(),
                json_bytes,
                elapsed[0].as_micros() / 10,
                elapsed[1].as_micros() / 10,
                elapsed[2].as_micros() / 10,
                elapsed[3].as_micros() / 10,
                elapsed[4].as_micros() / 10,
            );
        }
    }
}
