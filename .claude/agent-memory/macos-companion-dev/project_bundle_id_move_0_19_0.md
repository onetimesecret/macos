---
name: bundle-id-move-0-19-0
description: Three lane ids since 2026-09-29: com.onetimesecret.pad for App Store builds (staging, production), dev.onetimesecret.pad for the local install, dev.onetimesecret.pad.debug for debug builds; each recognised by exact name, CI gates the two CI-built ids by name
metadata:
  type: project
---

On 2026-09-05 (dogfood phase 4, item 1) the release id became
`com.onetimesecret.pad` and the dev lane `dev.onetimesecret.pad`; the
legacy `com.onetimesecret.companion.backdrop` and its `.debug` suffix
are gone. On 2026-09-29 the maintainer reassigned the lanes:
`com.onetimesecret.pad` is for staging (TestFlight) and production only,
the local lane (`scripts/install.sh`, release) runs as
`dev.onetimesecret.pad` (`FormFactor.localBundleIdentifier`), and the
dev lane (`--debug`) as `dev.onetimesecret.pad.debug`
(`FormFactor.devBundleIdentifier`). Neither move migrated state, drafts,
ledger or Keychain items, by the maintainer's decision.

**Why:** the maintainer's frame is that `com.*` is for what ships
through the App Store and `dev.*` is for every development signed
build. `isDevLane` is an exact match against
`FormFactor.devBundleIdentifier` and `resolvedBundleIdentifier` names
its identifiers instead of counting dots, which is what makes the
`.debug` id safe although it extends the local id.

**How to apply:**
- Seven places name the ids and none is derived from the others:
  `shell/OnetimePad-Info.plist` (App Store id),
  `FormFactor.localBundleIdentifier` and `devBundleIdentifier`,
  `LOCAL_BUNDLE_ID` and `DEV_BUNDLE_ID` in `scripts/build-lanes.sh`,
  and the two `case` gates in `.github/workflows/ci.yml` (debug job:
  `.debug`; release packaging job: the local id, since CI cannot sign an
  App Store build). `BundleDeclarationTests` pins the plist, the
  constants and the manifest together; the two CI strings are
  independent copies pinned only by themselves, and fail loudly rather
  than quietly. Check all seven when touching any one.
- `package-app.sh` writes `BUILD_BUNDLE_ID` into every bundle whose lane
  id differs from the production id; the " Dev" name and dev icon stay
  keyed on the debug configuration.
- A log predicate for every lane lists all three:
  `subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"}`.
- The retired `.debug` suffix on the shipping id still appears in
  ADR-0012 and ADR-0014 decision text (each carries an inline superseded
  note), in DOGFOOD.md's two older reset sections, in old CHANGELOG
  entries and in ABERRATIONS.md. Those are historical on purpose; do not
  sweep them again.
- The panel's `com.onetimesecret.companion` and the Rust
  `credentials::SERVICE` default are unchanged and are not cruft.
