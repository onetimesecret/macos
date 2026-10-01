#!/usr/bin/env bash
# The dev lane: rebuild whatever is stale, package the debug bundle,
# and launch it from dist/. The debug build takes its own bundle id
# (dev.onetimesecret.pad.debug), a "Dev" display name and the black app icon
# (ADR-0012), so it runs
# beside the installed copy without contending for the menu bar,
# defaults, keychain items, or state, and without being mistaken for it.
#
# The local counterpart is scripts/install.sh, which builds the release
# configuration as dev.onetimesecret.pad and installs it to /Applications.
#
# --no-launch builds without opening the app afterwards.
#
# The dev lane launches with COMPANION_ALLOW_CAPTURE=1 by default, which
# lifts the surface's screen-capture exclusion for the life of that run,
# so the window shows up in screenshots and screen recordings. A debug
# build always offers the Settings switch; the variable is what seeds
# it on, so a scripted run needs no click. The opt-out is never
# persisted and fails closed at the next launch (ADR-0012), which is
# why production keeps this a flag; the dev lane deviates because
# hand checks and scripted runs need the surface to render into
# captures without a click. Export COMPANION_ALLOW_CAPTURE=0 in the
# calling shell to force the fail-closed shape.
#
# --with-probe also builds dist/window-order-probe from
# scripts/window-order-probe.swift, the evidence standard for issue 184
# and ADR-0034. Off by default because most dev cycles don't need it.
# When on, the script prints the exact command to run afterwards.
#
# The other probe, scripts/sandbox-file-access-probe.swift (ADR-0035),
# is not built here. It is a bundle of its own, signed with the
# entitlements under test and launched through LaunchServices, none of
# which this script's debug bundle takes part in, so it has its own
# runner: scripts/sandbox-file-access-probe.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

NO_LAUNCH=0
# The dev lane defaults to allowing screen capture so scripted runs and
# hand checks can screenshot the surface without a flag. The header
# explains why this is a flag in production (ADR-0012 fail-closed); the
# dev lane deliberately deviates because a running dev build already
# offers the Settings switch. Export COMPANION_ALLOW_CAPTURE=0 in the
# calling shell to opt back out for a single run.
ALLOW_CAPTURE=1
WITH_PROBE=0
# An exported COMPANION_ALLOW_CAPTURE overrides the default. `open` does
# not forward the caller's environment to the app it starts, so a
# variable set in this shell would otherwise be dropped on the way.
if [[ -n "${COMPANION_ALLOW_CAPTURE:-}" ]]; then
  if [[ "$COMPANION_ALLOW_CAPTURE" == "0" ]]; then
    ALLOW_CAPTURE=0
  else
    ALLOW_CAPTURE=1
  fi
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) NO_LAUNCH=1 ;;
    --allow-capture) ALLOW_CAPTURE=1 ;;
    --with-probe) WITH_PROBE=1 ;;
    *)
      echo "unknown argument: $1 (the flags are --no-launch, --allow-capture and --with-probe)" >&2
      exit 1
      ;;
  esac
  shift
done

# The dev lane builds the dev shape of the core, test seams included
# (ADR-0018), which keeps bindings/ linkable by `swift test` between
# runs. The release lane (scripts/install.sh) builds without the
# feature, and the stamp build-core.sh leaves means each lane rebuilds
# the other's leftovers automatically.
scripts/build-core.sh --if-stale --test-util

# package-app.sh deletes and reassembles the dist/ bundle, so a copy
# still running from there has to quit first. Only the graceful
# AppleScript path runs the quit-time persistence snapshot; if the app
# will not quit, stop rather than pull the bundle out from under it.

# pgrep -f reads its pattern as an extended regex; escape the path so
# the match is literal.
running_from() { # <absolute path>
  pgrep -f "$(printf '%s' "$1" | sed 's/[][\.|$(){}?+*^]/\\&/g')" >/dev/null
}

DIST_APP="$PWD/dist/OnetimePad.app"
if running_from "$DIST_APP/Contents/MacOS"; then
  echo "==> Asking the copy running from dist/ to quit"
  quit_err=""
  if ! quit_err="$(osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$DIST_APP" 2>&1 >/dev/null)"; then
    echo "osascript could not deliver the quit event: $quit_err" >&2
    echo "If that reads like a permissions failure, allow this terminal under" >&2
    echo "System Settings > Privacy & Security > Automation." >&2
  fi
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    running_from "$DIST_APP/Contents/MacOS" || break
    sleep 0.2
  done
  if running_from "$DIST_APP/Contents/MacOS"; then
    echo "the app is still running from dist/; refusing to rebuild under it." >&2
    exit 1
  fi
fi

echo "==> scripts/package-app.sh --debug"
scripts/package-app.sh --debug

PROBE_OUT="dist/window-order-probe"
if ((WITH_PROBE)); then
  # The window-order probe is the evidence standard for issue 184 and
  # ADR-0034. Xcode-beta 26.0 first-launch leaves xcrun without a
  # resolved SDK and a bare swiftc hangs at the frontend, so the SDK
  # path is set explicitly.
  PROBE_SRC="scripts/window-order-probe.swift"
  if [[ ! -x "$PROBE_OUT" || "$PROBE_SRC" -nt "$PROBE_OUT" ]]; then
    echo "==> Compiling $PROBE_SRC"
    XCODE_DEV_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    if [[ ! -d "$XCODE_DEV_DIR" ]]; then
      XCODE_DEV_DIR="$(xcode-select -p)"
    fi
    DEVELOPER_DIR="$XCODE_DEV_DIR" \
      SDKROOT="$XCODE_DEV_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
      swiftc -O "$PROBE_SRC" -o "$PROBE_OUT"
  fi
fi

if [[ "$NO_LAUNCH" == 0 ]]; then
  if ((ALLOW_CAPTURE)); then
    echo "==> Launching $DIST_APP (screen capture allowed)"
    open --env COMPANION_ALLOW_CAPTURE=1 "$DIST_APP"
  else
    echo "==> Launching $DIST_APP"
    open "$DIST_APP"
  fi
fi

if ((WITH_PROBE)); then
  cat <<EOF

==> Window-order probe ready at $PROBE_OUT
    Run in a terminal on a desktop Space, then perform the route:
      $PROBE_OUT --watch --expect behind
    For routes that activate nothing (hotkey summon, outside click
    inside a full-screen Space):
      $PROBE_OUT --after 8 --expect above
EOF
fi
