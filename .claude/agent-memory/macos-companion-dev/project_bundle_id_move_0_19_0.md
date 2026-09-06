---
name: bundle-id-move-0-19-0
description: The bundle id moved to com.onetimesecret.pad (dev lane dev.onetimesecret.pad) in 0.19.0 on 2026-09-05; the dev lane is recognised by exact name, CI gates both packaged ids by name, and the legacy .debug suffix survives only in ADR decision text and old release notes
metadata:
  type: project
---

On 2026-09-05 (dogfood phase 4, item 1) the release id became
`com.onetimesecret.pad` and the dev lane `dev.onetimesecret.pad`; the
legacy `com.onetimesecret.companion.backdrop` and its `.debug` suffix
are gone. No migration for state, drafts, ledger or Keychain items, by
the maintainer's decision.

**Why:** the old id was a working title's lineage. The dev id is a
different prefix on purpose, so `isDevLane` is an exact match against
`FormFactor.devBundleIdentifier` and `resolvedBundleIdentifier` names
its identifiers instead of counting dots (the old comment said a future
change would need exactly that).

**How to apply:**
- Three places must agree on the dev id and none is derived from the
  others: `FormFactor.devBundleIdentifier`, `DEV_BUNDLE_ID` in
  `scripts/package-app.sh`, and the two `case` gates in
  `.github/workflows/ci.yml`. `BundleDeclarationTests` pins the first
  two together; CI is only pinned by itself. Check all three when
  touching any one.
- A log predicate that wants both lanes can no longer use BEGINSWITH;
  the docs use `subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad"}`.
- `.debug` still appears in ADR-0012 and ADR-0014 decision text (each
  carries an inline superseded note), in DOGFOOD.md's two older reset
  sections, in old CHANGELOG entries and in ABERRATIONS.md. Those are
  historical on purpose; do not sweep them again.
- The panel's `com.onetimesecret.companion` and the Rust
  `credentials::SERVICE` default are unchanged and are not cruft.
