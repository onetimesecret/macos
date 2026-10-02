#!/usr/bin/env bash
# Checked-in metadata for the three app build lanes. Machine-local certificate
# names and profile paths live outside every checkout, one directory per build
# environment, so every worktree on a Mac reads the same values:
#
#   $ONETIMEPAD_ENVIRONMENTS_DIR/<environment>/.env
#
# The dev lane reads the dev environment, the local lane reads local, and the
# app-store lane reads staging. Every file uses the same three names,
# CODESIGN_IDENTITY, PROVISIONING_PROFILE and INSTALLER_IDENTITY, and a lane
# takes them from its own file and nowhere else: values inherited from the
# calling shell are discarded first, so what one environment's .envrc exports
# cannot sign another lane's build. environments/example/ is the checked in
# template for one environment directory: copy it out of the checkout once per
# environment and rename .env.example to .env in each copy.

# App Store builds, staging (TestFlight) and production, ship under the
# production id. The local and dev lanes are development builds and share the
# dev.onetimesecret.pad family, each under its own id so neither reads the
# other's state or Keychain items.
PRODUCTION_BUNDLE_ID="com.onetimesecret.pad"
LOCAL_BUNDLE_ID="dev.onetimesecret.pad"
DEV_BUNDLE_ID="dev.onetimesecret.pad.debug"
# Bundle file names. Only App Store builds take the plain name, so a local
# install never replaces /Applications/OnetimePad.app, the path a TestFlight
# install occupies, and a debug bundle never reads as either in Finder.
PRODUCTION_APP_NAME="OnetimePad"
LOCAL_APP_NAME="OnetimePad Local"
DEV_APP_NAME="OnetimePad Debug"
ENVIRONMENTS_DIR="${ONETIMEPAD_ENVIRONMENTS_DIR:-$HOME/.local/appledev/CompanionApp/environments}"

SIGNING_VARIABLES=(CODESIGN_IDENTITY INSTALLER_IDENTITY PROVISIONING_PROFILE)
LEGACY_SIGNING_PREFIXES=(DEV_ LOCAL_ APP_STORE_)

# Called after the environment file is sourced, with every lane-prefixed name
# unset beforehand, so a prefixed name that is set here came from the file.
reject_legacy_signing_configuration() {
  local prefix variable name
  if [[ -e scripts/local.env ]]; then
    echo "scripts/local.env is no longer read. Move each lane's values into" >&2
    echo "$ENVIRONMENTS_DIR/<dev|local|staging>/.env, then delete it." >&2
    return 1
  fi
  for prefix in "${LEGACY_SIGNING_PREFIXES[@]}"; do
    for variable in "${SIGNING_VARIABLES[@]}"; do
      name="$prefix$variable"
      if [[ -n "${!name:-}" ]]; then
        echo "$name is no longer read. Rename it to $variable in $BUILD_ENVIRONMENT_FILE;" >&2
        echo "each lane reads only its own environment file. See environments/example/." >&2
        return 1
      fi
    done
  done
}

# The environment file is the only source of a lane's signing values. Inherited
# ones are dropped before it is read, so a missing file, or a name the file
# leaves out, leaves that value empty. Sourcing sits inside an if so a file
# whose final statement returns non zero fails here with a message instead of
# killing the caller silently.
load_build_environment() {
  local prefix variable
  BUILD_ENVIRONMENT_FILE="$ENVIRONMENTS_DIR/$BUILD_ENVIRONMENT/.env"
  for variable in "${SIGNING_VARIABLES[@]}"; do
    unset "$variable"
    for prefix in "${LEGACY_SIGNING_PREFIXES[@]}"; do
      unset "$prefix$variable"
    done
  done
  if [[ -f "$BUILD_ENVIRONMENT_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BUILD_ENVIRONMENT_FILE" || { echo "failed to source $BUILD_ENVIRONMENT_FILE" >&2; return 1; }
  fi
  reject_legacy_signing_configuration || return 1
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
  INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
  PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
}

select_build_lane() { # <dev|local|app-store>
  BUILD_LANE="$1"

  case "$BUILD_LANE" in
    dev) BUILD_ENVIRONMENT="dev" ;;
    local) BUILD_ENVIRONMENT="local" ;;
    app-store) BUILD_ENVIRONMENT="staging" ;;
    *)
      echo "unknown build lane: $BUILD_LANE" >&2
      return 1
      ;;
  esac
  load_build_environment || return 1

  case "$BUILD_LANE" in
    dev)
      CONFIG="debug"
      BUILD_BUNDLE_ID="$DEV_BUNDLE_ID"
      BUILD_APP_NAME="$DEV_APP_NAME"
      INSTALLER_IDENTITY=""
      PROFILE_CLASS="development"
      ;;
    local)
      CONFIG="release"
      BUILD_BUNDLE_ID="$LOCAL_BUNDLE_ID"
      BUILD_APP_NAME="$LOCAL_APP_NAME"
      INSTALLER_IDENTITY=""
      PROFILE_CLASS="development"
      ;;
    app-store)
      CONFIG="release"
      BUILD_BUNDLE_ID="$PRODUCTION_BUNDLE_ID"
      BUILD_APP_NAME="$PRODUCTION_APP_NAME"
      PROFILE_CLASS="app-store"
      ;;
  esac
}
