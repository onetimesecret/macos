#!/usr/bin/env bash
# Quit a running CompanionApp, escalating only as far as needed:
# AppleScript quit → SIGTERM → SIGKILL. Only the graceful path runs
# the quit-time persistence snapshot; the kill paths lose anything not
# yet persisted — hence graceful gets the longest window.
#
# Run this before `swift build` while the app is running from .build/:
# the in-place re-sign SIGKILLs the live process mid-flight.
set -euo pipefail

APP=CompanionApp

# `tell application to quit` launches the app if it isn't running just
# to deliver the event — check first.
if ! pgrep -xq "$APP"; then
  echo "$APP is not running."
  exit 0
fi

wait_for_exit() { # <seconds>
  local deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    pgrep -xq "$APP" || return 0
    sleep 0.2
  done
  return 1
}

echo "==> Asking $APP to quit"
osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
if wait_for_exit 5; then
  echo "Quit cleanly."
  exit 0
fi

echo "==> Still running — SIGTERM"
pkill -x "$APP" || true
if wait_for_exit 3; then
  echo "Terminated (quit-time snapshot skipped)."
  exit 0
fi

echo "==> Still running — SIGKILL"
pkill -KILL -x "$APP" || true
if wait_for_exit 2; then
  echo "Killed (unsaved state lost)."
  exit 0
fi

echo "$APP refused to die." >&2
exit 1
