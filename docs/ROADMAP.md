# Roadmap

GitHub milestones and issues are the source of truth for delivery status. This document is a short index to current work and durable plans.

## Current milestone

### [Dogfood fixes](https://github.com/onetimesecret/macos/milestone/2)

**Goal:** repair the faults daily dogfood use has surfaced so the pad behaves like a native citizen: menus, focus, Spaces, rendering, and shortcuts.

- [#41 Backdrop rests when clicking the app's own menus, so Edit ▸ Find never fires](https://github.com/onetimesecret/macos/issues/41)
- [#22 Focus law regressions: new page focus and chip draft TTL expiry](https://github.com/onetimesecret/macos/issues/22)
- [#23 Persistent editor view: undo, IME, and focus race correctness risks](https://github.com/onetimesecret/macos/issues/23)
- [#73 Pinned surface captures clicks while invisible over a fullscreen Space](https://github.com/onetimesecret/macos/issues/73)
- [#74 Cmd-tab return lands on Desktop 1, cannot drag between desktops, flickers on return](https://github.com/onetimesecret/macos/issues/74)
- [#75 Markdown renders inside fenced code blocks, a comment becomes an h1](https://github.com/onetimesecret/macos/issues/75)
- [#76 Project owned, Zed compatible JSON5 keymap as the source of shortcuts](https://github.com/onetimesecret/macos/issues/76)
- [#77 Cmd-n as the default new page shortcut](https://github.com/onetimesecret/macos/issues/77)

## Completed milestones

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
