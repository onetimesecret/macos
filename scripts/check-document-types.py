#!/usr/bin/env python3
"""Check the document types of a packaged Info.plist.

Usage: scripts/check-document-types.py path/to/Info.plist

BundleDeclarationTests pins the source plist; CI runs this over the plist
scripts/package-app.sh assembled.
"""

import plistlib
import sys

EXPECTED_RANKS = {
    "public.plain-text": "Alternate",
    "net.daringfireball.markdown": "Default",
    "com.apple.log": "Default",
    "com.onetimesecret.pad.dotenv": "Default",
}
SYSTEM_TYPES = {"public.plain-text", "com.apple.log"}


def problems(plist: dict) -> list[str]:
    found = []
    ranks = {}
    for index, entry in enumerate(plist.get("CFBundleDocumentTypes", [])):
        where = f"CFBundleDocumentTypes.{index}"
        if entry.get("CFBundleTypeRole") != "Editor":
            found.append(f"{where}: role is {entry.get('CFBundleTypeRole')!r}, expected 'Editor'")
        if "NSDocumentClass" in entry:
            found.append(f"{where}: names an NSDocumentClass; cmd-n belongs to page::New")
        types = entry.get("LSItemContentTypes", [])
        if len(types) != 1:
            found.append(f"{where}: expected one content type, got {types!r}")
            continue
        if types[0] in ranks:
            found.append(f"{where}: {types[0]} is declared twice")
        ranks[types[0]] = entry.get("LSHandlerRank")
    if ranks != EXPECTED_RANKS:
        found.append(f"content types and ranks are {ranks!r}, expected {EXPECTED_RANKS!r}")
    imported = {
        entry.get("UTTypeIdentifier") for entry in plist.get("UTImportedTypeDeclarations", [])
    }
    missing = set(EXPECTED_RANKS) - SYSTEM_TYPES - imported
    if missing:
        found.append(f"declared but not imported: {sorted(missing)!r}")
    if "UTExportedTypeDeclarations" in plist:
        found.append("the bundle exports a type; the build lanes would contend for it")
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], "rb") as handle:
        found = problems(plistlib.load(handle))
    for line in found:
        print(f"{argv[1]}: {line}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
