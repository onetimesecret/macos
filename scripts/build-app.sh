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
#
# Signing: ad-hoc by default. Enough for local TCC and pickers, but the
# code identity changes on every rebuild, so TCC grants reset AND the
# Keychain re-confirms access to stored items (the API token, the state
# key) each time. Set CODESIGN_IDENTITY to a real certificate for an
# identity that survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

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
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

echo "==> codesign (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "==> Verifying"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"

echo "Built $APP — launch with: open $APP"
