#!/usr/bin/env bash
# Package the app as a real .app bundle: dist/OnetimePad.app.
# A bare `swift run` binary has no CFBundleIdentifier, so macOS cannot
# address it: TCC grants don't stick, per-app pickers cannot list it,
# and LaunchServices registers it as a nameless process. The bundle is
# what makes the app a citizen of the permission system.
#
# This is the packaging engine; the entry points are scripts/dev.sh
# (debug, launched from dist/) and scripts/install.sh (release,
# installed to /Applications).
#
# Prereq: scripts/build-core.sh has produced the xcframework.
#
# --debug builds the debug configuration, which always offers the
# Settings switch that lifts the surface's capture exclusion. A release
# build offers the same switch only when launched with
# COMPANION_ALLOW_CAPTURE set, which also seeds it on. `open` does not
# forward the caller's environment; pass the variable explicitly, and to
# either configuration:
#   open --env COMPANION_ALLOW_CAPTURE=1 dist/OnetimePad.app
#   open --env COMPANION_ALLOW_CAPTURE=1 /Applications/OnetimePad.app
# Debug builds get a .debug bundle id so a dev instance and the
# installed copy can coexist without contending for the menu bar,
# defaults, keychain items, and state (ADR-0012).
#
# Signing: ad-hoc by default; set CODESIGN_IDENTITY to a real
# certificate for an identity that survives rebuilds. (The Settings
# window saves an API token to the Keychain, so ad-hoc identity churn
# means TCC grants reset and the Keychain re-confirms access to the
# stored items on every rebuild.) Carrying
# scripts/Companion.entitlements takes a real identity AND an embedded
# provisioning profile (PROVISIONING_PROFILE); every other build omits
# it and runs the documented login keychain fallback.
#
# Before signing, the assembled bundle is hashed into
# dist/OnetimePad.presig.sha256, the reproducible pre-signature
# artifact ADR-0012 publishes.
set -euo pipefail
cd "$(dirname "$0")/.."

# If scripts/local.env exists it is the source of truth for CODESIGN_IDENTITY.
# Sourcing sits inside an if so a local.env whose final statement returns
# non zero fails here with a message instead of killing the script silently.
if [[ -f scripts/local.env ]]; then
  source scripts/local.env || { echo "failed to source scripts/local.env" >&2; exit 1; }
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package-app.sh must run on macOS (needs swift + codesign)." >&2
  exit 1
fi

CONFIG=release
if [[ $# -gt 1 ]]; then
  echo "too many arguments (the only flag is --debug)" >&2
  exit 1
elif [[ "${1:-}" == "--debug" ]]; then
  CONFIG=debug
elif [[ -n "${1:-}" ]]; then
  echo "unknown argument: $1 (the only flag is --debug)" >&2
  exit 1
fi

if [[ ! -d bindings/CompanionCore.xcframework ]]; then
  echo "bindings/CompanionCore.xcframework is missing; run scripts/build-core.sh first." >&2
  exit 1
fi

# The bundle version is stamped from the same source companion_version()
# is baked from. Same source, not same build: a stale xcframework keeps
# the old string until build-core.sh reruns.
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' crates/ffi/Cargo.toml | head -n1)"
if [[ -z "$VERSION" ]]; then
  echo "could not read version from crates/ffi/Cargo.toml" >&2
  exit 1
fi

echo "==> swift build -c $CONFIG --product OnetimePad"
swift build --package-path shell -c "$CONFIG" --product OnetimePad
BIN="$(swift build --package-path shell -c "$CONFIG" --show-bin-path)/OnetimePad"

# ADR-0018: test seams are compiled out of release artifacts, and the
# claim is checked by machine here rather than trusted. The check reads
# the linked binary, not the static library, because the binary is the
# artifact this script ships (and because the library's thin-LTO
# members defeat nm). A debug bundle may carry the seams: it links the
# dev xcframework on purpose so `swift test` and dev.sh share one
# build.
if [[ "$CONFIG" == "release" ]]; then
  echo "==> Verifying no test seams in the release binary (ADR-0018)"
  # One pattern per gated seam: the check is worth nothing if a seam
  # added later is not named here, so add the symbol when you add the
  # export.
  if SEAM="$(nm -gU "$BIN" 2>/dev/null |
      grep -o -E '_companion_(new_ephemeral|test_age_ms)$' | head -n 1)"; then
    if [[ -n "$SEAM" ]]; then
      echo "release binary exports ${SEAM#_}, a test-only seam" >&2
      echo "(ADR-0018): bindings/ holds the dev xcframework. Rebuild the release" >&2
      echo "shape with scripts/build-core.sh (no flags) and package again." >&2
      exit 1
    fi
  fi
fi

APP=dist/OnetimePad.app
echo "==> Assembling $APP ($VERSION, $CONFIG)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OnetimePad"
# The brand art the menu bar item is drawn from (CompanionKit's
# LogoMark, which looks here first). SwiftPM's own resource bundle is
# not what ships: its accessor searches beside the .app, so the app
# carries the asset in Contents/Resources where Bundle.main finds it.
cp shell/Sources/CompanionKit/Resources/onetime-logo-v3-xl.svg "$APP/Contents/Resources/"
# The bundled default keymap, which is the authoritative list of what
# the keyboard does (issue #76, docs/development/about-the-keymap.md).
# Here for the same reason as the logo mark: Bundle.main is where the
# app looks first, and a bundle without this file has no shortcuts at
# all.
cp shell/Sources/CompanionKit/Resources/default-keymap.json "$APP/Contents/Resources/"
cp shell/OnetimePad-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Use whatever OnetimePad icon is already sitting in dist/icons/ (the
# most recently rendered one), so a custom scripts/build-icons.sh run
# right before packaging survives instead of being overwritten by a
# forced rebuild back to the standard shade. Only build the standard
# icon when none exists yet.
ICON="$(ls -t dist/icons/OnetimePad*.icns 2>/dev/null | head -n1 || true)"
if [[ -z "$ICON" ]]; then
  scripts/build-icons.sh
  ICON="dist/icons/OnetimePad.icns"
fi
echo "==> App icon: $ICON"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

# Dogfood builds carry the commit in CFBundleVersion so "which build am
# I on" has a one-glance answer. An uncommitted tree is part of the
# answer: the SHA alone would claim a build the repo cannot reproduce.
# Outside a git checkout the plain version stands.
if SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
  git diff --quiet HEAD 2>/dev/null || SHA="$SHA.dirty"
  plutil -replace CFBundleVersion -string "$VERSION+$SHA" "$APP/Contents/Info.plist"
fi

if [[ "$CONFIG" == "debug" ]]; then
  # A distinct identity for the dev instance, so it and the installed
  # copy read as separate apps to macOS and to the eye.
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.debug" "$APP/Contents/Info.plist"
  BUNDLE_NAME="$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")"
  plutil -replace CFBundleName -string "$BUNDLE_NAME Dev" "$APP/Contents/Info.plist"
fi

# The published artifact is the bundle as assembled, before any
# signature touches it. Hash every regular file by relative path and
# content: relative so the digest reproduces from a different checkout
# directory, and LC_ALL=C so the sort order is byte order rather than
# whatever the caller's locale collates to.
DIGEST_FILE="dist/$(basename "$APP" .app).presig.sha256"
echo "==> Pre-signature digest"
DIGEST="$(cd "$APP" && LC_ALL=C find . -type f -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | cut -d ' ' -f 1)"
if [[ -z "$DIGEST" ]]; then
  echo "pre-signature digest came out empty" >&2
  exit 1
fi
printf '%s  %s\n' "$DIGEST" "${APP##*/}" > "$DIGEST_FILE"
echo "$DIGEST  ${APP##*/} (pre-signature, $DIGEST_FILE)"

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
if [[ "$IDENTITY" == "-" ]]; then
  # An ad-hoc signature has no Team ID, so it cannot carry
  # keychain-access-groups. Expected for local builds, not a failure:
  # the credentials layer sees errSecMissingEntitlement and falls back
  # (ADR-0012).
  echo "    warning: ad-hoc signature, so scripts/Companion.entitlements is not applied." >&2
  echo "    warning: the data protection keychain is unavailable in this build; the" >&2
  echo "    warning: credentials layer falls back to the file based login keychain." >&2
  echo "    warning: set CODESIGN_IDENTITY to a real certificate for the modern store." >&2
  codesign --force --sign "$IDENTITY" "$APP"
else
  # $(AppIdentifierPrefix) is an Xcode build setting, and codesign does
  # not expand it. Left literal it signs in an access group that cannot
  # exist. Substitute the signing certificate's Team ID (the OU field)
  # at sign time, trailing dot included, matching Xcode.
  TEAM_ID="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Za-z0-9]\{6,\}\).*/\1/p' | head -n1)"
  if [[ -z "$TEAM_ID" ]]; then
    echo "    warning: could not read a Team ID from the signing certificate, so" >&2
    echo "    warning: scripts/Companion.entitlements is not applied and the data" >&2
    echo "    warning: protection keychain stays unavailable (login keychain fallback)." >&2
    codesign --force --sign "$IDENTITY" "$APP"
  else
    # A Team ID is still not enough. keychain-access-groups sits on
    # AMFI's restricted list: the bundle must also embed a provisioning
    # profile that authorizes the group, or launchd refuses to spawn
    # the app entirely (amfid -413, "No matching profile found"). So
    # the entitlement is applied only when PROVISIONING_PROFILE points
    # at a profile; see scripts/local.env.example for how to mint one.
    if [[ -n "${PROVISIONING_PROFILE:-}" && ! -f "$PROVISIONING_PROFILE" ]]; then
      echo "PROVISIONING_PROFILE is set but no file exists at: $PROVISIONING_PROFILE" >&2
      exit 1
    fi
    if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
      # The profile is machine-bound signing material, embedded after
      # the pre-signature digest on purpose: hashing it would make the
      # digest differ per machine.
      cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
      echo "==> embedded provisioning profile: $PROVISIONING_PROFILE"
      # The group follows the bundle's own identifier, read back out of
      # the assembled Info.plist so it already carries any .debug
      # suffix. Hardcoding one id would drop the installed release copy
      # and the .debug dev instance into a single group, and a shared
      # group is a shared keychain: CompanionKit/FormFactor.swift scopes
      # credentialService to the running build's bundle id, and
      # ADR-0012 says the two lanes must not read one another's items.
      SIGNED_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
      ACCESS_GROUP="${TEAM_ID}.${SIGNED_BUNDLE_ID}"
      SIGN_ENTITLEMENTS="$(mktemp -t companion-entitlements)"
      sed -e "s/\$(AppIdentifierPrefix)/${TEAM_ID}./g" \
          -e "s/@BUNDLE_IDENTIFIER@/${SIGNED_BUNDLE_ID}/g" \
          scripts/Companion.entitlements > "$SIGN_ENTITLEMENTS"
      echo "==> entitlements: keychain-access-group $ACCESS_GROUP"
      codesign --force --entitlements "$SIGN_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
      rm -f "$SIGN_ENTITLEMENTS"
    else
      echo "    warning: PROVISIONING_PROFILE is unset, so scripts/Companion.entitlements" >&2
      echo "    warning: is not applied: the keychain-access-groups entitlement needs an" >&2
      echo "    warning: embedded provisioning profile, and claiming it without one" >&2
      echo "    warning: produces an app AMFI refuses to launch. The data protection" >&2
      echo "    warning: keychain is unavailable in this build; the credentials layer" >&2
      echo "    warning: falls back to the file based login keychain. See" >&2
      echo "    warning: scripts/local.env.example for how to mint a profile." >&2
      codesign --force --sign "$IDENTITY" "$APP"
    fi
  fi
fi

echo "==> Verifying"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"

echo "Built $APP. Launch with: open $APP"
