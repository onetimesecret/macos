# Language-detection evaluation checklist

Status: **completed evaluation; gate failed** · 2026-09-14

This checklist records execution state. It is not an accepted specification.

## Discipline and provenance

- [x] Use only synthetic inputs; no clipboard history, private documents, or real credentials.
- [x] Pin and record Betlang `0.1.1`, registry checksum, package VCS revision, model checksum, and model size.
- [x] Enforce unique expanded IDs and inputs.
- [x] Enforce no exact input overlap between tuning and holdout splits.
- [x] Use disjoint deterministic generator ranges for tuning and holdout.
- [x] Select candidate thresholds from tuning only.
- [x] Run the tuning-selected candidate on holdout without using holdout results
  for selection or retuning. Rerun the unchanged candidate and corpus only after
  correcting evaluator eligibility to match production NUL/UTF-8 refusal.
- [x] Preserve candidate configuration and generated tune/holdout summaries.
- [x] Record corpus, configuration, raw output, report, artifact, and repository identities.

## Approved proposed gate

- [ ] At least 99% automatic-paste code precision on eligible held-out paste conversions. Observed: **115/128 = 89.84%**, Wilson 95% CI **83.40–93.97%**.
- [ ] Zero automatic conversions over at least 1,000 dedicated held-out prose/list/URL paste negatives. Observed: **12/1,203 = 1.00%**, Wilson 95% CI **0.57–1.74%**.
- [x] Report useful-code coverage. Observed: **115/122 = 94.26%**, Wilson 95% CI **88.63–97.19%**.
- [x] Report exact-label useful-code coverage separately. Observed on paste: **107/122 = 87.70%**, Wilson 95% CI **80.70–92.41%**.
- [x] Forbid all-abstain. Observed: **128** held-out automatic paste conversions.
- [x] Report uncertainty and corpus dependence.

## Decision

- [x] Record gate conclusion as **fail**.
- [x] Leave `crates/core/src/language_detection.rs` thresholds provisional and unchanged.
- [x] Do not claim shipping approval or production accuracy.
- [ ] Freeze production thresholds. Blocked by failed holdout.

## Validation

- [x] `cargo fmt -p language-eval -- --check`
- [x] `cargo test -p language-eval`
- [x] `cargo clippy -p language-eval --all-targets -- -D warnings`
- [x] `cargo test -p companion-core`
- [x] `cargo clippy -p companion-core --all-targets -- -D warnings`

See [the full evaluation record](evaluation-2026-09-14.md).
