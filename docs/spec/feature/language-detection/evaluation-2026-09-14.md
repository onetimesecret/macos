# Language-detection threshold evaluation — 2026-09-14

Status: **failed; production thresholds remain provisional**

This is a measurement record, not an accepted specification or a project guarantee. The authoritative threshold requirement is ADR-0029, Decision item 2:

> “Keep ranked scores internal for evaluation. Choose minimum evidence, top-score, and top-two-margin thresholds from the local corpus before freezing the adapter.”

The proposed automatic-paste gate evaluated here comes from the implementation plan: at least 99% precision among eligible held-out paste conversions, zero automatic conversions over at least 1,000 dedicated prose/list/URL paste negatives, reported uncertainty and useful-code coverage, and no all-abstain result.

## Conclusion

**Fail. Do not freeze the candidate in `crates/core/src/language_detection.rs`.**

The tuning-selected candidate failed the untouched holdout:

- Automatic-paste code precision: **115/128 = 89.84%**; Wilson 95% CI **83.40–93.97%**. Required point estimate: at least 99%.
- Dedicated prose/list/URL paste-negative conversions: **12/1,203 = 1.00%**; Wilson 95% CI **0.57–1.74%**. Required: zero conversions over at least 1,000 cases.
- Automatic-paste useful-code coverage: **115/122 = 94.26%**; Wilson 95% CI **88.63–97.19%**.
- The detector did not abstain on everything: **128** automatic paste conversions occurred.
- Exact-label useful-code coverage for the paste surface was **107/122 = 87.70%**; Wilson 95% CI **80.70–92.41%**. Rust was the principal observed label confusion: 8/10 generated held-out Rust snippets converted, but none received the expected `rust` label.

Twelve dedicated held-out list cases were automatically classified as `haskell`. One additional held-out credential-shaped negative was classified as `ini`; it is outside the dedicated prose/list/URL sub-gate but lowers overall conversion precision.

## Tune/holdout discipline

1. The existing baseline was run on the tuning split only.
2. The corpus and harness were expanded before candidate selection.
3. Candidate selection used only `tools/language-eval/output/audit-expanded-tune-baseline/cases.jsonl`.
4. The selected candidate was rerun on tuning.
5. The candidate was then run on holdout without changing the candidate, corpus, or generator.
6. Audit found that evaluator eligibility omitted the adapter's NUL/UTF-8 checks. Those checks were added and the same fixed candidate and unchanged corpus were rerun. This changed only one explicit binary/file case from eligible to ineligible; paste-gate counts were unchanged.
7. Holdout failure was recorded rather than used to retune.

The harness now rejects duplicate case IDs, duplicate expanded inputs, and any exact input shared across tune and holdout. Generated tune and holdout families use disjoint serial ranges.

## Candidate selected from tuning

Configuration: [`tools/language-eval/data/tuned-candidate.json`](../../../../tools/language-eval/data/tuned-candidate.json)

- Minimum non-whitespace bytes: `20`
- Minimum top score: `0.40`
- Minimum top-two margin: `0.20`
- Maximum input bytes: `4,194,304`

Selection rule: among the evaluated grid, prioritize candidates meeting the proposed tuning gate, then maximize useful-code coverage. The chosen candidate produced:

- Automatic-paste code precision: **110/111 = 99.10%**; Wilson 95% CI **95.07–99.84%**.
- Dedicated prose/list/URL paste-negative conversions: **0/603**; Wilson 95% CI **0.00–0.63%**.
- Automatic-paste useful-code coverage: **110/122 = 90.16%**; Wilson 95% CI **83.59–94.28%**.

These tuning measurements selected a candidate; they are not validation evidence.

## Corpus and metric interpretation

The corpus is deterministic, synthetic, and contains no private data. Each split contains 120 generated paste-code cases spanning Rust, Python, JavaScript, TypeScript, Swift, Go, shell, SQL, JSON, YAML, TOML, and Ruby, plus explicit cases. The dedicated negative families contain only prose, lists, and URLs: 600 tuning cases and 1,200 held-out cases, plus three explicit cases per split.

For the automatic-paste metrics, a conversion is a threshold-accepted `paste` result other than `markdown`. This models the proposed feature requirement to skip a `markdown` result. “Automatic-paste code precision” treats any useful-code conversion as a true positive; exact language correctness is reported separately.

The generated families vary deterministic templates and serials. Cases sharing a template are correlated, so Wilson intervals that treat cases as independent are optimistic. The corpus does not represent production clipboard prevalence, all 48 Betlang labels, multilingual prose, or the full planned malformed/configuration/unsupported-language matrix. Therefore, even a numerical pass on this corpus would still require review before production threshold freezing. The observed holdout is an unambiguous failure of the proposed numerical gate.

## Identities

Inputs:

- Repository base revision before this task: `d0d6758d0fae3aaacd58e742aaec6a8b1cd3fcba`
- Corpus declaration SHA-256: `ef489f116b8d1cc9279231dad2db57eb5ebce4063ec3e4e209fce5b81d72edc8`
- Harness/generator source SHA-256: `fe9f02dc33ba4f0f5f49a66171073bc90f57a7e4a5ed714e15db06749446f121`
- Candidate configuration SHA-256: `86ae451aab83377ba402a8ffd35336050f6fc54a70d534ba2581a4539029f679`
- Betlang version: `0.1.1`
- Registry crate checksum SHA-256: `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`
- Package VCS revision: `13b5cbf7b934fdbd4be0bb7437faeb03124700de`
- Model SHA-256: `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`
- Model size: `47,840` bytes

Outputs:

- Committed tune report JSON SHA-256: `5f846fd5cacd99e39552e3a28fc125101dd94df6dbbd16e71fcc55f6cda061ad`
- Generated tune `cases.jsonl` SHA-256: `46ee37479c6ca613923e02775eeb9922e6227a72595cebd75a1042ea4407e30a`
- Committed holdout report JSON SHA-256: `cb7eb73e941882b66e1d70bd66bb38b1bccd4ab2f66ac1c0a6e02fb2bc71896b`
- Generated holdout `cases.jsonl` SHA-256: `46efeb211dd97f71879c8848fcba9d7cbe988d43826f512580425843a20565df`

The harness records registry/model identities as metadata but does not re-hash dependency artifacts at runtime.

## Environment and cost observations

Environment: macOS `27.0` build `26A5425a`, Apple silicon (`arm64`), Rust/Cargo `1.94.1`, release profile.

Holdout run measurements:

- First eligible inference: `1,615,583 ns`.
- Warm p50/p95/p99/max over 100 iterations: `852,208 / 896,833 / 936,000 / 937,167 ns`.
- Evaluator executable: `742,608` bytes.
- Whole-process maximum RSS proxy from `/usr/bin/time`: `8,863,744` bytes.

These are local evaluator-process measurements, not end-to-end Swift request measurements and not supported-hardware qualification.

## Reproduction

From the repository root:

```sh
cargo test -p language-eval
cargo clippy -p language-eval --all-targets -- -D warnings
cargo run --release -p language-eval -- evaluate \
  --corpus tools/language-eval/data/corpus.json \
  --thresholds tools/language-eval/data/tuned-candidate.json \
  --split tune \
  --output-dir tools/language-eval/output/tuned-candidate-tune \
  --warm-iterations 100
cargo run --release -p language-eval -- evaluate \
  --corpus tools/language-eval/data/corpus.json \
  --thresholds tools/language-eval/data/tuned-candidate.json \
  --split holdout \
  --output-dir tools/language-eval/output/tuned-candidate-holdout \
  --warm-iterations 100
shasum -a 256 \
  tools/language-eval/data/corpus.json \
  tools/language-eval/src/main.rs \
  tools/language-eval/data/tuned-candidate.json \
  tools/language-eval/output/tuned-candidate-tune/report.json \
  tools/language-eval/output/tuned-candidate-tune/cases.jsonl \
  tools/language-eval/output/tuned-candidate-holdout/report.json \
  tools/language-eval/output/tuned-candidate-holdout/cases.jsonl
```

Committed generated summaries:

- [`tools/language-eval/reports/2026-09-14/tune/report.md`](../../../../tools/language-eval/reports/2026-09-14/tune/report.md)
- [`tools/language-eval/reports/2026-09-14/tune/report.json`](../../../../tools/language-eval/reports/2026-09-14/tune/report.json)
- [`tools/language-eval/reports/2026-09-14/holdout/report.md`](../../../../tools/language-eval/reports/2026-09-14/holdout/report.md)
- [`tools/language-eval/reports/2026-09-14/holdout/report.json`](../../../../tools/language-eval/reports/2026-09-14/holdout/report.json)
