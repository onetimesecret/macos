#!/usr/bin/env bash
# Package the app as a real .app bundle: dist/OnetimePad.app.
# A bare `swift run` binary has no CFBundleIdentifier, so macOS cannot
# address it: TCC grants don't stick, per-app pickers cannot list it,
# and LaunchServices registers it as a nameless process. The bundle is
# what makes the app a citizen of the permission system.
#
# This is the packaging engine; the entry points are scripts/dev.sh
# (debug, launched from dist/) and scripts/install.sh (release,
# installed to /Applications). `--app-store` builds the release bundle
# for App Store Connect and creates dist/OnetimePad.pkg. Its build number
# comes from a counter in the git common directory, shared by every
# worktree of the clone; `--build-number N` uses N instead.
#
# This script owns the required core shape: release packaging rebuilds without
# test-util, while --debug requests the development seams.
#
# --debug builds the debug configuration, which always offers the
# Settings switch that lifts the surface's capture exclusion. A release
# build offers the same switch only when launched with
# COMPANION_ALLOW_CAPTURE set, which also seeds it on. `open` does not
# forward the caller's environment; pass the variable explicitly, and to
# either configuration:
#   open --env COMPANION_ALLOW_CAPTURE=1 dist/OnetimePad.app
#   open --env COMPANION_ALLOW_CAPTURE=1 /Applications/OnetimePad.app
# Both entry points take --allow-capture, which is the same launch
# without the incantation: scripts/dev.sh --allow-capture and
# scripts/install.sh --allow-capture.
# Each lane runs under its own bundle id: dev.onetimesecret.pad.debug for
# debug builds, dev.onetimesecret.pad for the local install, and
# com.onetimesecret.pad for App Store builds, so a dev instance and the
# installed copy coexist without contending for the menu bar, defaults,
# keychain items, and state (ADR-0012).
#
# Signing is configured independently per lane, each in its own environment
# file outside the checkout (scripts/build-lanes.sh), under the same names in
# every file: CODESIGN_IDENTITY, PROVISIONING_PROFILE, and for the App Store
# lane INSTALLER_IDENTITY. Dev and local builds remain ad-hoc when
# their lane has no identity. The App Store lane requires its application
# identity, installer identity, and profile. Carrying
# scripts/Companion.entitlements takes a real identity and the matching
# lane-specific provisioning profile; every other build omits it and runs
# the documented login keychain fallback.
#
# Before signing, the assembled bundle is hashed into
# dist/OnetimePad.presig.sha256, the reproducible pre-signature
# artifact ADR-0012 publishes.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/build-lanes.sh

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package-app.sh must run on macOS (needs swift + codesign)." >&2
  exit 1
fi

CONFIG=release
APP_STORE_MODE=0
APP_STORE_BUILD_NUMBER=""
REQUESTED_BUILD_NUMBER=""
USAGE="usage: scripts/package-app.sh [--debug | --app-store [--build-number N]]"
while (($#)); do
  case "$1" in
    --debug)
      CONFIG=debug
      ;;
    --app-store)
      APP_STORE_MODE=1
      ;;
    --build-number)
      if (($# < 2)); then
        echo "$USAGE" >&2
        exit 1
      fi
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        echo "--build-number must contain decimal digits only (got: $2)" >&2
        exit 1
      fi
      REQUESTED_BUILD_NUMBER="$2"
      shift
      ;;
    *)
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
  shift
done
if [[ "$CONFIG" == "debug" ]] && ((APP_STORE_MODE)); then
  echo "$USAGE" >&2
  exit 1
fi
if [[ -n "$REQUESTED_BUILD_NUMBER" ]] && ((!APP_STORE_MODE)); then
  echo "--build-number applies only to --app-store" >&2
  exit 1
fi

if [[ "$CONFIG" == "debug" ]]; then
  select_build_lane dev
elif ((APP_STORE_MODE)); then
  select_build_lane app-store
else
  select_build_lane local
fi

DECLARED_PRODUCTION_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw shell/OnetimePad-Info.plist 2>/dev/null || true)"
if [[ "$DECLARED_PRODUCTION_BUNDLE_ID" != "$PRODUCTION_BUNDLE_ID" ]]; then
  echo "shell/OnetimePad-Info.plist declares $DECLARED_PRODUCTION_BUNDLE_ID; expected $PRODUCTION_BUNDLE_ID from scripts/build-lanes.sh" >&2
  exit 1
fi

echo "==> Build lane: $BUILD_LANE ($CONFIG, $BUILD_BUNDLE_ID)"
if [[ -f "$BUILD_ENVIRONMENT_FILE" ]]; then
  echo "==> Signing environment: $BUILD_ENVIRONMENT_FILE"
else
  echo "==> Signing environment: none ($BUILD_ENVIRONMENT_FILE is absent)"
fi

TEAM_ID=""
PROFILE_APP_ID=""
validate_signing_configuration() {
  if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
    if [[ -n "$PROVISIONING_PROFILE" ]]; then
      echo "$BUILD_LANE provisioning profile is set without a signing identity." >&2
      exit 1
    fi
    if ((APP_STORE_MODE)); then
      echo "CODESIGN_IDENTITY must name a Mac App Distribution identity for --app-store ($BUILD_ENVIRONMENT_FILE)." >&2
      exit 1
    fi
    return
  fi

  if ! security find-identity -v -p codesigning | grep -Fq "\"$CODESIGN_IDENTITY\""; then
    echo "$BUILD_LANE signing identity is not available in the keychain: $CODESIGN_IDENTITY" >&2
    exit 1
  fi
  TEAM_ID="$(security find-certificate -c "$CODESIGN_IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Za-z0-9]\{6,\}\).*/\1/p' | head -n1)"

  if [[ -z "$PROVISIONING_PROFILE" ]]; then
    if ((APP_STORE_MODE)); then
      echo "PROVISIONING_PROFILE must name a Mac App Store distribution profile for --app-store ($BUILD_ENVIRONMENT_FILE)." >&2
      exit 1
    fi
    return
  fi
  if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "$BUILD_LANE provisioning profile does not exist: $PROVISIONING_PROFILE" >&2
    exit 1
  fi
  if [[ -z "$TEAM_ID" ]]; then
    echo "could not read a Team ID from $BUILD_LANE signing identity: $CODESIGN_IDENTITY" >&2
    exit 1
  fi

  local profile_plist certificate_pem certificate_der device_udid
  profile_plist="$(mktemp -t onetimepad-profile)"
  certificate_pem="$(mktemp -t onetimepad-certificate-pem)"
  certificate_der="$(mktemp -t onetimepad-certificate-der)"
  if ! security cms -D -i "$PROVISIONING_PROFILE" > "$profile_plist"; then
    rm -f "$profile_plist" "$certificate_pem" "$certificate_der"
    echo "could not decode $BUILD_LANE provisioning profile: $PROVISIONING_PROFILE" >&2
    exit 1
  fi
  if ! security find-certificate -c "$CODESIGN_IDENTITY" -p > "$certificate_pem" \
      || ! openssl x509 -in "$certificate_pem" -outform DER -out "$certificate_der"; then
    rm -f "$profile_plist" "$certificate_pem" "$certificate_der"
    echo "could not read the certificate for $BUILD_LANE signing identity: $CODESIGN_IDENTITY" >&2
    exit 1
  fi

  device_udid=""
  if [[ "$PROFILE_CLASS" == "development" ]]; then
    device_udid="$(system_profiler SPHardwareDataType 2>/dev/null \
      | sed -n 's/^[[:space:]]*Provisioning UDID: //p' | head -n1)"
  fi
  local profile_arguments
  profile_arguments=(
    --profile-plist "$profile_plist"
    --certificate-der "$certificate_der"
    --team-id "$TEAM_ID"
    --bundle-id "$BUILD_BUNDLE_ID"
    --profile-class "$PROFILE_CLASS"
  )
  if [[ -n "$device_udid" ]]; then
    profile_arguments+=(--device-udid "$device_udid")
  fi
  if ! python3 scripts/validate-provisioning-profile.py "${profile_arguments[@]}"; then
    rm -f "$profile_plist" "$certificate_pem" "$certificate_der"
    exit 1
  fi

  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist")"
  rm -f "$profile_plist" "$certificate_pem" "$certificate_der"
}

if ((APP_STORE_MODE)); then
  # Resolved before the build so a missing counter fails in seconds, not
  # after the compile. Every worktree shares the git common directory.
  if [[ -z "${APP_STORE_BUILD_NUMBER_FILE:-}" ]]; then
    if ! GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
      echo "APP_STORE_BUILD_NUMBER_FILE must name the build number counter outside a git checkout." >&2
      exit 1
    fi
    APP_STORE_BUILD_NUMBER_FILE="$GIT_COMMON_DIR/onetimepad-app-store-build-number"
  fi
  if [[ -z "$INSTALLER_IDENTITY" ]]; then
    echo "INSTALLER_IDENTITY must name a Mac Installer Distribution identity for --app-store ($BUILD_ENVIRONMENT_FILE)." >&2
    exit 1
  fi
  if ! security find-identity -v -p basic | grep -Fq "\"$INSTALLER_IDENTITY\""; then
    echo "App Store installer identity is not available in the keychain: $INSTALLER_IDENTITY" >&2
    exit 1
  fi
fi
validate_signing_configuration

if [[ "$CONFIG" == "debug" ]]; then
  scripts/build-core.sh --if-stale --test-util
else
  # ADR-0018: never trust whichever development framework happens to be in
  # bindings/. The explicit release shape rebuilds whenever the stamp differs.
  scripts/build-core.sh --if-stale
fi

if [[ ! -d bindings/CompanionCore.xcframework ]]; then
  echo "bindings/CompanionCore.xcframework is missing after the core build." >&2
  exit 1
fi
if ! cmp -s THIRD_PARTY_NOTICES.md bindings/CompanionCore.xcframework/THIRD_PARTY_NOTICES.md; then
  echo "CompanionCore.xcframework is missing the canonical third-party notices." >&2
  exit 1
fi
if [[ "$CONFIG" == "release" ]]; then
  scripts/verify-release-core.sh
fi

# The app's marketing version is the product's own number and it lives
# in shell/OnetimePad-Info.plist, edited by hand when user visible work
# lands (issue #89). It used to be read from crates/ffi/Cargo.toml,
# which told the user about the Rust seam rather than about the app.
# The FFI and core crate versions are separate artifact identities, so all
# three are read and echoed at the assembly line below. The plist is copied into the
# bundle whole, so CFBundleShortVersionString needs no stamping; only
# CFBundleVersion does.
VERSION="$(plutil -extract CFBundleShortVersionString raw shell/OnetimePad-Info.plist 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "could not read CFBundleShortVersionString from shell/OnetimePad-Info.plist" >&2
  exit 1
fi
# The placeholder is the shape the file had before it held a real
# number, and shipping it would put 0.0.0 in About and in the tray.
if [[ "$VERSION" == "0.0.0" ]]; then
  echo "shell/OnetimePad-Info.plist still holds the 0.0.0 placeholder." >&2
  echo "Set CFBundleShortVersionString there to the version this build ships." >&2
  exit 1
fi
# Read, not stamped: companion_ffi_version() answers from the linked
# xcframework at runtime, while this reads what Cargo says today. A
# difference means build-core.sh has not rebuilt the linked artifact.
FFI_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' crates/ffi/Cargo.toml | head -n1)"
if [[ -z "$FFI_VERSION" ]]; then
  echo "could not read version from crates/ffi/Cargo.toml" >&2
  exit 1
fi
CORE_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' crates/core/Cargo.toml | head -n1)"
if [[ -z "$CORE_VERSION" ]]; then
  echo "could not read version from crates/core/Cargo.toml" >&2
  exit 1
fi

echo "==> swift build -c $CONFIG --product OnetimePad"
swift build --package-path shell -c "$CONFIG" --product OnetimePad
BIN="$(swift build --package-path shell -c "$CONFIG" --show-bin-path)/OnetimePad"

# ADR-0018: test seams are compiled out of release artifacts, and the
# claim is checked by machine here rather than trusted. The check reads
# the linked binary, not the static library, because the binary is the
# artifact this script ships (and because the library's thin-LTO
# members defeat nm). A debug bundle may carry the seams: it links the
# dev xcframework on purpose so `swift test` and dev.sh share one
# build.
if [[ "$CONFIG" == "release" ]]; then
  echo "==> Verifying no test seams in the release binary (ADR-0018)"
  # The check fails closed: an nm that errors, or a binary that lost
  # its C exports, would otherwise read as "no seam found" and pass. A
  # symbol every shape exports has to be visible before the absence of
  # a seam means anything.
  EXPORTS_FILE="$(mktemp -t companion-exports)"
  if ! nm -gU "$BIN" >"$EXPORTS_FILE"; then
    echo "nm could not inspect $BIN; refusing to package an unchecked release." >&2
    rm -f "$EXPORTS_FILE"
    exit 1
  fi
  EXPORTS="$(cat "$EXPORTS_FILE")"
  rm -f "$EXPORTS_FILE"
  if ! grep -q -E '_companion_free$' <<<"$EXPORTS"; then
    echo "nm found no companion exports in $BIN, so the seam check cannot" >&2
    echo "run (ADR-0018). The symbol table is unreadable or the core is not" >&2
    echo "linked; fix that before packaging a release." >&2
    exit 1
  fi
  # One pattern per gated seam: the check is worth nothing if a seam
  # added later is not named here, so add the symbol when you add the
  # export.
  SEAM="$(grep -o -E '_companion_(new_ephemeral|test_age_ms|test_wire_stub|test_wire_last_json)$' <<<"$EXPORTS" | head -n 1 || true)"
  if [[ -n "$SEAM" ]]; then
    echo "release binary exports ${SEAM#_}, a test-only seam" >&2
    echo "(ADR-0018): bindings/ holds the dev xcframework. Rebuild the release" >&2
    echo "shape with scripts/build-core.sh (no flags) and package again." >&2
    exit 1
  fi
fi

APP=dist/OnetimePad.app
echo "==> Assembling $APP (App $VERSION, FFI $FFI_VERSION, Core $CORE_VERSION, $CONFIG)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OnetimePad"
# The brand art the menu bar item is drawn from (CompanionKit's
# LogoMark, which looks here first). SwiftPM's own resource bundle is
# not what ships: its accessor searches beside the .app, so the app
# carries the asset in Contents/Resources where Bundle.main finds it.
cp shell/Sources/CompanionKit/Resources/onetime-logo-v3-xl.svg "$APP/Contents/Resources/"
# The bundled default keymap, which is the authoritative list of what
# the keyboard does (issue #76, docs/development/keymap-format-and-dispatch.md).
# Here for the same reason as the logo mark: Bundle.main is where the
# app looks first, and a bundle without this file has no shortcuts at
# all.
cp shell/Sources/CompanionKit/Resources/default-keymap.json "$APP/Contents/Resources/"
# CompanionLocalization reads the shipped translations through Bundle.main,
# not SwiftPM's generated accessor (which traps if its bundle is absent).
cp -R shell/Sources/CompanionKit/Resources/*.lproj "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cmp -s THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || {
  echo "app third-party notices do not match the canonical notice" >&2
  exit 1
}
cp shell/OnetimePad-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# A debug build always takes the black dev icon and never an ad-hoc
# render: the dev instance and the installed copy sit in the Dock
# together, and the shade is the only thing that separates them at a
# glance, so it is not something a shade experiment gets to change.
#
# A release build uses whatever OnetimePad icon is already sitting in
# dist/icons/ (the most recently rendered one), so a custom
# scripts/build-icons.sh run right before packaging survives instead of
# being overwritten by a forced rebuild back to the standard shade.
# Only build the standard icon when none exists yet. The glob excludes
# the dev icon by name, or a dev packaging run would leave it as the
# most recent icns and the next release would ship it.
if [[ "$CONFIG" == "debug" ]]; then
  scripts/build-icons.sh --dev
  ICON="dist/icons/OnetimePad-dev.icns"
else
  ICON="$(ls -t dist/icons/OnetimePad*.icns 2>/dev/null \
    | grep -v '/OnetimePad-dev\.icns$' | head -n1 || true)"
  if [[ -z "$ICON" ]]; then
    scripts/build-icons.sh
    ICON="dist/icons/OnetimePad.icns"
  fi
fi
# Finder and the Dock cache icons by bundle metadata. Replacing the
# contents of a fixed AppIcon.icns does not reliably invalidate that
# cache, especially when the app version did not change. Give each
# distinct payload a stable content-addressed resource name and make
# the copied plist point at it, so icon-only builds are observable.
ICON_DIGEST="$(shasum -a 256 "$ICON" | awk '{print $1}')"
if [[ -z "$ICON_DIGEST" ]]; then
  echo "could not hash app icon: $ICON" >&2
  exit 1
fi
ICON_BASENAME="AppIcon-$ICON_DIGEST"
echo "==> App icon: $ICON ($ICON_BASENAME)"
cp "$ICON" "$APP/Contents/Resources/$ICON_BASENAME.icns"
plutil -replace CFBundleIconFile -string "$ICON_BASENAME" "$APP/Contents/Info.plist"

# App Store Connect identifies a build by its build number, so no two
# packaging runs may share one. The counter is read and replaced under an
# exclusive lock held on fd 9, and the new value is written to a file
# beside it and renamed into place, so a reader sees the old number or the
# new one and never a partial write. The lock goes with the process, so a
# killed run cannot leave it held. A number is spent when it is reserved:
# a later failure leaves a gap rather than a number two runs share. An
# explicit number is used as given and raises the counter when it is
# higher, so the next reservation continues above it.
reserve_app_store_build_number() { # <counter file> [explicit number]
  local counter=$1 requested=${2:-} last=0 next staged
  exec 9>>"$counter.lock"
  if ! lockf -s -t 30 9; then
    echo "could not lock the App Store build number counter: $counter.lock" >&2
    exit 1
  fi
  if [[ -e "$counter" ]]; then
    last="$(<"$counter")"
    if [[ ! "$last" =~ ^[0-9]+$ ]]; then
      echo "App Store build number counter does not hold a decimal number: $counter" >&2
      exit 1
    fi
    last=$((10#$last))
  fi
  if [[ -n "$requested" ]]; then
    next=$((10#$requested))
    if ((next <= last)); then
      echo "warning: build number $next is not above the last reserved number $last ($counter)" >&2
    fi
  else
    next=$((last + 1))
  fi
  if ((next > last)); then
    staged="$(mktemp "$counter.XXXXXX")"
    printf '%s\n' "$next" > "$staged"
    mv -f "$staged" "$counter"
  fi
  exec 9>&-
  APP_STORE_BUILD_NUMBER=$next
}

if ((APP_STORE_MODE)); then
  # Keep the App Store build number separate from the marketing version and
  # reserve it only now, after the compile, so a broken build does not
  # spend one.
  reserve_app_store_build_number "$APP_STORE_BUILD_NUMBER_FILE" "$REQUESTED_BUILD_NUMBER"
  echo "==> App Store build number: $APP_STORE_BUILD_NUMBER (counter: $APP_STORE_BUILD_NUMBER_FILE)"
  plutil -replace CFBundleVersion -string "$APP_STORE_BUILD_NUMBER" "$APP/Contents/Info.plist"
else
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
  # Dogfood builds carry the commit in CFBundleVersion so "which build am
  # I on" has a one-glance answer. An uncommitted tree is part of the
  # answer: the SHA alone would claim a build the repo cannot reproduce.
  # Outside a git checkout the plain version stands.
  if SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
    git diff --quiet HEAD 2>/dev/null || SHA="$SHA.dirty"
    plutil -replace CFBundleVersion -string "$VERSION+$SHA" "$APP/Contents/Info.plist"
  fi
fi

# Each lane writes its own id from the manifest: the source plist declares
# the production id, which only the App Store lane keeps. Written outright
# rather than derived from the release id: the development ids share no
# prefix with it, on purpose, so nothing keyed off the id can take one lane
# for a configuration of another.
if [[ "$BUILD_BUNDLE_ID" != "$PRODUCTION_BUNDLE_ID" ]]; then
  plutil -replace CFBundleIdentifier -string "$BUILD_BUNDLE_ID" "$APP/Contents/Info.plist"
fi

if [[ "$CONFIG" == "debug" ]]; then
  # The dev instance also reads as a separate app to the eye, beside the
  # local install.
  BUNDLE_NAME="$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")"
  plutil -replace CFBundleName -string "$BUNDLE_NAME Dev" "$APP/Contents/Info.plist"
  # Both name keys, or the rename reaches the File menu and nothing
  # else: the ⌘Tab switcher, the Dock and the About panel read the
  # display name first, and a bundle whose two names disagree is a
  # bundle that calls itself two things in one session.
  plutil -replace CFBundleDisplayName -string "$BUNDLE_NAME Dev" "$APP/Contents/Info.plist"
fi

# The published artifact is the bundle as assembled, before any
# signature touches it. Hash every regular file by relative path and
# content: relative so the digest reproduces from a different checkout
# directory, and LC_ALL=C so the sort order is byte order rather than
# whatever the caller's locale collates to.
DIGEST_FILE="dist/$(basename "$APP" .app).presig.sha256"
echo "==> Pre-signature digest"
DIGEST="$(cd "$APP" && LC_ALL=C find . -type f -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | cut -d ' ' -f 1)"
if [[ -z "$DIGEST" ]]; then
  echo "pre-signature digest came out empty" >&2
  exit 1
fi
printf '%s  %s\n' "$DIGEST" "${APP##*/}" > "$DIGEST_FILE"
echo "$DIGEST  ${APP##*/} (pre-signature, $DIGEST_FILE)"

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign ($BUILD_LANE: ${CODESIGN_IDENTITY:-ad-hoc})"
if [[ "$IDENTITY" == "-" ]]; then
  # An ad-hoc signature has no Team ID, so it cannot carry
  # keychain-access-groups. Expected for unconfigured dev/local builds:
  # the credentials layer sees errSecMissingEntitlement and falls back
  # (ADR-0012).
  echo "    warning: ad-hoc signature, so scripts/Companion.entitlements is not applied." >&2
  echo "    warning: the data protection keychain is unavailable in this build; the" >&2
  echo "    warning: credentials layer falls back to the file based login keychain." >&2
  echo "    warning: configure this lane's CODESIGN identity in $BUILD_ENVIRONMENT_FILE for stable signing." >&2
  codesign --force --sign "$IDENTITY" "$APP"
elif [[ -z "$TEAM_ID" ]]; then
  echo "    warning: could not read a Team ID from the signing certificate, so" >&2
  echo "    warning: scripts/Companion.entitlements is not applied and the data" >&2
  echo "    warning: protection keychain stays unavailable (login keychain fallback)." >&2
  codesign --force --sign "$IDENTITY" "$APP"
elif [[ -n "$PROVISIONING_PROFILE" ]]; then
  # The profile is machine-bound signing material, embedded after the
  # pre-signature digest on purpose: hashing it would make the digest
  # differ per machine. Profile/team/app/certificate/device compatibility
  # was checked before any build or bundle replacement began.
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  echo "==> embedded provisioning profile: $PROVISIONING_PROFILE"
  SIGNED_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
  ACCESS_GROUP="${TEAM_ID}.${SIGNED_BUNDLE_ID}"

  SIGN_ENTITLEMENTS="$(mktemp -t companion-entitlements)"
  sed -e "s/\$(AppIdentifierPrefix)/${TEAM_ID}./g" \
      -e "s/@BUNDLE_IDENTIFIER@/${SIGNED_BUNDLE_ID}/g" \
      scripts/Companion.entitlements > "$SIGN_ENTITLEMENTS"
  if ((APP_STORE_MODE)); then
    # Embedding the profile does not copy its identity into the signature.
    # TestFlight checks the signed application identifier against the profile.
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$SIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$SIGN_ENTITLEMENTS"
  fi
  # codesign's AMFI XML parser rejects some otherwise valid plist
  # serialization styles, including `<true />`. Round-trip the rendered
  # template through binary form to produce Apple's canonical XML.
  plutil -convert binary1 "$SIGN_ENTITLEMENTS"
  plutil -convert xml1 "$SIGN_ENTITLEMENTS"
  echo "==> entitlements: app sandbox, outgoing network, keychain-access-group $ACCESS_GROUP"
  if ((APP_STORE_MODE)); then
    codesign --force --options runtime --entitlements "$SIGN_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  else
    codesign --force --entitlements "$SIGN_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  fi
  rm -f "$SIGN_ENTITLEMENTS"
else
  echo "    warning: the $BUILD_LANE provisioning profile is unset, so" >&2
  echo "    warning: scripts/Companion.entitlements is not applied. See" >&2
  echo "    warning: environments/example/.env.example for development-profile setup." >&2
  codesign --force --sign "$IDENTITY" "$APP"
fi

echo "==> Verifying $APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
cmp -s THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || {
  echo "signed app third-party notices do not match the canonical notice" >&2
  exit 1
}
cmp -s THIRD_PARTY_NOTICES.md bindings/CompanionCore.xcframework/THIRD_PARTY_NOTICES.md || {
  echo "final xcframework third-party notices do not match the canonical notice" >&2
  exit 1
}

if ((APP_STORE_MODE)); then
  ACTUAL_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
  if [[ "$ACTUAL_BUILD_NUMBER" != "$APP_STORE_BUILD_NUMBER" ]]; then
    echo "signed app build number $ACTUAL_BUILD_NUMBER does not match $APP_STORE_BUILD_NUMBER" >&2
    exit 1
  fi
  if ! cmp -s "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"; then
    echo "signed app does not contain the requested provisioning profile" >&2
    exit 1
  fi

  SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
  if ! grep -Fq "Authority=$CODESIGN_IDENTITY" <<<"$SIGNATURE_DETAILS"; then
    echo "signed app does not report the requested application identity" >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*\(runtime\)' <<<"$SIGNATURE_DETAILS"; then
    echo "signed app does not have the hardened runtime flag" >&2
    exit 1
  fi

  SIGNED_ENTITLEMENTS="$(mktemp -t onetimepad-signed-entitlements)"
  if ! codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null; then
    rm -f "$SIGNED_ENTITLEMENTS"
    echo "could not read entitlements from the signed app" >&2
    exit 1
  fi
  SIGNED_SANDBOX="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  SIGNED_NETWORK="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  SIGNED_ACCESS_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  SIGNED_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  SIGNED_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  rm -f "$SIGNED_ENTITLEMENTS"
  if [[ "$SIGNED_APP_ID" != "$PROFILE_APP_ID" || "$SIGNED_TEAM_ID" != "$TEAM_ID" ]]; then
    echo "signed app application/team identifiers do not match the provisioning profile and signing team" >&2
    exit 1
  fi
  if [[ "$SIGNED_SANDBOX" != "true" || "$SIGNED_NETWORK" != "true" || "$SIGNED_ACCESS_GROUP" != "$ACCESS_GROUP" ]]; then
    echo "signed app entitlements do not match the App Store distribution requirements" >&2
    exit 1
  fi

  PKG=dist/OnetimePad.pkg
  rm -f "$PKG"
  echo "==> productbuild $PKG"
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
  echo "==> Verifying $PKG"
  if ! PKG_SIGNATURE="$(pkgutil --check-signature "$PKG" 2>&1)"; then
    printf '%s\n' "$PKG_SIGNATURE" >&2
    exit 1
  fi
  printf '%s\n' "$PKG_SIGNATURE"
  if ! grep -Fq "$INSTALLER_IDENTITY" <<<"$PKG_SIGNATURE"; then
    echo "installer package does not report the requested installer identity" >&2
    exit 1
  fi
  echo "Built $APP and $PKG (App Store build $APP_STORE_BUILD_NUMBER)."
else
  echo "Built $APP. Launch with: open $APP"
fi
