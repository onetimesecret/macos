#!/usr/bin/env bash
# Checked-in metadata for the three app build lanes. Machine-local certificate
# names and profile paths belong in scripts/local.env under the matching prefix.

PRODUCTION_BUNDLE_ID="com.onetimesecret.pad"
DEV_BUNDLE_ID="dev.onetimesecret.pad"

reject_legacy_signing_configuration() {
  local variable
  for variable in CODESIGN_IDENTITY INSTALLER_IDENTITY PROVISIONING_PROFILE; do
    if [[ -n "${!variable:-}" ]]; then
      echo "$variable is no longer accepted because it applies one signing value to every build lane." >&2
      echo "Use DEV_*, LOCAL_*, or APP_STORE_* in scripts/local.env; see scripts/local.env.example." >&2
      return 1
    fi
  done
}

select_build_lane() { # <dev|local|app-store>
  BUILD_LANE="$1"
  INSTALLER_IDENTITY=""

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
      BUILD_BUNDLE_ID="$PRODUCTION_BUNDLE_ID"
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
    *)
      echo "unknown build lane: $BUILD_LANE" >&2
      return 1
      ;;
  esac
}
