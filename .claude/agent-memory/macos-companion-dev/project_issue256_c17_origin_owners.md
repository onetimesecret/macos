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
- Copying an NSString into a wiping owner: `autoreleasepool(|pool| Zeroizing::new(unsafe { s.to_str(pool) }.to_owned()))`. `to_string` goes through the formatter and leaves a plain String.
- Loro 1.13.9 `get_change` returns a ref into an already parsed change block and clones the message's `Arc<str>`; the decode copy happens when a block is parsed, not per call. Do not write "per get_change" in the register.
- Register status: use C31's form ("**Implemented** ..."), not "**W — implemented**"; the em dash breaks the no dashes rule even though older rows use it.
- Versions taken: core 0.34.4, ffi 0.43.3 (#313 uses 0.34.3 and 0.43.2), pasteboard 0.5.0 (public field type change). See [[stacked-version-bumps]].
- Still ordinary after C17: Foundation's NSString and UTF8String buffer, Loro's message copies (C01, C29), and derived `Debug` on `PasteboardItem` and `MemoryPasteboard` (now listed in C48).

Related: [[issue256-c31-resting-note]].
