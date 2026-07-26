#!/usr/bin/env bash
# Produce the two app icons as dist/icons/<name>.icns, rendered by
# scripts/render-icon.swift and assembled by iconutil. One motif, two
# shades of the ember accent (CompanionKit's Theme.swift): the panel
# gets ember itself, the backdrop a deeper shade of it, so the Dock
# shows two siblings rather than two identical apps or two
# placeholders.
#
# Idempotent and staleness-aware: an icon is rebuilt only when it is
# missing or older than the scripts that define it. The build scripts
# call this before copying the .icns into each bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-icons.sh must run on macOS (needs swift + iconutil)." >&2
  exit 1
fi

OUT=dist/icons
mkdir -p "$OUT"

build_icon() { # <app name> <rrggbb shade>
  local name="$1" shade="$2" icns="$OUT/$1.icns"
  if [[ -f "$icns" \
     && ! scripts/render-icon.swift -nt "$icns" \
     && ! scripts/build-icons.sh -nt "$icns" ]]; then
    return 0
  fi
  echo "==> Rendering $icns (#$shade)"
  local iconset
  iconset="$(mktemp -d)/$name.iconset"
  swift scripts/render-icon.swift "$shade" "$iconset"
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$(dirname "$iconset")"
}

build_icon CompanionApp d45a2a
build_icon CompanionBackdrop 8c3b1c
