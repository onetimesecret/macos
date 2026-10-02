#!/usr/bin/env bash
# Produce the app icon as dist/icons/<name>.icns, rendered by
# scripts/render-icon.swift and assembled by iconutil. The standard
# icon is the onetimesecret.com logo mark on deep ember, which is the
# same mark the menu bar item draws (CompanionKit's LogoMark) from the
# same asset, so tray and Dock tile read as one app. The dev lane's is
# the same mark on black, and the shade is what tells a dev instance
# from the installed copy in the Dock (--dev, and scripts/dev.sh takes
# it automatically).
#
# With no arguments, builds the standard set below. Idempotent and
# staleness-aware in that mode: an icon is rebuilt only when it is
# missing, older than the scripts and art that define it, or was last
# rendered from a different mark, style or shade (each icon carries a
# .stamp saying which).
#
# For trying out looks, an ad-hoc mode always rebuilds:
#   scripts/build-icons.sh <name> <style> <rrggbb>
#   scripts/build-icons.sh --dev              # the dev lane's black icon
#   scripts/build-icons.sh --list             # available marks and styles
#   scripts/build-icons.sh --composer         # foreground and cast shadow for Icon Composer
#   scripts/build-icons.sh --mark maruhi --composer # alternate motif
#   scripts/build-icons.sh --glass            # compile the saved Composer icon for packaging
#   scripts/build-icons.sh --rrggbb           # shades used so far
#   scripts/build-icons.sh --sheet [rrggbb]   # contact sheet of every style
#   scripts/build-icons.sh --shadows [rrggbb]
#       contact sheet of the long shadow family as a matrix, one row per
#       treatment and one column per angle, for judging which direction
#       and which falloff the mark wants
#   scripts/build-icons.sh --sweep <zoom> [rrggbb] [grid]
#       contact sheet of vignette crops for one zoom (a scale factor,
#       or zoom|zoom2|zoom4) on a grid of focuses, default 10x10
#   scripts/build-icons.sh --scout [rrggbb] [perUnit]
#       contact sheet of the most interesting vignette crops (corners,
#       intersections, overlaps) per zoom level, keeping perUnit picks
#       for every unit of zoom (default 4, so deeper zooms show more)
#
# A --mark <maruhi|logo> anywhere in the arguments picks the motif for
# any of the above and defaults to the maruhi. The logo mark is the
# onetimesecret.com logo, read from the app's own resources at
# shell/Sources/CompanionKit/Resources, so the brand lockup is either of
#   scripts/build-icons.sh --mark logo <name> flat dc4a22
#   scripts/build-icons.sh <name> --mark logo flat dc4a22
# Sheets and scouts name the mark in their output file, so a maruhi
# sheet and a logo sheet at one shade do not overwrite each other.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-icons.sh must run on macOS (needs swift + iconutil)." >&2
  exit 1
fi

OUT=dist/icons
mkdir -p "$OUT"

# The motif, and the render-icon.swift flag that selects it. Empty for
# the default, so an unadorned run is the command line it always was.
# The flag is pulled out wherever it appears, since it reads as naturally
# after the app name as before it, and what remains is dispatched below
# by count as if the flag had never been there.
MARK=maruhi
MARK_FLAG=()
MARK_CHOSEN=
REST=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mark)
      [[ $# -ge 2 ]] || { echo "--mark needs a mark name" >&2; exit 1; }
      MARK="$2"
      MARK_FLAG=(--mark "$2")
      MARK_CHOSEN=yes
      shift 2
      ;;
    *)
      REST+=("$1")
      shift
      ;;
  esac
done
set -- ${REST[@]+"${REST[@]}"}

build_icon() { # <app name> <style> <rrggbb shade>
  local name="$1" style="$2" shade="$3" icns="$OUT/$1.icns"
  echo "==> Rendering $icns ($MARK, $style, #$shade)"
  local iconset
  iconset="$(mktemp -d)/$name.iconset"
  swift scripts/render-icon.swift "${MARK_FLAG[@]}" "$style" "$shade" "$iconset"
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$(dirname "$iconset")"
  # What produced this icon, which the icns itself cannot say. Without
  # it an ad-hoc render would sit there passing for the standard icon
  # until something else went stale.
  echo "$MARK $style $shade" > "$icns.stamp"
}

build_sheet() { # <rrggbb shade>
  local shade="$1" png="$OUT/contact-sheet-$MARK-$1.png"
  echo "==> Rendering $png"
  swift scripts/render-icon.swift "${MARK_FLAG[@]}" --sheet "$shade" "$png"
}

build_shadows() { # [rrggbb shade]
  local shade="${1:-0f766e}" png="$OUT/shadows-$MARK-${1:-0f766e}.png"
  echo "==> Rendering $png"
  swift scripts/render-icon.swift "${MARK_FLAG[@]}" --shadows "$shade" "$png"
}

build_sweep() { # <zoom> [rrggbb shade] [grid]
  local zoom="$1" shade="${2:-0f766e}" grid="${3:-10}"
  case "$zoom" in
    zoom) zoom=1.6 ;;
    zoom2) zoom=3.2 ;;
    zoom4) zoom=6.4 ;;
  esac
  local png="$OUT/sweep-$MARK-z$zoom-$shade.png"
  echo "==> Rendering $png (${grid}x${grid})"
  swift scripts/render-icon.swift "${MARK_FLAG[@]}" --sweep "$zoom" "$shade" "$png" "$grid"
}

build_scout() { # [rrggbb shade] [perUnit]
  local shade="${1:-0f766e}" per="${2:-4}" png="$OUT/scout-$MARK-${1:-0f766e}.png"
  echo "==> Rendering $png ($per picks per unit of zoom)"
  swift scripts/render-icon.swift "${MARK_FLAG[@]}" --scout "$shade" "$png" "$per"
}

# The brand art, which the app ships as a resource and this script
# reads through render-icon.swift; edits to it restale the icon.
LOGO_SVG=shell/Sources/CompanionKit/Resources/onetime-logo-v3-xl.svg

build_icon_if_stale() { # <app name> <style> <rrggbb shade>
  local icns="$OUT/$1.icns"
  if [[ -f "$icns" \
     && "$(cat "$icns.stamp" 2>/dev/null)" == "$MARK $2 $3" \
     && ! scripts/render-icon.swift -nt "$icns" \
     && ! scripts/build-icons.sh -nt "$icns" \
     && ! "$LOGO_SVG" -nt "$icns" ]]; then
    return 0
  fi
  build_icon "$@"
}

build_glass_icon() {
  if [[ -n "$MARK_CHOSEN" ]]; then
    echo "--glass compiles artwork/OnetimePad-Glass.icon; --mark applies to rendered artwork only." >&2
    exit 1
  fi
  if ! xcrun --find actool >/dev/null 2>&1; then
    echo "--glass needs Xcode with Icon Composer support (actool); select it with DEVELOPER_DIR or xcode-select." >&2
    exit 1
  fi
  local compiled="$OUT/glass" minimum_target
  minimum_target="$(plutil -extract LSMinimumSystemVersion raw shell/OnetimePad-Info.plist)"
  mkdir -p "$compiled"
  # Compile every time, including saved material and appearance changes.
  # Remove earlier outputs so a failed compile cannot leave them in use.
  rm -f "$compiled/Assets.car" "$compiled/OnetimePad-Glass.icns" "$compiled/icon-info.plist"
  echo "==> Compiling artwork/OnetimePad-Glass.icon"
  xcrun actool artwork/OnetimePad-Glass.icon \
    --compile "$compiled" \
    --platform macosx \
    --minimum-deployment-target "$minimum_target" \
    --app-icon OnetimePad-Glass \
    --output-partial-info-plist "$compiled/icon-info.plist" \
    --output-format human-readable-text --warnings --notices
}

case $# in
  0)
    # The standard icon: the logo mark on deep ember, casting the long
    # shadow. The mark is the tray's too (CompanionKit's LogoMark reads
    # the same asset), so the Dock tile and the menu bar stay in step.
    if [[ -n "$MARK_CHOSEN" ]]; then
      # Asking for the standard icon in another motif is a change the
      # staleness check cannot see, so it is built outright.
      build_icon OnetimePad longshadow 8c3b1c
    else
      MARK=logo
      MARK_FLAG=(--mark logo)
      build_icon_if_stale OnetimePad longshadow 8c3b1c
    fi
    ;;
  1)
    case "$1" in
      --list)
        swift scripts/render-icon.swift --list
        ;;
      --composer)
        if [[ -z "$MARK_CHOSEN" ]]; then
          MARK=logo
          MARK_FLAG=(--mark logo)
        fi
        swift scripts/render-icon.swift "${MARK_FLAG[@]}" --composer "$OUT/composer-$MARK"
        ;;
      --glass)
        build_glass_icon
        ;;
      --rrggbb)
        cat <<'EOF'
0f766e  deep teal, the OnetimePad default (complement of the ember accent)
d45a2a  ember, the accent from CompanionKit's Theme.swift
8c3b1c  deep ember, the retired CompanionBackdrop shade
dc4a22  onetimesecret.com brand orange, the plate the logo mark sits on
fefefe  the near white the logo mark itself is drawn in
EOF
        ;;
      --dev)
        # The dev lane's icon, and only ever this one: the same logo
        # mark on black. A dev instance and the installed copy sit in
        # the Dock together all day, and the shade is the only thing
        # that separates them at a glance. Its own name, so an ad-hoc
        # render of the standard icon cannot be picked up as the dev
        # one and a dev packaging run cannot overwrite the release
        # icon.
        MARK=logo
        MARK_FLAG=(--mark logo)
        build_icon_if_stale OnetimePad-dev flat 000000
        ;;
      --sheet)
        build_sheet 0f766e
        ;;
      --shadows)
        build_shadows
        ;;
      --scout)
        build_scout
        ;;
      *)
        echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --glass | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
        exit 1
        ;;
    esac
    ;;
  2)
    case "$1" in
      --sheet) build_sheet "$2" ;;
      --shadows) build_shadows "$2" ;;
      --sweep) build_sweep "$2" ;;
      --scout) build_scout "$2" ;;
      *)
        echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --glass | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
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
      echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --glass | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --glass | --sheet [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
    exit 1
    ;;
esac
