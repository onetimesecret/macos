---
documentation_status: needs-review
---

# ADR-0048: A transfer sweeps due pages before it resolves

- **Status:** accepted
- **Date:** 2026-10-13
- **Depends on:** [ADR-0011](0011-ttl-choices.md), whose deadline admits no grace after expiry, and [ADR-0047](0047-the-sealed-fragment-the-detached-store-and-decrypted-drag.md), whose paste, move and clone this record guards.
- **Superseded in part by:** [ADR-0052](0052-a-page-past-its-deadline-gives-nothing-out.md), which replaces the consequence that copy, cut, copy decrypted and the decrypted drag still read a page past its deadline. The decision and the other consequences stand.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

ADR-0011 says of the grace a rung applies: "It is part of computing the
deadline, not a period during which an expired page is still readable.
Nothing survives its displayed expiry by any margin." [Law
0001](../law/0001-sealed-object.md)'s cut row says cut objects "retain
the page's clock".

A page leaves the store when something sweeps it: the shell's timer
(`PageModel.settleCoreEvent`, which calls `expireDue`, marks the store
dirty and refreshes) or a load, which sweeps after it restores
(`crates/ffi/src/lib.rs`). Between a page's deadline and its sweep the
page still stands in the store. The timer can fire late: on a busy main
thread, under App Nap or after sleep.

ADR-0047 point 6 resolves a reference against "any other live object,
attached or detached, on any page", and the active cut reattaches without
asking its page's clock. As built, both read a page in that interval, so a
cut from a page past its deadline reattached onto a fresh page, and a
copy's paste cloned its objects there, each on the fresh page's clock.

The store already refuses a due page where acting on it would extend it:
a rung change and the pause gesture return a refusal and leave the page to
its timer.

## Decision

A paste, a move or a clone never takes an object from a page past its
deadline.

1. A paste, the slot's paste, a move and a clone refuse a page past its
   deadline that no sweep has taken, changing nothing; its timer takes
   it, as with a rung change or a pause.
2. Before a paste whose fragment names an object resolves, the core
   sweeps every due page exactly as the timer's sweep does. Their objects
   then resolve by the records that sweep wrote, as `[sealed content ·
   expired]`, and a cut whose page it took has ended, so nothing
   reattaches. A fragment of ink alone sweeps nothing.
3. The sweep is the clock's and not the paste's: ADR-0047 point 8's
   transaction begins after it. A body that refuses afterwards reverts
   the paste, and the pages the sweep took stay taken, as the timer would
   have taken them.
4. The outcome counts the pages the sweep took as `pages_expired`. After
   a paste, move or clone the shell settles as its timer does, marking
   the store dirty and refreshing, so the shell drops a page the sweep
   took and writes the sealed file again. A refusal after a sweep
   reports nothing; the shell's timer, already due, settles it.

## Consequences

- A cut, a copy or a slot placed after its page's deadline places
  `[sealed content · expired]` for each object, on any page.
- A paste can end other pages before their timer fires; their tabs stay,
  empty, as after any expiry.
- A page past its deadline takes no paste, move or clone in the moments
  before its timer fires, while the shell still shows it.
- Copy, cut, copy decrypted and the decrypted drag do not sweep. They
  still read a page past its deadline until its timer fires; this record
  guards only the routes that place objects.
- A paste refused after its sweep is not a refusal that changed nothing.

## Eject triggers

- An object of a page past its deadline is found on another page after a
  paste, move or clone.
- A person reads a page taken at a paste, before its countdown showed
  zero to them, as lost work.

## Decision history

- 2026-10-13: Accepted for issue #170, before its code.
- 2026-10-13: Superseded in part by
  [ADR-0052](0052-a-page-past-its-deadline-gives-nothing-out.md). Its
  fourth consequence, that copy, cut, copy decrypted and the decrypted
  drag still read a page past its deadline, is replaced: every route
  that gives a page out now refuses it from its deadline, swept or not.
  The decision and the other consequences stand.
