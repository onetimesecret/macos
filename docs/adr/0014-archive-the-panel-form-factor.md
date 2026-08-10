# ADR-0014: Archive the panel form factor

- **Status:** accepted
- **Date:** 2026-08-07

## Context

ADR-0010 made form factors sibling executable targets over the one
core, and named extraction into a shared target as what happens when a
sibling graduates. The background surface graduated twice over: the
persistence work moved the seam wrapper into `CompanionKit`, and the
parity amendment moved the pages, tabs, chips, ledger and exit ramp.
By the ADR-0012 branch the surface (OnetimePad) was the daily driver,
and the panel (`CompanionApp`) held nothing of its own beyond its
window and posture.

Two apps cost what two apps cost: two build scripts, two bundles to
sign and install, two entries in every verification procedure, and a
review surface that reads as double. Nobody was running the panel.

## Decision

Archive the panel. `Sources/CompanionApp`, its Info.plist, and
`scripts/build-app.sh` are removed from the tree; git history is the
archive, and this ADR is the pointer to it. No `archive/` directory,
no commented-out target: dead code that stays visible gets read, and
code that gets read gets trusted.

The build lane consolidates around the one app:

- `scripts/dev.sh` builds the debug bundle (`.debug` bundle id, "Dev"
  display name, ADR-0012) and launches it from `dist/`.
- `scripts/install.sh` builds the release bundle, signs it, and
  installs it to `/Applications` (the dogfood channel).
- `scripts/package-app.sh` (previously `build-backdrop.sh`) is the
  packaging engine both entry points call; `build-core.sh`,
  `build-icons.sh`, and `quit-app.sh` stay as helpers.

The app's name is OnetimePad, and with the panel gone the name reaches
everywhere renaming is free: the executable target
(`Sources/OnetimePad`), its test target (`Tests/OnetimePadTests`), the
identity sheet (`shell/OnetimePad-Info.plist`), CFBundleExecutable,
and the assembled bundle (`dist/OnetimePad.app`, installed as
`OnetimePad.app`). "CompanionBackdrop" survives only where it was
never a name: the bundle id stays
`com.onetimesecret.companion.backdrop`, because macOS keys the state
directory, Keychain items, the keychain access group, and TCC grants
off the id, so renaming the id would orphan all four for every
existing install. The unified log subsystem carries the same string
for the same reason. Ids are infrastructure; names are paint.
`scripts/install.sh` retires a legacy `CompanionBackdrop.app` left in
the install destination, quitting it gracefully before removing it.

## Consequences

- `CompanionKit` remains the shared layer, and ADR-0010's sibling
  mechanism remains the path for a future form factor. Archiving the
  panel retires an instance, not the architecture.
- The panel-specific ADRs (0004, 0005) and the spec's panel sections
  describe a form factor that no longer builds. They stand as records;
  the interaction model they encode lives on in CompanionKit's
  surfaces.
- Restoring the panel is a `git revert` of the removal plus a target
  entry in Package.swift, not an excavation.
