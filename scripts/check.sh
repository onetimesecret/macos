#!/usr/bin/env bash
# Run the same gates as CI, locally (docs/01 §9). Rust gates run everywhere;
# cargo-deny and the Swift build run only where their tools exist.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> cargo fmt --check"
cargo fmt --all --check

echo "==> cargo clippy (default features)"
cargo clippy --workspace --all-targets -- -D warnings

echo "==> cargo clippy (ots-core, no default features)"
cargo clippy -p ots-core --all-targets --no-default-features -- -D warnings

echo "==> cargo test"
cargo test --workspace

if command -v cargo-deny >/dev/null 2>&1; then
  echo "==> cargo deny check"
  cargo deny check
else
  echo "==> cargo deny: SKIPPED (cargo-deny not installed; CI runs it)"
fi

# Swift lives only on macOS and links the generated .xcframework.
if command -v swift >/dev/null 2>&1 && [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> build .xcframework + swift build/test"
  scripts/build-core.sh
  ( cd apps/OTSCache && swift build && swift test )
else
  echo "==> swift: SKIPPED (not on macOS; the CI macOS job runs it)"
fi

echo "All checks passed."
