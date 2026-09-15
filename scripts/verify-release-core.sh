#!/usr/bin/env bash
# Link and inspect every architecture carried by the release CompanionCore.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "verify-release-core.sh must run on macOS (needs the Apple linker)." >&2
  exit 1
fi

XCF=bindings/CompanionCore.xcframework
INFO="$XCF/Info.plist"
STAMP=bindings/CompanionCore.features
if [[ ! -f "$INFO" ]]; then
  echo "$INFO is missing; build the release core first." >&2
  exit 1
fi
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "release" ]]; then
  echo "CompanionCore is not stamped as a release build." >&2
  exit 1
fi

ENTRY="$(python3 - "$INFO" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    document = plistlib.load(source)
libraries = document.get("AvailableLibraries")
if not isinstance(libraries, list) or len(libraries) != 1:
    raise SystemExit(f"expected exactly one XCFramework library entry, got {libraries!r}")
entry = libraries[0]
if entry.get("SupportedPlatform") != "macos":
    raise SystemExit(f"expected a macOS library entry, got {entry!r}")
if "SupportedPlatformVariant" in entry:
    raise SystemExit(f"unexpected platform variant in {entry!r}")
architectures = entry.get("SupportedArchitectures")
if not isinstance(architectures, list) or sorted(architectures) != ["arm64", "x86_64"]:
    raise SystemExit(
        "expected exact XCFramework architectures ['arm64', 'x86_64'], "
        f"got {architectures!r}"
    )
required = ("LibraryIdentifier", "LibraryPath", "HeadersPath")
if any(not isinstance(entry.get(key), str) or not entry[key] for key in required):
    raise SystemExit(f"XCFramework entry is missing a required path: {entry!r}")
print("\t".join(entry[key] for key in required))
PY
)"
IFS=$'\t' read -r LIBRARY_IDENTIFIER LIBRARY_PATH HEADERS_PATH <<<"$ENTRY"
LIB="$XCF/$LIBRARY_IDENTIFIER/$LIBRARY_PATH"
HEADERS="$XCF/$LIBRARY_IDENTIFIER/$HEADERS_PATH"
if [[ ! -f "$LIB" || ! -d "$HEADERS" ]]; then
  echo "XCFramework entry paths do not exist: $LIB and $HEADERS" >&2
  exit 1
fi

ARCHIVE_ARCHS="$(lipo -archs "$LIB" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
if [[ "$ARCHIVE_ARCHS" != "arm64 x86_64" ]]; then
  echo "expected archive architectures 'arm64 x86_64', got '$ARCHIVE_ARCHS'" >&2
  exit 1
fi

TMP="$(mktemp -d -t companion-release-core)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/main.swift" <<'SWIFT'
import CompanionCore

@main
struct CompanionCoreReleaseProbe {
    static func main() {
        companion_free(nil)
    }
}
SWIFT

SEAM_PATTERN='_companion_(new_ephemeral|test_age_ms|test_wire_stub|test_wire_last_json)$'
for ARCH in arm64 x86_64; do
  TARGET="$ARCH-apple-macosx13.0"
  BIN="$TMP/companion-core-$ARCH"
  EXPORTS_FILE="$TMP/companion-core-$ARCH.exports"
  echo "==> Linking CompanionCore release probe for $ARCH"
  xcrun --sdk macosx swiftc \
    -target "$TARGET" \
    -parse-as-library \
    -I "$HEADERS" \
    "$TMP/main.swift" \
    -Xlinker -force_load \
    -Xlinker "$LIB" \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework CoreFoundation \
    -Xlinker -lobjc \
    -Xlinker -liconv \
    -o "$BIN"

  LINKED_ARCHS="$(lipo -archs "$BIN" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  if [[ "$LINKED_ARCHS" != "$ARCH" ]]; then
    echo "expected linked output architecture '$ARCH', got '$LINKED_ARCHS'" >&2
    exit 1
  fi
  if ! nm -gU "$BIN" >"$EXPORTS_FILE"; then
    echo "nm could not inspect the $ARCH release probe." >&2
    exit 1
  fi
  if ! grep -q -E '_companion_free$' "$EXPORTS_FILE"; then
    echo "$ARCH release probe does not export _companion_free; refusing unchecked output." >&2
    exit 1
  fi
  SEAM="$(grep -o -E "$SEAM_PATTERN" "$EXPORTS_FILE" | head -n 1 || true)"
  if [[ -n "$SEAM" ]]; then
    echo "$ARCH release probe exports ${SEAM#_}, a test-only seam (ADR-0018)." >&2
    exit 1
  fi
done

echo "Verified CompanionCore release linkage and symbols for arm64 and x86_64."
