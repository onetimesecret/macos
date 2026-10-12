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
#       exports to dist/icons/composer-logo (or composer-<mark>).
#       Import/copy the PNGs into artwork/OnetimePad-Glass.icon/Assets by hand;
#       the saved Composer document and its assets define the release icon.
#       --composer does not update the artwork compiled by --glass.
#   scripts/build-icons.sh --mark maruhi --composer # alternate motif
#   scripts/build-icons.sh --update-glass-artwork # regenerate saved logo layers
#       retains the material and appearance settings in icon.json,
#       and refreshes the website exports as --web does.
#   scripts/build-icons.sh --glass [directory] # compile the saved Composer icon; directory is repo-relative
#   scripts/build-icons.sh --web [directory]   # export the saved Composer icon for the websites
#       light and dark renderings as 1024 pixel, 8 bit sRGB PNGs, and a
#       flat SVG of each (light in the document's fill shade, dark in
#       the Dark rendition's plate shade), in artwork/web unless a
#       repo-relative directory is given.
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
# rendered modes above. Ad-hoc renders default to maruhi; the standard,
# --dev, and --composer modes default to logo. --glass rejects --mark.
# The logo mark is the
# onetimesecret.com logo, read from the app's own resources at
# shell/Sources/CompanionKit/Resources, so the brand lockup is either of
#   scripts/build-icons.sh --mark logo <name> flat dc4a22
#   scripts/build-icons.sh <name> --mark logo flat dc4a22
# Sheets and scouts name the mark in their output file, so a maruhi
# sheet and a logo sheet at one shade do not overwrite each other.
set -euo pipefail

# The iconset directory of the render in progress, and any other
# scratch directory, taken back on any exit so a render, an export or
# iconutil failing under `set -e` leaves nothing behind in $TMPDIR.
ICONSET_DIR=""
SCRATCH_DIRS=()
cleanup_scratch() {
  [[ -z "$ICONSET_DIR" ]] || rm -rf "$ICONSET_DIR"
  ((${#SCRATCH_DIRS[@]} == 0)) || rm -rf "${SCRATCH_DIRS[@]}"
}
trap cleanup_scratch EXIT
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
  ICONSET_DIR="$(mktemp -d)"
  iconset="$ICONSET_DIR/$name.iconset"
  swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} "$style" "$shade" "$iconset"
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$ICONSET_DIR"
  ICONSET_DIR=""
  # What produced this icon, which the icns itself cannot say. Without
  # it an ad-hoc render would sit there passing for the standard icon
  # until something else went stale.
  echo "$MARK $style $shade" > "$icns.stamp"
}

build_sheet() { # <rrggbb shade>
  local shade="$1" png="$OUT/contact-sheet-$MARK-$1.png"
  echo "==> Rendering $png"
  swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} --sheet "$shade" "$png"
}

build_shadows() { # [rrggbb shade]
  local shade="${1:-0f766e}" png="$OUT/shadows-$MARK-${1:-0f766e}.png"
  echo "==> Rendering $png"
  swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} --shadows "$shade" "$png"
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
  swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} --sweep "$zoom" "$shade" "$png" "$grid"
}

build_scout() { # [rrggbb shade] [perUnit]
  local shade="${1:-0f766e}" per="${2:-4}" png="$OUT/scout-$MARK-${1:-0f766e}.png"
  echo "==> Rendering $png ($per picks per unit of zoom)"
  swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} --scout "$shade" "$png" "$per"
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

# The saved document enables refractivity, which needs Icon Composer
# 2.0 from Xcode 27, so every step that compiles or renders it checks.
require_refractivity_xcode() { # <mode flag>
  local xcode_version xcode_major
  xcode_version="$(xcodebuild -version </dev/null 2>/dev/null | awk '$1 == "Xcode" {print $2}')" || xcode_version=
  xcode_major="${xcode_version%%.*}"
  if [[ ! "$xcode_major" =~ ^[0-9]+$ ]] || ((xcode_major < 27)); then
    echo "$1 requires Xcode 27 or later for the saved refractivity artwork (selected: ${xcode_version:-unknown}); set DEVELOPER_DIR or xcode-select." >&2
    exit 1
  fi
}

# Icon Composer's command line exporter in the selected Xcode, left in
# COMPOSER_TOOL for the caller.
find_composer_tool() { # <mode flag>
  local developer_dir
  developer_dir="${DEVELOPER_DIR:-$(xcode-select --print-path)}"
  COMPOSER_TOOL="$(dirname "$developer_dir")/Applications/Icon Composer.app/Contents/Executables/ictool"
  if [[ ! -x "$COMPOSER_TOOL" ]]; then
    echo "$1 needs Icon Composer in the selected Xcode; set DEVELOPER_DIR or xcode-select." >&2
    exit 1
  fi
  require_refractivity_xcode "$1"
}

# The saved document's one fill shade as rrggbb, read from icon.json so
# the vector export cannot drift from the glass renderings. Icon
# Composer saves it as "extended-srgb:r,g,b,a" under automatic-gradient
# (its gradient derived from one shade) or solid. Any other fill is a
# composition the export does not know. Extended sRGB carries wide gamut
# colour as components below 0 or above 1, which a hex shade cannot
# hold, so such a fill is refused by name rather than clipped.
glass_fill_shade() {
  local document=artwork/OnetimePad-Glass.icon/icon.json key fill=
  for key in fill.automatic-gradient fill.solid; do
    if fill="$(plutil -extract "$key" raw -o - "$document" 2>/dev/null)"; then
      break
    fi
    fill=
  done
  if [[ ! "$fill" =~ ^extended-srgb:-?[0-9.]+,-?[0-9.]+,-?[0-9.]+,[0-9.]+$ ]]; then
    echo "could not read the glass fill: $document has no automatic-gradient or solid extended-srgb fill (got \"${fill:-nothing}\")" >&2
    exit 1
  fi
  printf '%s\n' "${fill#extended-srgb:}" |
    awk -F, -v document="$document" '
      $1 < 0 || $1 > 1 || $2 < 0 || $2 > 1 || $3 < 0 || $3 > 1 {
        printf "could not read the glass fill: %s,%s,%s in %s is outside sRGB, which a flat SVG shade cannot carry\n", $1, $2, $3, document > "/dev/stderr"
        exit 1
      }
      { printf "%02x%02x%02x\n", int($1 * 255 + 0.5), int($2 * 255 + 0.5), int($3 * 255 + 0.5) }'
}

# The websites' copy of the glass icon: Icon Composer's own light and
# dark renderings of the saved document, and a flat vector of each.
# Browsers cannot draw a .icon and an SVG cannot carry the glass, so the
# renderings are rasters. ictool writes 16 bit Display P3 and cwebp
# drops colour profiles by default, so sips converts each rendering to
# 8 bit sRGB. Each SVG is the icon shape in one shade under the white
# mark, placed as the Composer foreground is, for sizes and places
# where a raster would blur. The light shade is the document's fill;
# the document has no dark fill, Composer's dark appearance supplies
# that plate, so the dark shade is sampled from the Dark rendition. All
# four are staged and checked before any replaces the copies in the
# directory.
export_web_icons() { # [directory]
  if [[ -n "$MARK_CHOSEN" ]]; then
    echo "--web exports artwork/OnetimePad-Glass.icon; --mark applies to rendered artwork only." >&2
    exit 1
  fi
  find_composer_tool --web
  local destination="${1:-artwork/web}" staging rendition name shade dark_shade
  shade="$(glass_fill_shade)"
  staging="$(mktemp -d)"
  SCRATCH_DIRS+=("$staging")
  for rendition in Default Dark; do
    case "$rendition" in
      Default) name=onetimepad-icon ;;
      Dark) name=onetimepad-icon-dark ;;
    esac
    echo "==> Exporting $destination/$name.png ($rendition rendition)"
    "$COMPOSER_TOOL" "$PWD/artwork/OnetimePad-Glass.icon" --export-image \
      --output-file "$staging/$name-p3.png" \
      --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 >/dev/null
    # ictool exits 0 after some failures, an unknown rendition among
    # them, so only the file says whether the export happened.
    if [[ ! -s "$staging/$name-p3.png" ]]; then
      echo "could not export web icon: ictool produced no $rendition rendition" >&2
      exit 1
    fi
    sips --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
      "$staging/$name-p3.png" --out "$staging/$name.png" >/dev/null
    if [[ ! -s "$staging/$name.png" ]]; then
      echo "could not export web icon: sips produced no sRGB $name.png" >&2
      exit 1
    fi
  done
  dark_shade="$(swift scripts/render-icon.swift --plate-shade "$staging/onetimepad-icon-dark.png")"
  local svg_shade source
  for name in onetimepad-icon onetimepad-icon-dark; do
    case "$name" in
      onetimepad-icon) svg_shade="$shade"; source="icon.json" ;;
      onetimepad-icon-dark) svg_shade="$dark_shade"; source="the Dark rendition" ;;
    esac
    echo "==> Exporting $destination/$name.svg (flat, fill $svg_shade from $source)"
    swift scripts/render-icon.swift --mark logo --svg "$svg_shade" "$staging/$name.svg" >/dev/null
    if [[ ! -s "$staging/$name.svg" ]]; then
      echo "could not export web icon: render-icon.swift produced no $name.svg" >&2
      exit 1
    fi
  done
  mkdir -p "$destination"
  mv "$staging/onetimepad-icon.png" "$staging/onetimepad-icon-dark.png" \
    "$staging/onetimepad-icon.svg" "$staging/onetimepad-icon-dark.svg" "$destination/"
}

update_glass_artwork() {
  if [[ -n "$MARK_CHOSEN" ]]; then
    echo "--update-glass-artwork updates the saved logo composition; use --composer for alternate marks." >&2
    exit 1
  fi
  find_composer_tool --update-glass-artwork
  local document="$PWD/artwork/OnetimePad-Glass.icon"
  echo "==> Updating saved glass foreground and cast shadow"
  swift scripts/render-icon.swift --mark logo --composer "$OUT/composer-logo"
  cp "$OUT/composer-logo/01-logo-foreground.png" "$document/Assets/01-logo-foreground.png"
  cp "$OUT/composer-logo/00-logo-cast-shadow.png" "$document/Assets/00-logo-cast-shadow.png"
  export_web_icons
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
  require_refractivity_xcode --glass
  local compiled="${1:-$OUT/glass}" minimum_target
  minimum_target="$(plutil -extract LSMinimumSystemVersion raw shell/OnetimePad-Info.plist)"
  mkdir -p "$compiled"
  # Compile every time, including saved material and appearance changes.
  # Remove earlier outputs so a failed compile cannot leave them in use.
  rm -f "$compiled/Assets.car" "$compiled/OnetimePad-Glass.icns" "$compiled/icon-info.plist"
  echo "==> Compiling artwork/OnetimePad-Glass.icon"
  # actool's helper can crash when a CI caller leaves stdin closed.
  # Give the noninteractive compiler an open descriptor with EOF.
  xcrun actool artwork/OnetimePad-Glass.icon \
    --compile "$compiled" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target "$minimum_target" \
    --app-icon OnetimePad-Glass \
    --output-partial-info-plist "$compiled/icon-info.plist" \
    --output-format human-readable-text --warnings --notices </dev/null
  local output icon_file
  for output in Assets.car icon-info.plist; do
    if [[ ! -s "$compiled/$output" ]]; then
      echo "could not compile glass icon: actool produced no nonempty $compiled/$output" >&2
      exit 1
    fi
  done
  if ! icon_file="$(plutil -extract CFBundleIconFile raw "$compiled/icon-info.plist" 2>/dev/null)" || [[ -z "$icon_file" ]]; then
    echo "could not compile glass icon: missing CFBundleIconFile in $compiled/icon-info.plist" >&2
    exit 1
  fi
  if [[ ! -s "$compiled/$icon_file.icns" ]]; then
    echo "could not compile glass icon: actool produced no nonempty $compiled/$icon_file.icns" >&2
    exit 1
  fi
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
        swift scripts/render-icon.swift ${MARK_FLAG[@]+"${MARK_FLAG[@]}"} --composer "$OUT/composer-$MARK"
        ;;
      --glass)
        build_glass_icon
        ;;
      --web)
        export_web_icons
        ;;
      --update-glass-artwork)
        update_glass_artwork
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
        echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --update-glass-artwork | --glass [directory] | --web [directory] | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
        exit 1
        ;;
    esac
    ;;
  2)
    case "$1" in
      --glass) build_glass_icon "$2" ;;
      --web) export_web_icons "$2" ;;
      --sheet) build_sheet "$2" ;;
      --shadows) build_shadows "$2" ;;
      --sweep) build_sweep "$2" ;;
      --scout) build_scout "$2" ;;
      *)
        echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --update-glass-artwork | --glass [directory] | --web [directory] | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
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
      echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --update-glass-artwork | --glass [directory] | --web [directory] | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: build-icons.sh [--mark <maruhi|logo>] [--list | --rrggbb | --dev | --composer | --update-glass-artwork | --glass [directory] | --web [directory] | --sheet [rrggbb] | --shadows [rrggbb] | --sweep <zoom> [rrggbb] [grid] | --scout [rrggbb] [perUnit] | <name> <style> <rrggbb>]" >&2
    exit 1
    ;;
esac
