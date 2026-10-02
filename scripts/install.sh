#!/usr/bin/env bash
# The local lane: build the release bundle as dev.onetimesecret.pad, sign
# it, and install it to APP_DEST (default /Applications) as
# "OnetimePad Local.app", beside a TestFlight OnetimePad.app rather than
# over it. The installed copy
# runs from /Applications rather than from .build/ or dist/, so
# rebuilds in the repo never kill it. See
# environments/example/.env.example for pinning a signing identity
# that lets TCC grants and Keychain access survive updates.
#
# The dev counterpart is scripts/dev.sh, which packages a debug bundle
# under its own bundle id, dev.onetimesecret.pad.debug, and launches it from
# dist/.
#
# --no-launch installs without opening the app afterwards.
#
# --allow-capture launches with COMPANION_ALLOW_CAPTURE=1, which lifts
# the surface's screen-capture exclusion for the life of that run, so
# the window shows up in screenshots and screen recordings. This is a
# release build, where the variable is the only thing that reveals the
# Settings switch at all, and it seeds it on so a scripted run needs no
# click. The opt-out is never persisted and fails closed at the next
# launch (ADR-0012), which is why this is a flag and not the default.
# Exporting the variable in the calling shell does the same thing.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/build-lanes.sh
select_build_lane local

NO_LAUNCH=0
ALLOW_CAPTURE=0
# An exported COMPANION_ALLOW_CAPTURE means the same thing as the flag.
# `open` does not forward the caller's environment to the app it starts,
# so a variable set in this shell would otherwise be dropped on the way.
if [[ -n "${COMPANION_ALLOW_CAPTURE:-}" ]]; then
  ALLOW_CAPTURE=1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) NO_LAUNCH=1 ;;
    --allow-capture) ALLOW_CAPTURE=1 ;;
    *)
      echo "unknown argument: $1 (the flags are --no-launch and --allow-capture)" >&2
      exit 1
      ;;
  esac
  shift
done

# Refuse to point the destructive steps below at anything but a real
# absolute destination, and refuse before any build work starts so a
# bad invocation costs nothing.
APP_DEST="${APP_DEST-/Applications}"
if [[ -z "$APP_DEST" || "$APP_DEST" != /* ]]; then
  echo "APP_DEST must be a non-empty absolute path (got \"$APP_DEST\")." >&2
  exit 1
fi

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  echo "WARNING: CODESIGN_IDENTITY is unset, so this install will be ad-hoc" >&2
  echo "signed. TCC grants and Keychain confirmations will reset on every" >&2
  echo "update. Set it in $BUILD_ENVIRONMENT_FILE; see" >&2
  echo "environments/example/.env.example." >&2
fi

echo "==> scripts/package-app.sh (local lane)"
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
  # `open` normally registers the bundle itself, but the explicit refresh
  # makes icon-only updates visible to LaunchServices without restarting
  # Finder or the Dock. package-app.sh gives changed icon payloads distinct
  # names for the same reason.
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    echo "==> Refreshing LaunchServices registration"
    "$lsregister" -f "$dest"
  else
    echo "warning: LaunchServices registration tool is unavailable; icon refresh may wait for cache expiry." >&2
  fi
  local version
  version="$(plutil -extract CFBundleShortVersionString raw "$dest/Contents/Info.plist")"
  echo "Installed $name.app $version"
}

# One-time migration: this app used to install as CompanionBackdrop.app,
# under the legacy com.onetimesecret.companion.backdrop id. The id has
# since moved to com.onetimesecret.pad (0.19.0), so to LaunchServices the
# two bundles are two apps now rather than two copies of one, but the
# old one still goes: a stale bundle under a retired id is a second
# OnetimePad in Launchpad and Spotlight, over state the new id cannot
# read. It goes only after it has quit: quit_installed exits rather
# than return when the app will not go, and we never remove a live app.
#
# The local lane later installed as OnetimePad.app, which is also the
# name a TestFlight install takes. That bundle goes only when it carries
# this lane's id, so a TestFlight copy at the same path is left alone.
migrate_legacy_bundle() { # <legacy app name> [required bundle id]
  local name="$1" id="${2:-}"
  local legacy="$APP_DEST/$name.app"
  [[ -d "$legacy" ]] || return 0
  if [[ -n "$id" ]] &&
    [[ "$(plutil -extract CFBundleIdentifier raw "$legacy/Contents/Info.plist" 2>/dev/null)" != "$id" ]]; then
    return 0
  fi
  quit_installed "$name"
  echo "==> Removing legacy $legacy (this app is now $BUILD_APP_NAME.app)"
  rm -rf "$legacy"
}

quit_installed "$BUILD_APP_NAME"
install_bundle "$BUILD_APP_NAME"
migrate_legacy_bundle CompanionBackdrop
migrate_legacy_bundle "$PRODUCTION_APP_NAME" "$BUILD_BUNDLE_ID"

if [[ "$NO_LAUNCH" == 0 ]]; then
  if ((ALLOW_CAPTURE)); then
    echo "==> Launching installed app (screen capture allowed)"
    open --env COMPANION_ALLOW_CAPTURE=1 "$APP_DEST/$BUILD_APP_NAME.app"
  else
    echo "==> Launching installed app"
    open "$APP_DEST/$BUILD_APP_NAME.app"
  fi
fi
