# State of the Onion, 2026-08-27

Captured verbatim from the stock-take taken on this date, before the relay ticket moved to a private repo. Frozen as written; see the 2026-08-28 entry for what changed. See `README.md` for what this document is.

---

## Current state

Main is at `3602a66`, well past the last handoff (`285043d`). Two work streams have been running in parallel, and both landed a lot since 08-25.

**Milestone 3 — Multi device sync** (milestone/3, the active one). Design phase is fully closed and pass 3 implementation has landed on main, not just been planned:

- Closed: #92, #93 (ADR-0021 accepted), #94, #95 (per-GOP key), #96 (delta seam), #97 (pairing), #99 (relay protocol), #100 (expiry clock), #101 (coordinated compaction).
- New code on main: `crates/sync/` (`oauth`, `relay`, `envelope`, `pad`, `loopback`, `pairing`, sans-IO client half) wired into FFI via `sync_driver.rs`, `sync_session.rs`, `pairing.rs`. Specs written: `docs/spec/feature/sync/{account-auth,relay-protocol,README}.md`. PR #123 (`fix/sync-key-isolation`) merged.
- **Open, remaining: 2 issues.**
  - **#98** — account auth + relay channel gate (OAuth 2.0 + PKCE loopback, RFC 8252). The `oauth` module and spec exist; this closes out the auth/gating integration.
  - **#102** — the app-facing UI: enrolment, sync status, and the off switch. Pass 5 work, the last mile. With sync off the app must be indistinguishable from today's.
- Server side of the relay is filed in the `onetimesecret` repo (per #99), not here.

**Editor polish stream** (dogfood-driven, outside the sync milestone). Recently merged: lists with depth/automation, a code-ink tokenizer + syntax highlighting, block metadata display, markdown link affordance, fence stamp coalescing. Decisions recorded as ADR-0022 (fence coalescing), ADR-0023 (⌘-click link opens), ADR-0024 (caret-only automation, display-only color). Dogfood milestone 2 closed except #79 (vertical time tabs), which carries forward as an exploration, not a blocker.

**Uncommitted:** one-line change in `InkEditorView.swift` (`classifiedKind` guard swapped `let storage =` for `!= nil` since the binding was unused). Trivial, yours or a leftover.

## Recent focus

The last few days shifted from sync *doctrine and ADRs* to sync *code* (the sans-IO sync crate + FFI seams), running alongside a burst of editor rendering features (lists, highlighting, block metadata) driven by daily dogfood use.

## Coming up

- **Finish milestone 3:** #98 and #102, plus the relay server in the other repo. That completes multi-device sync end to end.
- **TestFlight / distribution** (`docs/plans/from-here-to-testflight.md`): sandbox, entitlements, Distribution identity, provisioning profile, signed `.pkg`, App Store Connect. Not yet a milestone or issues. Keychain round-trip under sandbox is flagged as the single highest-risk integration point to verify on device.
- **Block versioning** (added to DOGFOOD.md in `2e58158`, unscheduled): make the created→modified block stamp a clickable element revealing prior versions of the block. Interacts with the block-metadata display just shipped and the ADR-0013 provenance model. Same note asks for a blur/opacity (0–100) setting when the pad drops to backdrop UI.

Net: sync is close to done (2 issues + external relay), then the two undecided-but-looming tracks are TestFlight distribution and block-version history.
