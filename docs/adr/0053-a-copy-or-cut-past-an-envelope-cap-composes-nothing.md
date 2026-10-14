---
documentation_status: needs-review
---

# ADR-0053: A copy or a cut past an envelope cap composes nothing

- **Status:** accepted
- **Date:** 2026-10-13
- **Supersedes in part:** [ADR-0049](0049-a-pasted-envelope-is-bounded.md), specifically its consequence "A selection longer than 8 MiB or holding more than 1024 objects still copies and cuts, and pastes in the app as its public text with the unreadable line. A cut that large cannot be placed from the slot, which carries no public text, and its active cut does not survive a relaunch; ⌘Z on its page brings its objects back." Its decision and its other consequences stand.
- **Depends on:** [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), whose points 1, 2 and 5 say what a copy and a cut write.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0049 bounds the envelope a paste reads: no longer than 8 MiB, no
more than 1024 references. `Fragment::parse` in
`crates/core/src/fragment.rs` checks both; `copy_fragment` and
`cut_fragment` in `crates/core/src/transfer.rs` composed without them.

So this build wrote envelopes it then refused to read. A cut that large
detached its objects as an active cut whose own envelope the slot could
not place and a relaunch could not restore, which left ⌘Z as the only
way back for those objects.

## Decision

Copy and cut compose an envelope only within ADR-0049's caps.

1. Both measure the envelope they would write, its length in bytes and
   the references it names, with the one check the parse uses. The
   length is the sizing pass's count, taken before the buffer exists; a
   cut's envelope is measured with its cut field.
2. Past either cap, both refuse whole: nothing is written, a cut deletes
   nothing and detaches nothing, and the active cut stays as it was. A
   selection of ink alone writes no envelope and meets no cap.
3. The refusal names its cap and limit across the seam,
   `{"error": "tooLarge", "limit": 8388608}` or
   `{"error": "tooManyObjects", "limit": 1024}`, as a file open's
   `tooLarge` does, so the shell's line can name the core's number.

## Consequences

- An envelope this build writes is one it reads, at either cap.
- A selection past a cap cannot be copied or cut with its objects, nor
  dragged, since a drag between pages "carries the copy fragment"
  (ADR-0047 point 10). The person selects less.
- No cut leaves objects that only ⌘Z brings back.
- The shell owes the line. Until it is written, the refusal reads as a
  copy or a cut that did nothing.

## Eject triggers

- A person's own selection meets a cap in ordinary use, which would ask
  for higher caps or a paged envelope, not for copy to outrun paste
  again.
- A person needs the ink of a selection past a cap without its objects,
  which would ask for a copy that names what it leaves out.

## Decision history

- 2026-10-13: Accepted for issue #170, before its code.
