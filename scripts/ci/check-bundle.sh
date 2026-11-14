#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

case "${1:-}" in
  debug)
    name="OnetimePad Debug"
    expected_id="dev.onetimesecret.pad.debug"
    ;;
  release)
    name="OnetimePad Local"
    expected_id="dev.onetimesecret.pad"
    ;;
  *)
    echo "usage: $0 <debug|release>" >&2
    exit 1
    ;;
esac

plist="dist/$name.app/Contents/Info.plist"
id="$(plutil -extract CFBundleIdentifier raw "$plist")"
test "$id" = "$expected_id" \
  || { echo "expected bundle id $expected_id, got: $id" >&2; exit 1; }
echo "bundle id: $id"

sudden="$(plutil -extract NSSupportsSuddenTermination raw "$plist")"
test "$sudden" = "true" \
  || { echo "expected NSSupportsSuddenTermination true, got: $sudden" >&2; exit 1; }

# Ranks per type, the imported types, and no NSDocumentClass (issue #77).
python3 scripts/check-document-types.py "$plist"

test -s "dist/$name.presig.sha256" \
  || { echo "dist/$name.presig.sha256 is missing or empty" >&2; exit 1; }
cmp THIRD_PARTY_NOTICES.md "dist/$name.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cmp THIRD_PARTY_NOTICES.md bindings/CompanionCore.xcframework/THIRD_PARTY_NOTICES.md
if [[ "$1" == "release" ]]; then
  test "$(cat bindings/CompanionCore.features)" = "release"
fi
cat "dist/$name.presig.sha256"
