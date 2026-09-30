# Roadmap

GitHub milestones and issues are the source of truth for delivery status. This document is a short index to current work and durable plans.

## Current work

No milestone is open. Milestones 3 and 4 both closed out in the first days of September 2026 and are listed below, and no issue in the repository is currently open.

- File backed documents are implemented on `feature/regular-text-files`: a content class that is a peer to pages, both first class, with the file on disk as the artifact, explicit save, and drafts staged in their own sealed file. [ADR-0028](adr/0028-file-backed-documents-are-a-peer-content-class.md) is proposed, not accepted, so the branch is not a commitment yet. The behaviour is written down in the [file backed documents specification](spec/feature/file-editing/README.md) and the code is mapped in [file-backed document implementation](development/file-backed-documents.md).
- The [paradigms note](spec/feature/vertical-time-tabs/2026-0828-paradigms.md) carries the parked questions, including the durable tab mapping that ADR-0011 section 6 requires before a second paradigm may ship. They stay parked until a second paradigm is wanted.
- [ADR-0025](adr/0025-block-revision-history.md) (block revision history) is still proposed. It anchors the undo work already landed and is the next decision to settle when block level history is picked up again.

## Completed milestones

### [Editing rhythm and the time rail](https://github.com/onetimesecret/macos/milestone/4)

**Goal:** land the refinements deferred out of the sync milestone, plus the standing judgment calls the sync work surfaced: a writing rhythm that stays safe beside other devices, time rail reading polish for vertical tabs mode, and TTL semantics once the page clock stopped standing in for a link's lifetime.

- [#131 Time rail: word labels and a faint minimap background](https://github.com/onetimesecret/macos/issues/131)
- [#132 Adopt Loro's UndoManager before remote ops land in live documents](https://github.com/onetimesecret/macos/issues/132)
- [#133 Weigh the pause research at word, sentence, and paragraph boundaries](https://github.com/onetimesecret/macos/issues/133)
- [#145 Finish ADR-0011 and settle the link default TTL](https://github.com/onetimesecret/macos/issues/145)
- [#146 Implement ADR-0011: ceiling default rung, grace boundary snap, grace setting](https://github.com/onetimesecret/macos/issues/146)

[#139 Remove the page-to-link TTL coupling that ADR-0026 retires](https://github.com/onetimesecret/macos/issues/139) was tracked outside the milestone because it was blocked until ADR-0011 named the link default. It landed in PR 149 once #146 had merged, so the milestone's TTL goal is met in full.

Decisions: [ADR-0011](adr/0011-ttl-choices.md) (TTL rungs are intuitive durations at the surface's tempo; the default rung is the ceiling, a deadline snaps to a clock boundary at creation, and a link's default is a fixed seven days) and [ADR-0026](adr/0026-link-lifetime-is-independent-of-page-lifetime.md) (a link's lifetime is not the page's lifetime). The undo work is anchored on [ADR-0025](adr/0025-block-revision-history.md), still proposed. The pause weighing lives in [the pause boundaries note](spec/feature/block-revisions/2026-0901-pause-boundaries.md).

### [Multi device sync](https://github.com/onetimesecret/macos/milestone/3)

**Goal:** a user's pages reach their second machine through a relay that can never read them, off until it is turned on, with the pad still working when there is no account and no network.

- [#92 Reconcile the not a sync service doctrine with the relay ADR-0013 licenses](https://github.com/onetimesecret/macos/issues/92)
- [#93 ADR-0021: multi device sync over a blind relay](https://github.com/onetimesecret/macos/issues/93)
- [#94 Decide how a device joins when no peer is awake](https://github.com/onetimesecret/macos/issues/94)
- [#95 Derive a per GOP key so relay ciphertext dies at the ceremony](https://github.com/onetimesecret/macos/issues/95)
- [#96 There is no delta seam: the document module exports whole snapshots only](https://github.com/onetimesecret/macos/issues/96)
- [#97 Pair devices with their own key exchange, not with the account](https://github.com/onetimesecret/macos/issues/97)
- [#98 Authenticate the account and gate the relay channel](https://github.com/onetimesecret/macos/issues/98)
- [#99 The relay protocol and what the relay is allowed to hold](https://github.com/onetimesecret/macos/issues/99)
- [#100 Decide whose clock expires a page when two devices hold it](https://github.com/onetimesecret/macos/issues/100)
- [#101 Make the compaction ceremony a coordinated protocol event](https://github.com/onetimesecret/macos/issues/101)
- [#102 What sync looks like in the app: enrolment, status, and the off switch](https://github.com/onetimesecret/macos/issues/102)

Decisions: [ADR-0021](adr/0021-multi-device-sync-over-a-blind-relay.md) (multi device sync over a blind relay: the earliest known expiry wins across devices, and a joining device starts at the current key frame) and [ADR-0027](adr/0027-account-auth-gates-the-sync-channel.md) (account auth gates the sync channel).

See the [detailed plan](plans/multi-device-sync.md).

### [Dogfood fixes](https://github.com/onetimesecret/macos/milestone/2)

**Goal:** repair the faults daily dogfood use has surfaced so the pad behaves like a native citizen: menus, focus, Spaces, rendering, and shortcuts.

- [#22 Focus law regressions: new page focus and chip draft TTL expiry](https://github.com/onetimesecret/macos/issues/22)
- [#23 Persistent editor view: undo, IME, and focus race correctness risks](https://github.com/onetimesecret/macos/issues/23)
- [#41 Backdrop rests when clicking the app's own menus, so Edit ▸ Find never fires](https://github.com/onetimesecret/macos/issues/41)
- [#73 Pinned surface captures clicks while invisible over a fullscreen Space](https://github.com/onetimesecret/macos/issues/73)
- [#74 Cmd-tab return lands on Desktop 1, cannot drag between desktops, flickers on return](https://github.com/onetimesecret/macos/issues/74)
- [#75 Markdown renders inside fenced code blocks, a comment becomes an h1](https://github.com/onetimesecret/macos/issues/75)
- [#76 Project owned, Zed compatible JSON5 keymap as the source of shortcuts](https://github.com/onetimesecret/macos/issues/76)
- [#77 Cmd-n as the default new page shortcut](https://github.com/onetimesecret/macos/issues/77)
- [#78 Hide the ledger, resize arrows, page button, and header dot](https://github.com/onetimesecret/macos/issues/78)

[#79 Explore a page per unit of time with vertical time tabs](https://github.com/onetimesecret/macos/issues/79) is an exploration of a different tab model rather than a fault, so it was deliberately not treated as a blocker for closing this milestone. It carried forward on its own and closed on 25 August 2026.

Decisions: [ADR-0019](adr/0019-the-pad-is-on-every-space.md) (the pad is on every Space, and does not travel between them).

### [Trustworthy persistence](https://github.com/onetimesecret/macos/milestone/1)

**Goal:** unexpired OnetimePad content is durable, recoverable, and visibly saved within the security boundary adopted by the persistence ADR.

- [#44 Decide the persistence contract across crash and macOS restart](https://github.com/onetimesecret/macos/issues/44)
- [#47 Persist unexpired content across abnormal termination and restart](https://github.com/onetimesecret/macos/issues/47)
- [#49 Make restore failure and withheld saves visible in the app](https://github.com/onetimesecret/macos/issues/49)
- [#46 Add Cmd+S force-save with clear save status](https://github.com/onetimesecret/macos/issues/46)
- [#48 Add persistence recovery regression matrix](https://github.com/onetimesecret/macos/issues/48)
- [#51 Transient sysctl failure destroys the live session's staged content](https://github.com/onetimesecret/macos/issues/51)
- [#52 Clipboard copy-out arms no write, so the sent record can be lost](https://github.com/onetimesecret/macos/issues/52)
- [#53 PageModel persistence is untestable: no injectable state directory or credential store](https://github.com/onetimesecret/macos/issues/53)
- [#54 Length-prefix persisted records so a trailing field costs no format break](https://github.com/onetimesecret/macos/issues/54)

Decisions: [ADR-0016](adr/0016-content-persists-across-restart.md) (content persists across restart, TTL is the only destruction mechanism) and [ADR-0017](adr/0017-durable-tabs-expiring-pages.md) (durable tabs, expiring pages). Both supersede parts of [ADR-0012](adr/0012-framing-threat-boundary-and-persistence-model.md).

See the [detailed plan](plans/trustworthy-persistence.md).

## Documentation map

- [`adr/`](adr/): accepted and proposed architectural, security, and product decisions.
- [`dogfood/ABERRATIONS.md`](dogfood/ABERRATIONS.md): raw dogfood observations awaiting triage or a permanent home.
- [`dogfood/DOGFOOD.md`](dogfood/DOGFOOD.md): durable operational guidance for dogfooders and contributors.
- [`plans/`](plans/): detailed, milestone-scoped plans. These link to GitHub issues rather than copying their status.
- [`qa/recovery-matrix.md`](qa/recovery-matrix.md): the seven persistence lifecycle cases, what asserts each one, and when its hardware procedure last ran.
- [`qa/verification-procedures/`](qa/verification-procedures/): the checks CI cannot reach, each with an owner and a dated Results table.
