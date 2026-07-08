#!/usr/bin/env bash
# Build companion-ffi as a universal macOS .xcframework for a Swift shell
# (or spike) to link. macOS-only: needs the Apple SDK, rustup Apple
# targets, and xcodebuild. Output lands in bindings/ (git-ignored — a
# build artifact, not source).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-core.sh must run on macOS (needs the Apple SDK + xcodebuild)." >&2
  exit 1
fi

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
LIB=libcompanion_ffi.a
OUT=bindings
XCF="$OUT/CompanionCore.xcframework"
HEADERS="$OUT/include"
UNIVERSAL="target/universal-apple-darwin/release"

echo "==> Ensuring Apple targets are installed"
rustup target add "${TARGETS[@]}"

for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release -p companion-ffi --target $t"
  cargo build --release -p companion-ffi --target "$t"
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
cp crates/ffi/include/companion_ffi.h "$HEADERS/"
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
