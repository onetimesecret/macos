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

types="$(plutil -extract CFBundleDocumentTypes raw "$plist")"
role="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw "$plist")"
rank="$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw "$plist")"
uti="$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw "$plist")"
test "$types/$role/$rank/$uti" = "1/Editor/Alternate/public.plain-text" \
  || { echo "expected 1/Editor/Alternate/public.plain-text, got: $types/$role/$rank/$uti" >&2; exit 1; }
if plutil -extract CFBundleDocumentTypes.0.NSDocumentClass raw "$plist" >/dev/null 2>&1; then
  echo "CFBundleDocumentTypes.0 names an NSDocumentClass; cmd-n belongs to page::New" >&2
  exit 1
fi

test -s "dist/$name.presig.sha256" \
  || { echo "dist/$name.presig.sha256 is missing or empty" >&2; exit 1; }
cmp THIRD_PARTY_NOTICES.md "dist/$name.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cmp THIRD_PARTY_NOTICES.md bindings/CompanionCore.xcframework/THIRD_PARTY_NOTICES.md
if [[ "$1" == "release" ]]; then
  test "$(cat bindings/CompanionCore.features)" = "release"
fi
cat "dist/$name.presig.sha256"
