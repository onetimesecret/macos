#!/usr/bin/env bash
# Build companion-ffi as a universal macOS .xcframework for a Swift shell
# (or spike) to link. macOS-only: needs the Apple SDK, rustup Apple
# targets, and xcodebuild. Output lands in bindings/ (git-ignored: a
# build artifact, not source).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-core.sh must run on macOS (needs the Apple SDK + xcodebuild)." >&2
  exit 1
fi

# Xcode-beta 26.0 first-launch leaves xcrun without a resolved SDK, and
# lipo and xcodebuild then hang waiting on one, so the developer dir and
# SDK path are set explicitly. A caller that already exported either
# keeps its own value.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  if [[ ! -d "$DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
export DEVELOPER_DIR
export SDKROOT="${SDKROOT:-$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"

XCF=bindings/CompanionCore.xcframework
# The feature shape the last build baked in. Release is explicit: a missing
# stamp must never compare equal to the release shape.
STAMP=bindings/CompanionCore.features

IF_STALE=0
FEATURES=""
SHAPE="release"
# --test-util adds the gated test seams (ADR-0018) for the dev build
# the Swift suite links against.
for arg in "$@"; do
  case "$arg" in
    --if-stale) IF_STALE=1 ;;
    --test-util) FEATURES="test-util"; SHAPE="test-util" ;;
    *)
      echo "unknown argument: $arg (the flags are --if-stale and --test-util)" >&2
      exit 1
      ;;
  esac
done

echo "==> Verifying pinned Betlang package and model"
scripts/verify-betlang.py

if [[ "$IF_STALE" == 1 ]]; then
  # Rebuild only when the xcframework and explicit shape stamp exist, the
  # shape matches, and no source, manifest, header, notice, toolchain, or build
  # script input is newer. The verifier above always runs, even on a cache hit.
  if [[ -d "$XCF" && -f "$STAMP" && "$(cat "$STAMP")" == "$SHAPE" \
    && ! THIRD_PARTY_NOTICES.md -nt "$XCF" \
    && ! rust-toolchain.toml -nt "$XCF" \
    && ! scripts/build-core.sh -nt "$XCF" \
    && -z "$(find crates Cargo.toml Cargo.lock -type f \( -name '*.rs' -o -name 'Cargo.*' -o -name '*.h' \) -newer "$XCF" -print -quit)" ]] \
    && cmp -s THIRD_PARTY_NOTICES.md "$XCF/THIRD_PARTY_NOTICES.md"; then
    echo "==> $XCF is current ($SHAPE); skipping core build"
    exit 0
  fi
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
  echo "==> cargo build --locked --release -p companion-ffi --target $t${FEATURES:+ --features $FEATURES}"
  cargo build --locked --release -p companion-ffi --target "$t" ${FEATURES:+--features "$FEATURES"}
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
rm -f "$STAMP"
xcodebuild -create-xcframework \
  -library "$UNIVERSAL/$LIB" -headers "$HEADERS" \
  -output "$XCF"
cp THIRD_PARTY_NOTICES.md "$XCF/THIRD_PARTY_NOTICES.md"
plutil -lint "$XCF/Info.plist"
cmp -s THIRD_PARTY_NOTICES.md "$XCF/THIRD_PARTY_NOTICES.md" || {
  echo "xcframework third-party notices do not match the canonical notice" >&2
  exit 1
}
printf '%s\n' "$SHAPE" > "$STAMP"
echo "Built $XCF ($SHAPE)"
