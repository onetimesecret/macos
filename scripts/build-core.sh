#!/usr/bin/env bash
# Build companion-ffi as a universal macOS .xcframework for a Swift shell
# (or spike) to link. macOS-only: needs the Apple SDK, rustup Apple
# targets, and xcodebuild. Output lands in bindings/ (git-ignored — a
# build artifact, not source).
#
# --dev-scaffolding compiles in companion_dev_seed_pasteboard (the
# temporary plaintext-ingest shim the spike needs until the NSPasteboard
# adapter lands, issue #3) and declares it in the packaged header. The
# default build has neither the symbol nor the declaration.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-core.sh must run on macOS (needs the Apple SDK + xcodebuild)." >&2
  exit 1
fi

DEV_SCAFFOLDING=0
CARGO_FEATURES=()
if [[ "${1:-}" == "--dev-scaffolding" ]]; then
  DEV_SCAFFOLDING=1
  CARGO_FEATURES=(--features dev-scaffolding)
elif [[ -n "${1:-}" ]]; then
  echo "unknown argument: $1 (the only flag is --dev-scaffolding)" >&2
  exit 1
fi

# Must match the shell's platform floor (Package.swift: .macOS(.v13)),
# else cc-built objects (e.g. ring's C sources) default to the SDK's
# version and ld warns on every link.
export MACOSX_DEPLOYMENT_TARGET=13.0

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
LIB=libcompanion_ffi.a
OUT=bindings
XCF="$OUT/CompanionCore.xcframework"
HEADERS="$OUT/include"
UNIVERSAL="target/universal-apple-darwin/release"

echo "==> Ensuring Apple targets are installed"
rustup target add "${TARGETS[@]}"

for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release -p companion-ffi --target $t ${CARGO_FEATURES[*]}"
  cargo build --release -p companion-ffi --target "$t" "${CARGO_FEATURES[@]}"
done

echo "==> lipo -> universal static lib"
mkdir -p "$UNIVERSAL"
lipo -create \
  "target/aarch64-apple-darwin/release/$LIB" \
  "target/x86_64-apple-darwin/release/$LIB" \
  -output "$UNIVERSAL/$LIB"

echo "==> Assembling headers + modulemap"
rm -rf "$XCF" "$HEADERS"
mkdir -p "$HEADERS"
if [[ "$DEV_SCAFFOLDING" == 1 ]]; then
  # Expose the dev-only declaration iff the symbol was compiled in.
  printf '#define COMPANION_DEV_SCAFFOLDING 1\n' |
    cat - crates/ffi/include/companion_ffi.h > "$HEADERS/companion_ffi.h"
else
  cp crates/ffi/include/companion_ffi.h "$HEADERS/"
fi
cat > "$HEADERS/module.modulemap" <<'EOF'
module CompanionCore {
    header "companion_ffi.h"
    export *
}
EOF

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
  -library "$UNIVERSAL/$LIB" -headers "$HEADERS" \
  -output "$XCF"

echo "Built $XCF"
