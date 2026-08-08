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
#   scripts/build-icons.sh --sweep <zoom> [rrggbb] [grid]
#       contact sheet of vignette crops for one zoom (a scale factor,
#       or zoom|zoom2|zoom4) on a grid of focuses, default 10x10
#   scripts/build-icons.sh --scout [rrggbb] [perUnit]
#       contact sheet of the most interesting vignette crops (corners,
#       intersections, overlaps) per zoom level, keeping perUnit picks
#       for every unit of zoom (default 4, so deeper zooms show more)
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

build_sweep() { # <zoom> [rrggbb shade] [grid]
  local zoom="$1" shade="${2:-0f766e}" grid="${3:-10}"
  case "$zoom" in
    zoom) zoom=1.6 ;;
    zoom2) zoom=3.2 ;;
    zoom4) zoom=6.4 ;;
  esac
  local png="$OUT/sweep-z$zoom-$shade.png"
  echo "==> Rendering $png (${grid}x${grid})"
  swift scripts/render-icon.swift --sweep "$zoom" "$shade" "$png" "$grid"
}

build_scout() { # [rrggbb shade] [perUnit]
  local shade="${1:-0f766e}" per="${2:-4}" png="$OUT/scout-${1:-0f766e}.png"
  echo "==> Rendering $png ($per picks per unit of zoom)"
  swift scripts/render-icon.swift --scout "$shade" "$png" "$per"
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
      --scout)
        build_scout
        ;;
      *)
        echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
        exit 1
        ;;
    esac
    ;;
  2)
    case "$1" in
      --sheet) build_sheet "$2" ;;
      --sweep) build_sweep "$2" ;;
      --scout) build_scout "$2" ;;
      *)
        echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
        exit 1
        ;;
    esac
    ;;
  3)
    if [[ "$1" == "--sweep" ]]; then
      build_sweep "$2" "$3"
    elif [[ "$1" == "--scout" ]]; then
      build_scout "$2" "$3"
    else
      build_icon "$1" "$2" "$3"
    fi
    ;;
  4)
    if [[ "$1" == "--sweep" ]]; then
      build_sweep "$2" "$3" "$4"
    else
      echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: build-icons.sh [--list | --rrggbb | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
    exit 1
    ;;
esac
