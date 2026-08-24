# Roadmap

GitHub milestones and issues are the source of truth for delivery status. This document is a short index to current work and durable plans.

## Current milestone

### [Multi device sync](https://github.com/onetimesecret/macos/milestone/3)

**Goal:** a user's pages reach their second machine through a relay that can never read them, off until it is turned on, with the pad still working when there is no account and no network.

- [#92 Reconcile the not a sync service doctrine with the relay ADR-0013 licenses](https://github.com/onetimesecret/macos/issues/92)
- [#93 ADR-0020: multi device sync over a blind relay](https://github.com/onetimesecret/macos/issues/93)
- [#94 Decide how a device joins when no peer is awake](https://github.com/onetimesecret/macos/issues/94)
- [#95 Derive a per GOP key so relay ciphertext dies at the ceremony](https://github.com/onetimesecret/macos/issues/95)
- [#96 There is no delta seam: the document module exports whole snapshots only](https://github.com/onetimesecret/macos/issues/96)
- [#97 Pair devices with their own key exchange, not with the account](https://github.com/onetimesecret/macos/issues/97)
- [#98 Authenticate the account and gate the relay channel](https://github.com/onetimesecret/macos/issues/98)
- [#99 The relay protocol and what the relay is allowed to hold](https://github.com/onetimesecret/macos/issues/99)
- [#100 Decide whose clock expires a page when two devices hold it](https://github.com/onetimesecret/macos/issues/100)
- [#101 Make the compaction ceremony a coordinated protocol event](https://github.com/onetimesecret/macos/issues/101)
- [#102 What sync looks like in the app: enrolment, status, and the off switch](https://github.com/onetimesecret/macos/issues/102)

See the [detailed plan](plans/multi-device-sync.md).

## Completed milestones

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

[#79 Explore a page per unit of time with vertical time tabs](https://github.com/onetimesecret/macos/issues/79) remains open. It is an exploration of a different tab model rather than a fault, so it was deliberately not treated as a blocker for closing this milestone, and it carries forward on its own.

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
- [`dogfood/ABERRATIONS.md`](dogfood/ABERRATIONS.md): raw dogfood observations awaiting triage or promotion.
- [`dogfood/DOGFOOD.md`](dogfood/DOGFOOD.md): durable operational guidance for dogfooders and contributors.
- [`plans/`](plans/): detailed, milestone-scoped plans. These link to GitHub issues rather than copying their status.
- [`qa/recovery-matrix.md`](qa/recovery-matrix.md): the seven persistence lifecycle cases, what asserts each one, and when its hardware procedure last ran.
- [`qa/verification-procedures/`](qa/verification-procedures/): the checks CI cannot reach, each with an owner and a dated Results table.
