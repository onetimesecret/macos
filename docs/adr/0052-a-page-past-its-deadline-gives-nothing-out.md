---
documentation_status: needs-review
---

# ADR-0052: A page past its deadline gives nothing out

- **Status:** accepted
- **Date:** 2026-10-13
- **Supersedes in part:** [ADR-0048](0048-a-transfer-sweeps-due-pages-before-it-resolves.md), specifically its consequence "Copy, cut, copy decrypted and the decrypted drag do not sweep. They still read a page past its deadline until its timer fires; this record guards only the routes that place objects." Its decision and its other consequences stand.
- **Depends on:** [ADR-0011](0011-ttl-choices.md), whose deadline admits no grace after expiry.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0011 says of the grace a rung applies: "It is part of computing the
deadline, not a period during which an expired page is still readable.
Nothing survives its displayed expiry by any margin."

ADR-0048 refused a page past its deadline to a paste, a move and a
clone, and accepted that copy, cut, copy decrypted and the decrypted
drag still read it until the shell's timer fires. That consequence
contradicts ADR-0011, which ADR-0048 neither amends nor supersedes.

The interval can be long. ADR-0048 says "The timer can fire late: on a
busy main thread, under App Nap or after sleep", and the core's clock
keeps counting while the system sleeps (`crates/core/src/clock.rs`).
After hours asleep, a page can be hours past its deadline and still
stand in the store until the timer fires. In
that time copy decrypted, copy `NAME=value`, the decrypted drag and a
conceal each write the page's plaintext out and record a `sent`, and the
note's text and a fragment's copy or cut hand its ink, names and notes
to the shell and the general pasteboard.

## Decision

From a page's deadline, whether or not a sweep has taken it, the core
gives none of it out.

1. One store accessor, `readable_sheets`, holds the live pages whose
   countdown still runs. It asks the same question the sweep asks,
   `Sheet::is_due`, so a page leaves it at the instant it becomes due.
2. Copy decrypted, copy `NAME=value`, the decrypted drag, a chip's
   conceal and a page's conceal, the note's text, and a fragment's copy
   and cut find their page or object only through that accessor. On a
   page past its deadline each refuses: it writes nothing, sends
   nothing, records no `sent`, and a cut changes nothing.
3. A read does not sweep. Its refusal is its report: both conceals
   answer "this page has expired", and the other routes answer as for
   an unknown id.
4. The shell settles after any refusal of these routes, as when its
   timer fires, which sweeps the page and drops it from the screen.

## Consequences

- ADR-0011's sentence holds for every route that hands plaintext to
  the pasteboard, a drag, the server or the shell's note.
- A page the shell still shows refuses every way out once its deadline
  passes; the person meets a refusal, then the settle takes the page.
- The routes that draw a page, its document, faces and meta, are not
  gated, so the page stays on screen until the shell settles. Settling
  on wake as well as on the timer narrows that interval; it is the
  shell's to build.
- A conceal staged before the deadline and answered after it still
  records its `sent`: the read happened while the page was readable.

## Eject triggers

- Any route hands a page's plaintext out after its deadline, swept or
  not.
- A person reads a refusal on a page whose countdown they still see
  running as lost work, which would ask for the shell to settle sooner,
  not for the gate to move.

## Decision history

- 2026-10-13: Accepted for issue #170, before its code.

## Erratum

2026-10-13: Decision point 2 says each route finds its page or object
only through `readable_sheets`. Each reads only through it, but to
word its refusal a page's conceal asks whether the page still stands,
and a chip's conceal whether any page still holds the chip; neither
reads either. The first consequence names the shell's note among the
routes the gate covers. The core's note route is covered, but AppKit
copies, cuts and drags the open note's ink, and serves a page's
selection of ink alone to a service or a drag of several stretches,
from the text the shell already shows, which no core route sees; until
the shell settles, those still give the page out. The last consequence
says a conceal answered after the deadline still records its `sent`.
It does only while the page stands: a sweep during the round trip
leaves the record nowhere to land, as `finish_conceal` in
`crates/ffi/src/lib.rs` already said. The decision is unchanged.
