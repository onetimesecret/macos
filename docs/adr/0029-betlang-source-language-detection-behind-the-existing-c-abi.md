---
documentation_status: needs-review # draft | reviewed | stale
---

# ADR-0029: Betlang source-language detection behind the existing C ABI

- **Status:** proposed
- **Date:** 2026-09-12
- **Depends on:** [ADR-0024](0024-caret-only-automation-and-display-only-color.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

The related feature specification is
[source-language detection](../spec/feature/language-detection/README.md).

## Context

The three requested surfaces need the same content classifier but different UI
policies. Keep inference in `companion-core`, C interoperability in
`companion-ffi`, and trigger/render/edit decisions in Swift. A Rust
`Option<&'static str>` is an internal API, not a C ABI type.

Betlang is a small candidate with a limited label set and a young dependency
history. Repository popularity and another editor's adoption are not evidence
of suitability for ordinary note pastes. The reported Zed integration and
27-star count have not been independently verified for this plan and are not
acceptance criteria.

## Upstream evidence and artifact record

Upstream primary sources below describe Betlang, not this application's
security, compatibility, or accuracy guarantees. Inspection date: 2026-09-12.
Snapshot: `514a4cd95c26447ac3649826f266ef2d02448888`.

| Item | Recorded value |
|---|---|
| Proposed exact Cargo pin | `betlang = "=0.1.1"` |
| Snapshot manifest version | `0.1.1` |
| Snapshot Rust requirement | `1.88`, edition 2024 |
| Runtime dependency in manifest | `fearless_simd = "0.4"`; no Dioxus dependency listed |
| Embedded artifact | `assets/magika/source-student-q4.bin` |
| Format | weights-only MSQ1 |
| Size reported upstream | 47,840 bytes |
| SHA-256 reported upstream | `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083` |
| Architecture | `wordseq-b1024-k3-m2048-tiny-3conv-hidden` |
| Tokenizer | version 3 |
| Output labels | 48 |

The checksum is recorded here as the proposed artifact pin. It has **not** been
independently computed from the published crate in this task. Before adding the
dependency, fetch the exact registry package, hash its embedded model, verify its
source/API against the inspected snapshot, and record the package checksum and
VCS revision. A manifest version on `main` does not prove the registry release
contains that commit's inference optimizations. Fail adoption on mismatch;
review a new pin rather than silently updating this record.

Primary sources:

- [Snapshot Cargo.toml](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/Cargo.toml)
  is the source for manifest observations.
- [README, Model and Performance](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/README.md)
  says: “The model is loaded once per process and then reused through a
  `OnceLock`.” It also says: “Native CPU inference dispatches through
  `fearless_simd`.” These are upstream descriptions, not local benchmarks.
- [Model card, Evaluation](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/MODEL_CARD.md)
  reports `test_fs_accuracy=0.942353` and `macro_recall=0.939690` on a held-out
  filesystem-label split of 34,087 files. Its evaluation description includes:
  “rows where the teacher keeps at most 10% of its probability mass on the head
  labels are excluded”. Interpretation: approximately 94% on that split is not
  an estimate of code-versus-prose paste accuracy.
- The same model card says: “Non-source formats are out of scope unless
  represented by a public source-language variant.” It also says: “Very short
  inputs are intentionally rejected when fewer than eight non-whitespace bytes
  are available.”
- [Public API source](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/src/lib.rs)
  implements `language()` by taking the first ranked prediction, without a
  confidence threshold. Interpretation: the adapter needs an abstention policy;
  `language().is_some()` is not a code-recognition gate.

The local workspace declares Rust `1.94` and pins toolchain `1.94.1`. This is a
manifest comparison only; building the exact dependency and its transitive
resolution on supported targets remains required.

## Decision

1. Add the exact dependency to `crates/core/Cargo.toml` and commit the resolved
   `Cargo.lock`. Do not add a second inference implementation in `crates/ffi`.
2. Expose this safe core convenience API:

   ```rust
   pub fn detect_source_language(bytes: &[u8]) -> Option<&'static str>;
   ```

   Return a canonical Betlang slug only after input and confidence checks;
   otherwise return `None`. Keep ranked scores internal for evaluation. Choose
   minimum evidence, top-score, and top-two-margin thresholds from the local
   corpus before freezing the adapter. Reject non-finite scores. No public
   assurance that a returned label means the input is code.
3. Export a stateless C wrapper, provisionally:

   ```c
   /* Proposed; not an existing header declaration. */
   char *companion_detect_source_language(const uint8_t *bytes, size_t len);
   ```

   Return NULL for abstention, invalid input, or contained inference failure.
   Return a newly allocated NUL-terminated slug otherwise; Swift copies it and
   calls the existing `companion_string_free`. This follows current owned-string
   conventions instead of introducing a borrowed static pointer exception.
   Do not expose a Rust slice, enum, string fat pointer, or `Option` directly.
4. Input is borrowed only for the synchronous C call. `(NULL, 0)` is empty;
   `(NULL, nonzero)` is invalid. Check lengths before constructing a slice;
   non-null input must be readable for `len` bytes and remain unchanged until
   return. Arbitrary invalid pointers cannot be made safe by validation.
   Use an explicit pointer/length, never `strlen`; embedded NULs are not a
   terminator and should cause text eligibility to abstain. Bound input to the
   existing 4 MiB file limit initially. Do not acquire the mutable store mutex
   or require a `CompanionHandle` merely to run inference.
5. Contain Rust unwinding panics at this new boundary and return NULL. This is
   not protection against invalid foreign pointers or process-aborting failures.
   Add a Swift `String?` wrapper and a bounded worker service with owned input
   lifetime, cancellation, and document-revision checks.
6. Reuse upstream one-time initialization; do not add a second model loader,
   runtime downloader, or redundant `OnceLock`. Verify the packaged implementation
   before relying on snapshot behavior. Bound concurrency because runtime scratch
   and transformed weights are larger than the compressed model artifact.
7. Swift owns language-to-renderer mapping and action policy. Use one conservative
   acceptance gate initially for all three surfaces. If manual suggestions need
   weaker thresholds, propose a structured result/API revision instead of silently
   changing the meaning of the label-only export.

### License and redistribution

The upstream [README, License And Attribution](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/README.md)
says exactly:

> Betlang is licensed under MIT. The embedded student model was trained from
> outputs of Google's Magika teacher model; Magika is published by Google under
> Apache-2.0. Keep this attribution with redistributed model artifacts.

The [model card, Attribution](https://github.com/DioxusLabs/betlang/blob/514a4cd95c26447ac3649826f266ef2d02448888/MODEL_CARD.md)
says exactly:

> The embedded student model was trained from outputs of Google's Magika teacher
> model. Magika is published by Google under Apache-2.0. Betlang's source code is
> MIT licensed; keep Magika attribution with redistributed model artifacts.

Proposed release requirement: preserve Betlang's MIT license/copyright notice,
include the quoted Magika attribution and Apache-2.0 license text in shipped
third-party notices, and review any applicable upstream NOTICE material and
transitive dependency licenses. Carry notices with app distributions and any
separately redistributed framework/model artifacts; an ADR present only in this
repository is insufficient. Verify final packaged artifacts, not just source
files. Do not infer from these statements that the student weights have been
unambiguously relicensed Apache-2.0; resolve licensing ambiguity before release.

### Partial replacement of ADR-0024 on acceptance

Ask reviewers to approve these specific extensions to ADR-0024:

- Opt-in automatic fencing may transform only the incoming paste replacement,
  including its explicitly selected replacement range, as one undoable action.
  It may not rewrite surrounding existing lines.
- An explicit wrap/insert-label command may change only the range presented to
  the user, even when it is not the caret's line.
- Bare-fence content may produce a dismissible suggestion; an accepted inferred
  language may drive display-only highlighting without changing the info string.
- Whole-file Source mode and fixed-width code-region styling are allowed in the
  editable surface. Recognition surfaces remain outside scope.

Until this ADR is accepted, ADR-0024 remains unchanged. On acceptance, record
the reciprocal partial-supersession relationship in both ADRs. Do not mark
ADR-0024 superseded wholesale.

## Consequences

A small model does not imply a 50 KB binary delta or a 50 KB memory footprint.
Measure linked size, cold initialization, steady-state latency, derived-data
retention, and concurrency cost locally. Wrong suggestions remain possible;
wrong automatic fencing is the more costly error.

Pin upgrades require a checksum, license, label-mapping, quality, and performance
review.

## Eject triggers

Do not ship automatic paste conversion if prose false positives remain material,
if a single responsive undoable paste cannot be preserved, or if policy approval
is absent. The other surfaces may ship separately only after their own policy,
artifact, licensing, and evaluation gates pass.
