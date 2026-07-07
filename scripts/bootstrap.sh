#!/usr/bin/env bash
# One-command dev setup (docs/01 §10). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rustup >/dev/null 2>&1; then
  echo "Install rustup first: https://rustup.rs" >&2
  exit 1
fi

echo "==> Toolchain (pinned by rust-toolchain.toml)"
rustup show active-toolchain || true

echo "==> Fetching dependencies"
cargo fetch

echo "==> Building the portable core"
cargo build -p ots-core

cat <<'EOF'

Bootstrap complete.

Next:
  scripts/check.sh          # fmt + clippy + tests (+ deny/swift where available)
  cargo test -p ots-core    # the portable trust core (fully testable here)
  scripts/build-core.sh     # (macOS only) build the .xcframework for the Swift app

The Swift app in apps/OTSCache builds on macOS after build-core.sh has produced
bindings/OtsCore.xcframework.
EOF
