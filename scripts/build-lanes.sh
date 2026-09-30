#!/usr/bin/env bash
# Checked-in metadata for the three app build lanes. Machine-local certificate
# names and profile paths live outside every checkout, one directory per build
# environment, so every worktree on a Mac reads the same values:
#
#   $ONETIMEPAD_ENVIRONMENTS_DIR/<environment>/.env
#
# The dev lane reads the dev environment, the local lane reads local, and the
# app-store lane reads staging. Each file keeps its lane's prefix (DEV_*,
# LOCAL_*, or APP_STORE_*), so values a shell exports from one environment's
# .envrc cannot sign another lane's build. environments/example/ is the
# checked in template for one environment directory: copy it out of the
# checkout once per environment and rename .env.example to .env in each copy.

# App Store builds, staging (TestFlight) and production, ship under the
# production id. The local and dev lanes are development builds and share the
# dev.onetimesecret.pad family, each under its own id so neither reads the
# other's state or Keychain items.
PRODUCTION_BUNDLE_ID="com.onetimesecret.pad"
LOCAL_BUNDLE_ID="dev.onetimesecret.pad"
DEV_BUNDLE_ID="dev.onetimesecret.pad.debug"
ENVIRONMENTS_DIR="${ONETIMEPAD_ENVIRONMENTS_DIR:-$HOME/.local/appledev/CompanionApp/environments}"

reject_legacy_signing_configuration() {
  local variable
  if [[ -e scripts/local.env ]]; then
    echo "scripts/local.env is no longer read. Move each lane's values into" >&2
    echo "$ENVIRONMENTS_DIR/<dev|local|staging>/.env, then delete it." >&2
    return 1
  fi
  for variable in CODESIGN_IDENTITY INSTALLER_IDENTITY PROVISIONING_PROFILE; do
    if [[ -n "${!variable:-}" ]]; then
      echo "$variable is no longer accepted because it applies one signing value to every build lane." >&2
      echo "Use DEV_*, LOCAL_*, or APP_STORE_* in the lane's environment file; see environments/example/." >&2
      return 1
    fi
  done
}

# Values assigned in the environment file take precedence over inherited ones.
# A missing file leaves the lane to its inherited values. Sourcing sits inside
# an if so a file whose final statement returns non zero fails here with a
# message instead of killing the caller silently.
load_build_environment() {
  BUILD_ENVIRONMENT_FILE="$ENVIRONMENTS_DIR/$BUILD_ENVIRONMENT/.env"
  if [[ -f "$BUILD_ENVIRONMENT_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BUILD_ENVIRONMENT_FILE" || { echo "failed to source $BUILD_ENVIRONMENT_FILE" >&2; return 1; }
  fi
  reject_legacy_signing_configuration
}

select_build_lane() { # <dev|local|app-store>
  BUILD_LANE="$1"
  INSTALLER_IDENTITY=""

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
      CODESIGN_IDENTITY="${DEV_CODESIGN_IDENTITY:-}"
      PROVISIONING_PROFILE="${DEV_PROVISIONING_PROFILE:-}"
      PROFILE_CLASS="development"
      ;;
    local)
      CONFIG="release"
      BUILD_BUNDLE_ID="$LOCAL_BUNDLE_ID"
      CODESIGN_IDENTITY="${LOCAL_CODESIGN_IDENTITY:-}"
      PROVISIONING_PROFILE="${LOCAL_PROVISIONING_PROFILE:-}"
      PROFILE_CLASS="development"
      ;;
    app-store)
      CONFIG="release"
      BUILD_BUNDLE_ID="$PRODUCTION_BUNDLE_ID"
      CODESIGN_IDENTITY="${APP_STORE_CODESIGN_IDENTITY:-}"
      INSTALLER_IDENTITY="${APP_STORE_INSTALLER_IDENTITY:-}"
      PROVISIONING_PROFILE="${APP_STORE_PROVISIONING_PROFILE:-}"
      PROFILE_CLASS="app-store"
      ;;
  esac
}
