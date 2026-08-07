#!/usr/bin/env bash
# Quit the running companion apps, escalating only as far as needed:
# AppleScript quit, then SIGTERM, then SIGKILL. Only the graceful path
# runs the quit-time persistence snapshot; the kill paths lose anything
# not yet persisted, so graceful gets the longest window.
#
# With no argument this quits every running instance of both apps. Pass
# CompanionApp or CompanionBackdrop to quit just that one.
#
# Run this before `swift build` while an app is running from .build/:
# the in-place re-sign SIGKILLs the live process mid-flight. A process
# running from dist/ survives `swift build`, but scripts/build-app.sh
# and scripts/build-backdrop.sh both `rm -rf` their dist/ bundle before
# reassembling it, so a live dist/ copy has to be quit before packaging
# too.
set -euo pipefail

APPS=(CompanionApp CompanionBackdrop)

# One optional argument, and it is checked by count rather than by
# emptiness: an empty string is still an argument, and treating it as
# "no argument given" would quietly quit both apps when the caller
# named one and the name expanded to nothing.
if (($# > 1)); then
  echo "too many arguments; pass at most one app name" >&2
  echo "valid names: ${APPS[*]}" >&2
  exit 1
elif (($# == 1)); then
  case "$1" in
    CompanionApp | CompanionBackdrop) APPS=("$1") ;;
    *)
      echo "unknown app: $1" >&2
      echo "valid names: ${APPS[*]}" >&2
      exit 1
      ;;
  esac
fi

# The enclosing .app of a running process, resolved from its pid. We
# address AppleScript at that path rather than at the app's name,
# because `tell application "CompanionBackdrop"` asks LaunchServices to
# resolve a name that no longer exists: the backdrop's bundle name is
# OnetimePad. A path names the bundle we actually found running, which
# a name cannot do. It is not a promise about routing: when two copies
# share a bundle id, which process the event reaches is LaunchServices'
# call, and the escalation below is what covers the copy that survives.
#
# Two ways to fail, and the caller has to tell them apart: 2 means the
# pid is gone (it exited in the moment between pgrep listing it and ps
# being asked about it, so there is nothing left to quit), 1 means the
# process is alive but has no .app around it.
bundle_for_pid() { # <pid>
  local exe stem
  exe="$(ps -p "$1" -o comm= 2>/dev/null)" || return 2
  [[ -n "$exe" ]] || return 2
  stem="${exe%/Contents/MacOS/*}"
  [[ "$stem" != "$exe" && "$stem" == *.app ]] || return 1
  printf '%s\n' "$stem"
}

wait_for_exit() { # <app name> <seconds>
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    pgrep -xq "$1" || return 0
    sleep 0.2
  done
  return 1
}

# Ask one .app to quit. Surface osascript failures so a denied Automation
# consent gets named instead of blamed on the app.
applescript_quit() { # <bundle path>
  local quit_err
  if ! quit_err="$(osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$1" 2>&1 >/dev/null)"; then
    echo "osascript could not deliver the quit event to $1: $quit_err" >&2
    echo "If that reads like a permissions failure, allow this terminal under" >&2
    echo "System Settings > Privacy & Security > Automation." >&2
  fi
}

quit_app() { # <app name>; returns non zero if it is still running at the end
  local name="$1"
  local pids bundles=() seen="" bare=0 pid bundle rc

  # `tell application to quit` launches the app if it isn't running just
  # to deliver the event, so check first.
  pids="$(pgrep -x "$name" || true)"
  if [[ -z "$pids" ]]; then
    echo "$name is not running."
    return 0
  fi

  # Two copies of the same app can be running at once (dist/ and
  # /Applications, say). Collect one entry per distinct bundle so each
  # gets its own quit event and neither gets two.
  for pid in $pids; do
    bundle="$(bundle_for_pid "$pid")" && rc=0 || rc=$?
    case "$rc" in
      0)
        if ! grep -Fxq "$bundle" <<<"$seen"; then
          seen+="$bundle"$'\n'
          bundles+=("$bundle")
        fi
        ;;
      1)
        # A bare `swift run` binary has no .app around it, so there is
        # no path for AppleScript to address and no way to ask it
        # politely.
        bare=1
        ;;
      *)
        # The pid went away while we were looking at it. Nothing to
        # address and nothing to report: any copy still running is
        # another pid in this same list.
        ;;
    esac
  done

  if ((bare)); then
    echo "$name is running without an .app bundle (a bare \`swift run\` binary)."
    echo "AppleScript cannot address it, so the quit-time snapshot is skipped."
  fi

  # Every pid pgrep handed us had exited by the time we asked ps about
  # it, so the escalation below would be signalling nothing and would
  # report a kill that never happened.
  if ((${#bundles[@]} == 0 && bare == 0)); then
    echo "$name exited on its own before it could be asked to quit."
    return 0
  fi

  if ((${#bundles[@]})); then
    for bundle in "${bundles[@]}"; do
      echo "==> Asking $name at $bundle to quit"
      applescript_quit "$bundle"
    done
    if wait_for_exit "$name" 5; then
      echo "$name quit cleanly."
      return 0
    fi
  fi

  echo "==> $name still running: SIGTERM"
  pkill -x "$name" || true
  if wait_for_exit "$name" 3; then
    echo "$name terminated (quit-time snapshot skipped)."
    return 0
  fi

  echo "==> $name still running: SIGKILL"
  pkill -KILL -x "$name" || true
  if wait_for_exit "$name" 2; then
    echo "$name killed (unsaved state lost)."
    return 0
  fi

  echo "$name refused to die." >&2
  return 1
}

status=0
for app in "${APPS[@]}"; do
  quit_app "$app" || status=1
done
exit "$status"
