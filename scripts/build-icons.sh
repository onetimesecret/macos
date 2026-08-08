#!/usr/bin/env bash
# Produce the app icon as dist/icons/<name>.icns, rendered by
# scripts/render-icon.swift and assembled by iconutil. The motif sits
# on a deep teal, the complement of the ember accent (CompanionKit's
# Theme.swift), so the Dock tile reads against the in-app palette
# rather than blending into it.
#
# With no arguments, builds the standard set below. Idempotent and
# staleness-aware in that mode: an icon is rebuilt only when it is
# missing or older than the scripts that define it.
#
# For trying out looks, an ad-hoc mode always rebuilds:
#   scripts/build-icons.sh <name> <style> <rrggbb>
#   scripts/build-icons.sh --list             # available styles
#   scripts/build-icons.sh --rrggbb           # shades used so far
#   scripts/build-icons.sh --sheet [rrggbb]   # contact sheet of every style
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-icons.sh must run on macOS (needs swift + iconutil)." >&2
  exit 1
fi

OUT=dist/icons
mkdir -p "$OUT"

build_icon() { # <app name> <style> <rrggbb shade>
  local name="$1" style="$2" shade="$3" icns="$OUT/$1.icns"
  echo "==> Rendering $icns ($style, #$shade)"
  local iconset
  iconset="$(mktemp -d)/$name.iconset"
  swift scripts/render-icon.swift "$style" "$shade" "$iconset"
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$(dirname "$iconset")"
}

build_sheet() { # <rrggbb shade>
  local shade="$1" png="$OUT/contact-sheet-$1.png"
  echo "==> Rendering $png"
  swift scripts/render-icon.swift --sheet "$shade" "$png"
}

build_icon_if_stale() { # <app name> <style> <rrggbb shade>
  local icns="$OUT/$1.icns"
  if [[ -f "$icns" \
     && ! scripts/render-icon.swift -nt "$icns" \
     && ! scripts/build-icons.sh -nt "$icns" ]]; then
    return 0
  fi
  build_icon "$@"
}

case $# in
  0)
    build_icon_if_stale OnetimePad gradient 0f766e
    ;;
  1)
    case "$1" in
      --list)
        swift scripts/render-icon.swift --list
        ;;
      --rrggbb)
        cat <<'EOF'
0f766e  deep teal, the OnetimePad default (complement of the ember accent)
d45a2a  ember, the accent from CompanionKit's Theme.swift
8c3b1c  deep ember, the retired CompanionBackdrop shade
EOF
        ;;
      --sheet)
        build_sheet 0f766e
        ;;
      *)
        echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | <name> <style> <rrggbb>]" >&2
        exit 1
        ;;
    esac
    ;;
  2)
    if [[ "$1" == "--sheet" ]]; then
      build_sheet "$2"
    else
      echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | <name> <style> <rrggbb>]" >&2
      exit 1
    fi
    ;;
  3)
    build_icon "$1" "$2" "$3"
    ;;
  *)
    echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | <name> <style> <rrggbb>]" >&2
    exit 1
    ;;
esac
