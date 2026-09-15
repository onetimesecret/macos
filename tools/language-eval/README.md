# Language evaluation harness

`language-eval` is a maintained, non-shipping Rust workspace tool for measuring the registry artifact `betlang = "=0.1.1"` against deterministic synthetic clipboard-shaped inputs. It is not linked by any shipping crate or the macOS app.

The corpus contains synthetic examples only. Do not add private data or user clipboard contents. Tune and holdout cases use disjoint explicit examples and generated serial ranges; use tune results when changing thresholds and reserve holdout results for evaluation. The harness rejects duplicate IDs, duplicate expanded inputs, and exact input overlap between splits.

`data/zed-baseline.json` is explicitly labeled as the Zed external starting baseline. It sets 20 non-whitespace bytes, a 0.20 top score, and a 0.20 top-two margin. It is not a Companion-selected threshold. `data/tuned-candidate.json` records the candidate selected from the 2026-09-14 tuning run; it failed holdout and is not approved for production. `maximum_input_bytes` remains configurable.

## Run

From the `macos` workspace root:

```sh
cargo fmt --all -- --check
cargo test -p language-eval
cargo clippy -p language-eval --all-targets -- -D warnings
cargo run --release -p language-eval -- evaluate \
  --corpus tools/language-eval/data/corpus.json \
  --thresholds tools/language-eval/data/zed-baseline.json \
  --split holdout \
  --output-dir tools/language-eval/output/holdout \
  --warm-iterations 100
```

`--split` accepts `all`, `tune`, or `holdout`. Output consists of `cases.jsonl`, `report.json`, and `report.md`. The generated `output/` directory is ignored by Git. Selected summary snapshots are committed under `reports/`; regenerate `cases.jsonl` from the identified corpus and configuration when raw ranked values are needed.

## Interpretation and limitations

The harness reports acceptance quality, useful-code coverage over all useful-code cases, negative false conversions, automatic-paste code precision and useful-code coverage, dedicated prose/list/URL paste-negative conversions, product-surface (`paste`, `fence`, and `file`), content-kind, and input-length breakdowns, Wilson 95% confidence intervals for rates, confusion data, timing, executable size, and a whole-process peak-RSS proxy obtained from `/usr/bin/time` when supported. Automatic-paste metrics exclude `markdown` predictions, matching the proposed paste policy; exact-label quality is reported separately. Latency is wall-clock timing and is affected by the host. Peak RSS covers the entire evaluator process, not only the model. Artifact checksums and sizes in reports are recorded metadata; the harness does not re-hash the embedded model or downloaded crate at runtime.

This tool collects evidence. Passing thresholds or producing favorable measurements is not shipping approval and does not integrate language detection into the app. The synthetic corpus does not establish performance on private or production clipboard data.
