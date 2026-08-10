#!/usr/bin/env bash
# The local production lane: build the release bundle, sign it, and
# install it to APP_DEST (default /Applications). The installed copy
# runs from /Applications rather than from .build/ or dist/, so
# rebuilds in the repo never kill it. See scripts/local.env.example for
# pinning a signing identity that lets TCC grants and Keychain access
# survive updates.
#
# The dev counterpart is scripts/dev.sh, which packages a debug bundle
# under a .debug bundle id and launches it from dist/.
#
# --no-launch installs without opening the app afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

# If scripts/local.env exists it is the source of truth for CODESIGN_IDENTITY.
# Sourcing sits inside an if so a local.env whose final statement returns
# non zero fails here with a message instead of killing the script silently.
if [[ -f scripts/local.env ]]; then
  source scripts/local.env || { echo "failed to source scripts/local.env" >&2; exit 1; }
fi

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

# Refuse to point the destructive steps below at anything but a real
# absolute destination, and refuse before any build work starts so a
# bad invocation costs nothing.
APP_DEST="${APP_DEST-/Applications}"
if [[ -z "$APP_DEST" || "$APP_DEST" != /* ]]; then
  echo "APP_DEST must be a non-empty absolute path (got \"$APP_DEST\")." >&2
  exit 1
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "WARNING: CODESIGN_IDENTITY is unset, so this install will be ad-hoc" >&2
  echo "signed. TCC grants and Keychain confirmations will reset on every" >&2
  echo "update. See scripts/local.env.example for a stable identity." >&2
fi

scripts/build-core.sh --if-stale

echo "==> scripts/package-app.sh"
scripts/package-app.sh

# Ask a running installed copy to quit before replacing it. Only the
# graceful AppleScript path runs the quit-time persistence snapshot, so
# we never escalate to signals here; if the app will not quit, we stop
# rather than replace it live.

# pgrep -f reads its pattern as an extended regex, so an APP_DEST with
# metacharacters would silently match nothing (or error, which callers
# would read as not running). Escape the path so the match is literal.
running_from() { # <absolute path>
  pgrep -f "$(printf '%s' "$1" | sed 's/[][\.|$(){}?+*^]/\\&/g')" >/dev/null
}

quit_installed() { # <app name>
  local name="$1"
  local macos_dir="$APP_DEST/$name.app/Contents/MacOS"
  running_from "$macos_dir" || return 0
  echo "==> Asking $name at $APP_DEST to quit"
  # Address the app by path, not bundle id: a release copy running from
  # dist/ shares the installed copy's id, and an id-addressed quit can
  # land on the wrong process. Surface osascript failures so a denied
  # Automation consent gets named instead of blamed on the app below.
  local quit_err
  if ! quit_err="$(osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$APP_DEST/$name.app" 2>&1 >/dev/null)"; then
    echo "osascript could not deliver the quit event: $quit_err" >&2
    echo "If that reads like a permissions failure, allow this terminal under" >&2
    echo "System Settings > Privacy & Security > Automation." >&2
  fi
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    running_from "$macos_dir" || return 0
    sleep 0.2
  done
  echo "$name is still running from $macos_dir; refusing to touch a live app." >&2
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

# One-time migration: this app used to install as CompanionBackdrop.app
# (the bundle id, which never changes, still carries that legacy name).
# Leaving the old bundle beside the new one would hand LaunchServices
# two registered copies of one bundle id, so the old bundle goes, but
# only after it has quit: quit_installed exits rather than return when
# the app will not go, and we never remove a live app.
migrate_legacy_bundle() { # <legacy app name>
  local name="$1"
  local legacy="$APP_DEST/$name.app"
  [[ -d "$legacy" ]] || return 0
  quit_installed "$name"
  echo "==> Removing legacy $legacy (this app is now OnetimePad.app)"
  rm -rf "$legacy"
}

quit_installed OnetimePad
install_bundle OnetimePad
migrate_legacy_bundle CompanionBackdrop

if [[ "$NO_LAUNCH" == 0 ]]; then
  echo "==> Launching installed app"
  open "$APP_DEST/OnetimePad.app"
fi
