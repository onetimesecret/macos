---
name: issue256-c17-origin-owners
description: Register row C17 (origin URLs) chose W in PR 315 on 2026-10-21; what stays ordinary, the NSString copy idiom, Loro message facts and the version numbers taken
metadata:
  type: project
---

C17 (origin URLs) was implemented as **W** in PR 315 (fix/256-origin-owners, 2026-10-21):
`PasteboardItem.origin_url`, the memory board's stored origin, `SpanProvenance.origin` and
`MaterializedMeta.origin` are `Option<Zeroizing<String>>`; `origin_message` moved to
`ffi/src/content_json.rs` and counts then writes into a zeroed exact buffer.

**Why:** the origin is any string the writing app put under `public.url`, query included, so
it can bear a token; only `UNRECORDED_ORIGIN` (Loro transaction origin) is an N identifier.

**How to apply:**
- Read an NSString's UTF-8 only through `pasteboard/src/macos.rs::utf8_of` (getBytes into a zeroed Zeroizing buffer). `to_str`, `to_string` and Display all call `UTF8String`, which mallocs an unwiped UTF-8 copy for a UTF-16 stored string and returns NULL for an unpaired surrogate, so objc2 builds a slice from NULL (UB).
- The board cannot deliver an unpaired surrogate here: `setString` of one reads back as "" and invalid UTF-8 data reads back as nil, so test the refusal on `utf8_of` with `stringWithCharacters_length`, and the read's choice on `chosen_content` (an unconverted text falls through to the PNG, the coordinator's call on 2026-10-21).
- Compare type names with `isEqualToString` (`SystemPasteboard::declares`), never by converting them; `read` runs in its own `autoreleasepool` (`read_in_pool`).
- Loro (change merge interval 0) folds a backdated commit into the change before it, so a test that wants the earliest change mid span must commit in rising stamps and insert at the front last.
- Loro 1.13.9 `get_change` returns a ref into an already parsed change block and clones the message's `Arc<str>`; the decode copy happens when a block is parsed, not per call. Do not write "per get_change" in the register.
- Register status: use C31's form ("**Implemented** ..."), not "**W — implemented**"; the em dash breaks the no dashes rule even though older rows use it.
- Versions taken: core 0.34.4, ffi 0.43.3 (#313 uses 0.34.3 and 0.43.2), pasteboard 0.5.0 (public field type change). See [[stacked-version-bumps]].
- Still ordinary after C17: Foundation's NSString and whatever it allocates inside getBytes (not inspected), and Loro's message copies (C01, C29). A capacity equals length check cannot count copies; do not write "copied once" in a test comment. `PasteboardItem` and `MemoryPasteboard` now have hand written `Debug` that redacts only the origin; their content still prints (C48).
- The review bot's other points on PR 315 were left: no diag on `origin_message`'s unreachable `None`, no shared count-and-write helper with `encode`, no restored "compaction reads it back" doc line (AGENTS.md forbids answering a finding with comment prose), the `leftover.length` check kept beside `used == len`, and no NUL guard in `origin_message` (its output never crosses the C seam).

Related: [[issue256-c31-resting-note]].
