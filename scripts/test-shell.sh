#!/usr/bin/env bash
# The Swift test lane. `swift test` links companion_new_ephemeral and
# the rest of the gated seams (ADR-0018), which only a --test-util core
# exports, so a bare `swift test` against a release-shape xcframework
# fails at link time with an undefined-symbol wall that names the
# symbol but not the cause. This script builds the right shape first so
# that never happens, and it is the only supported way to run the Swift
# tests.
#
# The core build is --if-stale, so back-to-back runs skip it, and the
# feature stamp build-core.sh leaves means a release-shape core left by
# scripts/install.sh is rebuilt here rather than linked against. The
# reverse holds too: install.sh rebuilds the seam-free shape, so the
# two lanes undo each other's leftovers without anyone tracking which
# ran last.
#
# Arguments are forwarded to `swift test`, so a filtered run works:
#   scripts/test-shell.sh --filter PageModelTests
set -euo pipefail
cd "$(dirname "$0")/.."

# Rebuilding can replace an executable that is still running from this build directory.
build_pattern="$(printf '%s' "$PWD/shell/.build/" | sed 's/[][\\.|$(){}?+*^]/\\&/g')"
if pgrep -f "^$build_pattern" >/dev/null; then
  echo "Refusing to rebuild shell/.build while an executable from it is running." >&2
  echo "Close that development instance normally, then rerun the tests." >&2
  exit 1
else
  process_status=$?
  if [[ "$process_status" != 1 ]]; then
    echo "Cannot inspect running build executables; no build or tests were started." >&2
    exit 1
  fi
fi

scripts/build-core.sh --if-stale --test-util

echo "==> swift test --package-path shell${*:+ $*}"
swift test --package-path shell "$@"
