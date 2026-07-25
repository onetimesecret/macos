#!/usr/bin/env bash
# The daily dogfood channel: build both apps and install them to
# APP_DEST (default /Applications). The installed copy runs from
# /Applications rather than from .build/ or dist/, so rebuilds in the
# repo never kill it. See scripts/local.env.example for pinning a
# signing identity that lets TCC grants and Keychain access survive
# updates.
#
# --no-launch installs without opening the apps afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

# If scripts/local.env exists it is the source of truth for CODESIGN_IDENTITY.
[[ -f scripts/local.env ]] && source scripts/local.env

NO_LAUNCH=0
if [[ $# -gt 1 ]]; then
  echo "too many arguments (the only flag is --no-launch)" >&2
  exit 1
elif [[ "${1:-}" == "--no-launch" ]]; then
  NO_LAUNCH=1
elif [[ -n "${1:-}" ]]; then
  echo "unknown argument: $1 (the only flag is --no-launch)" >&2
  exit 1
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "WARNING: CODESIGN_IDENTITY is unset, so this install will be ad-hoc" >&2
  echo "signed. TCC grants and Keychain confirmations will reset on every" >&2
  echo "update. See scripts/local.env.example for a stable identity." >&2
fi

# Rebuild the core only when it is stale: missing outright, or older
# than any Rust source or manifest under crates/.
XCF=bindings/CompanionCore.xcframework
if [[ ! -d "$XCF" ]]; then
  echo "==> $XCF is missing; running scripts/build-core.sh"
  scripts/build-core.sh
elif [[ -n "$(find crates -type f \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock \) -newer "$XCF" -print -quit)" ]]; then
  echo "==> crates/ changed since $XCF was built; running scripts/build-core.sh"
  scripts/build-core.sh
fi

echo "==> scripts/build-app.sh"
scripts/build-app.sh
echo "==> scripts/build-backdrop.sh"
scripts/build-backdrop.sh

# Refuse to point the destructive steps below at anything but a real
# absolute destination.
APP_DEST="${APP_DEST-/Applications}"
if [[ -z "$APP_DEST" || "$APP_DEST" != /* ]]; then
  echo "APP_DEST must be a non-empty absolute path (got \"$APP_DEST\")." >&2
  exit 1
fi

# Ask a running installed copy to quit before replacing it. Only the
# graceful AppleScript path runs the quit-time persistence snapshot, so
# we never escalate to signals here; if the app will not quit, we stop
# rather than replace it live.
quit_installed() { # <app name>
  local name="$1"
  local macos_dir="$APP_DEST/$name.app/Contents/MacOS"
  pgrep -f "$macos_dir" >/dev/null || return 0
  local bundle_id
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_DEST/$name.app/Contents/Info.plist")"
  echo "==> Asking $name ($bundle_id) to quit"
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    pgrep -f "$macos_dir" >/dev/null || return 0
    sleep 0.2
  done
  echo "$name is still running from $macos_dir; refusing to replace a live app." >&2
  exit 1
}

install_bundle() { # <app name>
  local name="$1"
  local dest="$APP_DEST/$name.app"
  echo "==> Installing dist/$name.app -> $dest"
  rm -rf "$dest"
  ditto "dist/$name.app" "$dest"
  local version
  version="$(plutil -extract CFBundleShortVersionString raw "$dest/Contents/Info.plist")"
  echo "Installed $name.app $version"
}

for name in CompanionApp CompanionBackdrop; do
  quit_installed "$name"
  install_bundle "$name"
done

if [[ "$NO_LAUNCH" == 0 ]]; then
  echo "==> Launching installed apps"
  open "$APP_DEST/CompanionApp.app"
  open "$APP_DEST/CompanionBackdrop.app"
fi
