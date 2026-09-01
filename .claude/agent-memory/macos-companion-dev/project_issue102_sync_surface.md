---
name: issue102-sync-surface
description: #102's surface landed on feature/102-sync-surface; the relay's delta stream has no author so own ops echo back, and the signin cancel now really ends the browser trip
metadata:
  type: project
---

Issue #102 built on branch `feature/102-sync-surface` off
`feature/132-undo-manager` (pushed 2026-09-01, PR #143). Most of the
surface already existed under #98/#119/#121; what #102 added was the
header word, the give up, the last seen line, the elsewhere mark, the
off proof, `docs/spec/feature/sync/surface.md` and
`docs/qa/verification-procedures/sync-enrolment.md`.

**The relay's delta stream carries no author, so a device fetches back
its own published blobs and re-imports them.** `SyncEvent::Applied`
fired for those echoes, which was harmless while the only consumer was
a refresh and false the moment a page had to say "another device is
editing this page". The discriminator is the document frontier:
`store.document_version` before and after the import, and only a moved
frontier is an arrival. A publish does *not* advance `next_seq`, so
this is not a corner case; it happens on every publish.

**Why:** the mark had to be true or it was worse than nothing.

**How to apply:** never treat an `applied` event as evidence a peer
did something without checking the document moved. If per author
attribution is ever needed, the envelope has no author field and
ADR-0021's blindness is why.

**`companion_sync_signin_cancel` used to be unable to stop a sign in
that was already out.** The finish takes the ceremony out of the state
and blocks in the loopback listener for the full five minutes, so the
old cancel dropped only a ceremony nobody had taken. It now raises a
shared `AtomicBool` the accept loop watches, which is what makes
ADR-0027 §5's "a way to give up" a real control rather than a button.
The core answers both a given up and a never returned trip with
`abandoned`; the shell keeps the difference for one settling only.

**Two judgement calls a maintainer may want to revisit.** The gate
`off` earns no header word even with the switch on over no relay (the
page's sentence carries it instead), and `attached` reads `synced`
except when pages are enrolled with no peer awake, which reads
`sync waiting`. The header word table lives in
`SyncController.headerWord` and is tested one state at a time.

Related: [[issue98-account-gate]], [[relay-hosting-and-auth-decision]].
