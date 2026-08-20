# Roadmap

GitHub milestones and issues are the source of truth for delivery status. This document is a short index to current work and durable plans.

## Current milestone

### [Trustworthy persistence](https://github.com/onetimesecret/macos/milestone/1)

**Goal:** unexpired OnetimePad content is durable, recoverable, and visibly saved within the security boundary adopted by the persistence ADR.

- [#44 Decide the persistence contract across crash and macOS restart](https://github.com/onetimesecret/macos/issues/44)
- [#47 Persist unexpired content across abnormal termination and restart](https://github.com/onetimesecret/macos/issues/47)
- [#49 Make restore failure and withheld saves visible in the app](https://github.com/onetimesecret/macos/issues/49)
- [#46 Add Cmd+S force-save with clear save status](https://github.com/onetimesecret/macos/issues/46)
- [#48 Add persistence recovery regression matrix](https://github.com/onetimesecret/macos/issues/48)

See the [detailed plan](plans/trustworthy-persistence.md) and [ADR-0012](adr/0012-framing-threat-boundary-and-persistence-model.md).

## Documentation map

- [`adr/`](adr/): accepted and proposed architectural, security, and product decisions.
- [`dogfood/ABERRATIONS.md`](dogfood/ABERRATIONS.md): raw dogfood observations awaiting triage or promotion.
- [`dogfood/DOGFOOD.md`](dogfood/DOGFOOD.md): durable operational guidance for dogfooders and contributors.
- [`plans/`](plans/): detailed, milestone-scoped plans. These link to GitHub issues rather than copying their status.
