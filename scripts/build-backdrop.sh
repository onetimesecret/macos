#!/usr/bin/env bash
# Package the background-surface form factor as a real .app bundle:
# dist/CompanionBackdrop.app. The sibling of build-app.sh (ADR-0010) —
# same reasons a bundle exists at all (a bare `swift run` binary has no
# CFBundleIdentifier, so TCC grants and per-app pickers cannot address
# it), same stamping, same signing story.
#
# Prereq: scripts/build-core.sh has produced the xcframework.
#
# --debug builds the debug configuration — the only build that can lift
# the surface's capture exclusion (COMPANION_ALLOW_CAPTURE, compiled out
# of release). `open` does not forward the caller's environment; pass
# the variable explicitly:
#   open --env COMPANION_ALLOW_CAPTURE=1 dist/CompanionBackdrop.app
# Debug builds get a .dev bundle id so a dev instance and the installed
# copy can coexist without contending for the menu bar, defaults, and
# state.
#
# Signing: ad-hoc by default; set CODESIGN_IDENTITY to a real
# certificate for an identity that survives rebuilds. (The backdrop
# stores nothing in the Keychain, so identity churn costs less here
# than it does for the panel app — TCC grants still reset.)
set -euo pipefail
cd "$(dirname "$0")/.."

# If scripts/local.env exists it is the source of truth for CODESIGN_IDENTITY.
# Sourcing sits inside an if so a local.env whose final statement returns
# non zero fails here with a message instead of killing the script silently.
if [[ -f scripts/local.env ]]; then
  source scripts/local.env || { echo "failed to source scripts/local.env" >&2; exit 1; }
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-backdrop.sh must run on macOS (needs swift + codesign)." >&2
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

echo "==> swift build -c $CONFIG --product CompanionBackdrop"
swift build --package-path shell -c "$CONFIG" --product CompanionBackdrop
BIN="$(swift build --package-path shell -c "$CONFIG" --show-bin-path)/CompanionBackdrop"

APP=dist/CompanionBackdrop.app
echo "==> Assembling $APP ($VERSION, $CONFIG)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CompanionBackdrop"
cp shell/Backdrop-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
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
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.dev" "$APP/Contents/Info.plist"
  BUNDLE_NAME="$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")"
  plutil -replace CFBundleName -string "$BUNDLE_NAME Dev" "$APP/Contents/Info.plist"
fi

echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "==> Verifying"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"

echo "Built $APP — launch with: open $APP"
