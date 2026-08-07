#!/usr/bin/env bash
# The dev lane: rebuild whatever is stale, package the debug bundle,
# and launch it from dist/. The debug build takes a .debug bundle id
# and a "Dev" display name (ADR-0012), so it runs beside the installed
# copy without contending for the menu bar, defaults, keychain items,
# or state.
#
# The production counterpart is scripts/install.sh, which builds the
# release configuration and installs it to /Applications.
#
# --no-launch builds without opening the app afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

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

scripts/build-core.sh --if-stale

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

if [[ "$NO_LAUNCH" == 0 ]]; then
  echo "==> Launching $DIST_APP"
  open "$DIST_APP"
fi
