# State of the Onion, 2026-08-28

One day on from the first entry, and the picture is the same on the client side and clearer on the server side. The day's work was decisions, not code: where the relay lives, who issues its tokens, and where its ticket now sits. See `README.md` for what this document is, and the 2026-08-27 entry for the snapshot this one corrects.

## What changed today

**The relay went private.** The blind relay ticket moved out of the public macos repo to a skunkworks issue, onetimesecret-internal#8, and stays private for now. Yesterday's entry said the server side was "filed in the onetimesecret repo, per #99". That line is superseded: the interface still lives in the public #99, but the build lives in internal#8. The plan doc now points there (`docs/plans/multi-device-sync.md`).

**The relay has a home: Fly.io Machines.** It runs as a separate service, not inside the OTS app, so it can iterate on its own cadence. Sprites cover hibernation between syncs if we want it. The choice follows from the shape ADR-0021 already set: the relay is a blind fanout broker with a bounded, non-durable one-GOP buffer plus live connections, not a datastore. It holds nothing worth persisting, because a device offline past one GOP rejoins at the current key frame and never asks for history. Turso was rejected as a durable database solving storage we do not have and giving no fanout; Bunny Scripts as short-lived edge functions wrong for long-lived connections.

**Auth has a provider: onetimesecret.dev.** OTS is its own OAuth authorization server. The v0.27 release, staged at onetimesecret.dev, adds OAuth via rodauth-oauth, and that is what #98's client flow talks to. The client half is already built and spec first: authorization code with PKCE in the system browser on a loopback redirect (RFC 8252), refresh rotation with reuse detection, a 90-day idle window (`crates/sync/src/oauth.rs`, `docs/spec/feature/sync/account-auth.md`). PASETO stays a format-agnostic phase 2; if it lands, the flow and lifetimes do not move. The spec now names the provider above section 1.

## Where that leaves the two open issues

- **#98** cleanly splits. The client half is done and merged. What remains is the provider half, and it is not macos-side: it is Rodauth-OAuth on OTS core, riding the v0.27 release. The relay validates what OTS issued and mints nothing of its own.
- **#102** is unchanged and still the last mile: enrolment, sync status, and the off switch, with the app indistinguishable from today's while sync is off.

## Still looming, still unscheduled

Both carry forward from yesterday without movement:

- **TestFlight and distribution** (`docs/plans/from-here-to-testflight.md`): sandbox, entitlements, a Distribution identity, a provisioning profile, a signed `.pkg`, an App Store Connect record. The keychain round trip under sandbox is the single highest-risk point to verify on device. Not yet a milestone.
- **Block versioning** (DOGFOOD.md, commit `2e58158`): make the created and modified stamp a clickable element that reveals a block's prior versions, plus a blur and opacity setting when the pad drops to backdrop. It leans on the block-metadata display that just shipped and the ADR-0013 provenance model. Not yet an issue.

Net: milestone 3's client side is effectively complete. The remaining sync work is the relay on Fly and the OAuth provider on OTS v0.27, both now off the public macos board. TestFlight and block-version history are the next two things that will need a milestone once sync closes.
