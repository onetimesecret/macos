#!/usr/bin/env bash
# Package the shell as a real .app bundle: dist/CompanionApp.app.
#
# A bare `swift run` binary has no CFBundleIdentifier, so macOS cannot
# address it: TCC grants don't stick, per-app screen-capture pickers
# can't list it, and LaunchServices registers it as a nameless
# UIElement. The bundle (shell/Info.plist: com.onetimesecret.companion)
# is what makes the app a citizen of the permission system.
#
# Prereq: scripts/build-core.sh has produced the xcframework.
#
# --debug builds the debug configuration — the only build that can lift
# the window's capture exclusion (COMPANION_ALLOW_CAPTURE, compiled out
# of release). `open` does not forward the caller's environment; pass
# the variable explicitly:
#   open --env COMPANION_ALLOW_CAPTURE=1 dist/CompanionApp.app
# Debug builds get a .debug bundle id so a dev instance and the
# installed copy can coexist without contending for the menu bar,
# defaults, keychain items, and state (ADR-0012).
#
# Signing: ad-hoc by default. Enough for local TCC and pickers, but the
# code identity changes on every rebuild, so TCC grants reset AND the
# Keychain re-confirms access to stored items (the API token, the state
# key) each time. Set CODESIGN_IDENTITY to a real certificate for an
# identity that survives rebuilds. Only a real identity can carry
# scripts/Companion.entitlements, so only a real identity reaches the
# data protection keychain; ad-hoc builds run the documented fallback.
#
# Before signing, the assembled bundle is hashed into
# dist/CompanionApp.presig.sha256. That digest is the reproducible
# pre-signature artifact ADR-0012 publishes: signing timestamps and
# stapled tickets make the shipped .app non bit identical, the unsigned
# payload does not.
set -euo pipefail
cd "$(dirname "$0")/.."

# If scripts/local.env exists it is the source of truth for CODESIGN_IDENTITY.
# Sourcing sits inside an if so a local.env whose final statement returns
# non zero fails here with a message instead of killing the script silently.
if [[ -f scripts/local.env ]]; then
  source scripts/local.env || { echo "failed to source scripts/local.env" >&2; exit 1; }
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-app.sh must run on macOS (needs swift + codesign)." >&2
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
  echo "bindings/CompanionCore.xcframework is missing — run scripts/build-core.sh first." >&2
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

echo "==> swift build -c $CONFIG"
swift build --package-path shell -c "$CONFIG"
BIN="$(swift build --package-path shell -c "$CONFIG" --show-bin-path)/CompanionApp"

APP=dist/CompanionApp.app
echo "==> Assembling $APP ($VERSION, $CONFIG)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CompanionApp"
cp shell/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
scripts/build-icons.sh
cp dist/icons/CompanionApp.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

# Dogfood builds carry the commit in CFBundleVersion so "which build am
# I on" has a one-glance answer (the tray menu and the About panel both
# read it). An uncommitted tree is part of the answer: the SHA alone
# would claim a build the repo cannot reproduce. Outside a git checkout
# the plain version stands.
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

# scripts/Companion.entitlements declares keychain-access-groups, which
# is what lets the credentials layer reach the data protection keychain
# (ADR-0012). It holds no XML comments on purpose: the AMFI parser that
# reads entitlements at signing time rejects them outright.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
if [[ "$IDENTITY" == "-" ]]; then
  # An ad-hoc signature has no Team ID, so it cannot carry
  # keychain-access-groups. This is expected for local builds, not a
  # failure: the credentials layer sees errSecMissingEntitlement and
  # falls back (ADR-0012).
  echo "    warning: ad-hoc signature, so scripts/Companion.entitlements is not applied." >&2
  echo "    warning: the data protection keychain is unavailable in this build; the" >&2
  echo "    warning: credentials layer falls back to the file based login keychain." >&2
  echo "    warning: set CODESIGN_IDENTITY to a real certificate for the modern store." >&2
  codesign --force --sign "$IDENTITY" "$APP"
else
  # $(AppIdentifierPrefix) is an Xcode build setting, and codesign does
  # not expand it. Left literal it signs in an access group that cannot
  # exist, so SecItemAdd still fails with errSecMissingEntitlement and
  # the entitlements file buys nothing. Substitute the signing
  # certificate's Team ID (the OU field) at sign time. The prefix
  # carries a trailing dot, matching Xcode.
  TEAM_ID="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Za-z0-9]\{6,\}\).*/\1/p' | head -n1)"
  if [[ -z "$TEAM_ID" ]]; then
    echo "    warning: could not read a Team ID from the signing certificate, so" >&2
    echo "    warning: scripts/Companion.entitlements is not applied and the data" >&2
    echo "    warning: protection keychain stays unavailable (login keychain fallback)." >&2
    codesign --force --sign "$IDENTITY" "$APP"
  else
    SIGN_ENTITLEMENTS="$(mktemp -t companion-entitlements)"
    sed "s/\$(AppIdentifierPrefix)/${TEAM_ID}./g" scripts/Companion.entitlements \
      > "$SIGN_ENTITLEMENTS"
    echo "==> entitlements: keychain-access-group ${TEAM_ID}.com.onetimesecret.companion"
    codesign --force --entitlements "$SIGN_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    rm -f "$SIGN_ENTITLEMENTS"
  fi
fi

echo "==> Verifying"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"

echo "Built $APP — launch with: open $APP"
