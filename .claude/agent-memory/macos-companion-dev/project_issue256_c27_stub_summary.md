---
name: issue256-c27-stub-summary
description: Issue #256 row C27 (PR 316, 2026-10-21, no version bump); StubWire::summarize reads through derived structs with IgnoredAny; B1 now lists C08, C17, C19 to C21; F08 still names C22 as remaining
metadata:
  type: project
---

C27 shipped as PR 316 on fix/256-stub-summarize. `StubWire::summarize`
(`crates/ffi/src/conceal.rs`, test-util only) reads the body through
`SummaryBody`/`SummaryFields`; the secret's text, unnamed fields and the
passphrase are `IgnoredAny`. No crate bump: test-util only, non-test
surface unchanged.

**Why:** serde_json 1.0.150 skips an ignored string in place
(`SliceRead::ignore_str`, `ignore_escape`); `ignore_value` puts only `[`/`{`
frame bytes in `self.scratch`. A review bot said that stack was local; it
is `self.scratch` (de.rs 1103, 1145, 1156, 1192).

**How to apply:**
- A lone surrogate escape (`"\ud800"`) is the test witness that a value
  is skipped undecoded: any `String` decode refuses it.
- Derived typed parsing is all-or-nothing where `Value` degraded per
  field; declined adding a parse flag because it moves the pinned bytes.
- B1 after PR 316: C08, C17, C19 to C21, and `bytes_to_write` (C05).
  F04 and C22 cross references were fixed; F08 still names C19 to C22 as
  remaining, although C22 reads implemented.

Related: [[issue256-c31-resting-note]].
