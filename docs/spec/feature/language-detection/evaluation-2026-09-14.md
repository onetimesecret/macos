# Language-detection threshold evaluation — 2026-09-14

Status: **blocked; production thresholds remain provisional**

This is a measurement record, not an accepted specification or a project guarantee. The authoritative threshold requirement is ADR-0029, Decision item 2:

> “Keep ranked scores internal for evaluation. Choose minimum evidence, top-score, and top-two-margin thresholds from the local corpus before freezing the adapter.”

## Controlling conclusion

**Do not freeze the candidate in `crates/core/src/language_detection.rs` and do not enable automatic paste fencing.**

The original holdout report remains the controlling quality result. It failed:

- Automatic-paste code precision: **115/128 = 89.84%**; Wilson 95% CI **83.40–93.97%**.
- Dedicated prose/list/URL paste-negative conversions: **12/1,203 = 1.00%**; Wilson 95% CI **0.57–1.74%**.
- Automatic-paste useful-code coverage: **115/122 = 94.26%**; Wilson 95% CI **88.63–97.19%**.
- Automatic paste conversions: **128**, so this was not an all-abstain result.

The archived report is `tools/language-eval/reports/2026-09-14/holdout/report.json`, SHA-256 `cb7eb73e941882b66e1d70bd66bb38b1bccd4ab2f66ac1c0a6e02fb2bc71896b`.

## Threshold-selection evidence

The tuning calculation is now reproducible from committed artifacts:

- Raw baseline tuning rankings: `tools/language-eval/reports/2026-09-14/selection/baseline-tune-cases.jsonl`.
- Evaluated grid and selection constraints: `tools/language-eval/data/threshold-grid.json`.
- Selection implementation: `tools/language-eval/select-thresholds.py`.
- Full candidate table: `tools/language-eval/reports/2026-09-14/selection/threshold-selection.md` and `.json`.
- Selected candidate: `tools/language-eval/data/tuned-candidate.json` (`20 / 0.40 / 0.20`, maximum 4 MiB).

The grid evaluates 15 combinations. Three satisfy the recorded tuning constraints; maximizing automatic-paste useful-code coverage selects `20 / 0.40 / 0.20`, which produced **110/111 = 99.10%** precision, **0/603** dedicated negative conversions, and **110/122 = 90.16%** useful-code coverage.

This reproduces the selection calculation. It does not retroactively prove the chronology of the original run. The original candidate, corpus, reports, and execution note entered the repository together, and the original raw holdout rankings were not preserved. Therefore, “untouched original holdout” remains unsupported as independently auditable historical evidence.

## Adapter drift control

Production and the evaluator now depend on the same unpublished pure policy crate at `crates/language-detection-policy`. It owns byte eligibility, UTF-8/NUL rejection, evidence counting, finite-score rejection, inclusive top-score comparison, and inclusive top-two-margin comparison.

The evaluator has differential coverage that runs production and evaluation over eligible, short, whitespace-only, NUL-containing, invalid UTF-8, oversized, code, and Markdown-shaped paste inputs. It also verifies that the committed external baseline matches the production policy exactly. Threshold-boundary ranking tests remain explicit.

The production baseline remains `20 / 0.20 / 0.20`; the failed candidate remains `20 / 0.40 / 0.20`. Sharing policy code does not change production thresholds.

## Split-diversity remediation

The current corpus no longer creates holdout inputs by applying new serial numbers to tuning templates:

- Tuning retains `dedicated_paste_negative` and `paste_code`.
- Holdout uses separate `independent_holdout_paste_negative` and `independent_holdout_paste_code` implementations.
- The holdout negative generator composes 1,200 unique prose, list, and URL examples from split-specific vocabulary and layouts.
- A regression test requires generated family implementations to be disjoint between tune and holdout, and another checks all 1,200 holdout negatives are unique and gate-scoped.
- Exact duplicate IDs, duplicate inputs, and cross-split exact input overlap remain rejected.

This reduces direct template leakage. It does not establish statistical independence or production representativeness: the data remains deterministic, synthetic, English-heavy, and generated from bounded vocabularies and layouts. It still does not cover production clipboard prevalence, all 48 Betlang labels, multilingual prose, or the full malformed/configuration/unsupported-language matrix. General production-quality conclusions remain unsupported.

## Remediation diagnostic, not a new untouched holdout

The revised split was run to verify the harness and expose its behavior. It produced:

- Automatic-paste code precision: **102/103 = 99.03%**; Wilson 95% CI **94.70–99.83%**.
- Dedicated prose/list/URL paste-negative conversions: **0/1,203**; Wilson 95% CI **0.00–0.32%**.
- Automatic-paste useful-code coverage: **102/122 = 83.61%**; Wilson 95% CI **76.03–89.13%**.

Those numbers meet the proposed numerical rule, but they do **not** clear the gate. The revised corpus was designed after the original holdout result and this compliance review were visible, then executed in the same work session. It is a remediation diagnostic, not untouched validation evidence. Its raw rankings and reports are preserved under `tools/language-eval/reports/2026-09-14/remediation-holdout/`.

A future quality decision requires a new holdout source fixed before candidate evaluation, with its corpus identity and selection record committed separately before the holdout is run. Automatic fencing remains blocked until that evidence exists and the other ADR-0029 release gates are resolved.

## Artifact identities

- Current corpus SHA-256: `58ba0ecc377b932c74f34ecc47b7111c1121d332c8ccc681f3fc9c81373b2190`
- Current harness source SHA-256: `c8d3d0369d0da556165c85510bdbabcaa03303002e173fc31d017198cf98fe8f`
- Candidate configuration SHA-256: `86ae451aab83377ba402a8ffd35336050f6fc54a70d534ba2581a4539029f679`
- Threshold grid SHA-256: `225ddf675f27d8b652c3fa945be319d61141c78cf5027a88528eb206f0749bd5`
- Selection input SHA-256: `fd2b2338af8e6ad581cf43ace4985a37f25677ca7399b770d59249ead7880eda`
- Selection report SHA-256: `3a180089818f94ca4b298dd9b69c916921176fe44f4bbba65bc2ae7d7dbf0849`
- Remediation holdout report SHA-256: `2de21fb558254b9470688a5ed5e8c19bd7d0856ed69ce382072e98989428599f`
- Remediation holdout raw cases SHA-256: `5c6f429b95bb1397688f3a3d11b97dfdfb70aaf43827cd487094f051f47bcee9`
- Betlang version: `0.1.1`
- Registry crate checksum SHA-256: `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`
- Model SHA-256: `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`
- Model size: `47,840` bytes

## Reproduction

From the repository root:

```sh
cargo test -p language-eval
cargo clippy -p language-eval --all-targets -- -D warnings
python3 tools/language-eval/select-thresholds.py \
  --cases tools/language-eval/reports/2026-09-14/selection/baseline-tune-cases.jsonl \
  --grid tools/language-eval/data/threshold-grid.json \
  --output /tmp/threshold-selection.json \
  --markdown-output /tmp/threshold-selection.md \
  --expect-candidate tools/language-eval/data/tuned-candidate.json
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
  --output-dir tools/language-eval/output/remediation-holdout \
  --warm-iterations 100
```
