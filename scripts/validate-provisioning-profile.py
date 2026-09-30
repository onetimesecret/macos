"""Validate a decoded macOS provisioning profile against one build lane."""

import argparse
import plistlib
import sys
from datetime import datetime, timezone
from pathlib import Path


def authorizes(pattern: str, value: str) -> bool:
    """Return whether an exact or terminal-wildcard profile value allows value."""
    if pattern == value:
        return True
    return pattern.endswith("*") and value.startswith(pattern[:-1])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile-plist", required=True, type=Path)
    parser.add_argument("--certificate-der", required=True, type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument(
        "--profile-class", required=True, choices=("development", "app-store")
    )
    parser.add_argument("--device-udid")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        profile = plistlib.loads(args.profile_plist.read_bytes())
        certificate = args.certificate_der.read_bytes()
    except (OSError, plistlib.InvalidFileException) as error:
        print(f"could not read provisioning metadata: {error}", file=sys.stderr)
        return 1

    errors: list[str] = []
    entitlements = profile.get("Entitlements", {})
    expected_app_id = f"{args.team_id}.{args.bundle_id}"

    teams = profile.get("TeamIdentifier", [])
    if args.team_id not in teams:
        errors.append(
            f"profile team {teams!r} does not include signing team {args.team_id}"
        )

    profile_app_id = entitlements.get("com.apple.application-identifier")
    if not isinstance(profile_app_id, str) or not authorizes(
        profile_app_id, expected_app_id
    ):
        errors.append(
            f"profile App ID {profile_app_id!r} does not authorize {expected_app_id}"
        )

    access_groups = entitlements.get("keychain-access-groups", [])
    if not isinstance(access_groups, list) or not any(
        isinstance(group, str) and authorizes(group, expected_app_id)
        for group in access_groups
    ):
        errors.append(
            f"profile keychain access groups do not authorize {expected_app_id}"
        )

    certificates = profile.get("DeveloperCertificates", [])
    if certificate not in certificates:
        errors.append(
            "profile does not include the selected signing certificate"
        )

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        errors.append("profile has no readable expiration date")
    else:
        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=timezone.utc)
        if expiration <= datetime.now(timezone.utc):
            errors.append(f"profile expired at {expiration.isoformat()}")

    provisioned_devices = profile.get("ProvisionedDevices", [])
    get_task_allow = entitlements.get("get-task-allow")
    if args.profile_class == "development":
        if get_task_allow is not True:
            errors.append("profile is not a macOS development profile")
        if not isinstance(provisioned_devices, list) or not provisioned_devices:
            errors.append("development profile contains no provisioned devices")
        elif not args.device_udid:
            errors.append(
                "this Mac's Provisioning UDID could not be determined"
            )
        elif args.device_udid not in provisioned_devices:
            errors.append(
                f"development profile does not authorize this Mac ({args.device_udid})"
            )
    else:
        if get_task_allow is True:
            errors.append("App Store lane cannot use a development profile")
        if provisioned_devices:
            errors.append(
                "App Store profile unexpectedly contains provisioned devices"
            )
        if profile_app_id != expected_app_id:
            errors.append(
                f"App Store profile must use explicit App ID {expected_app_id}, got {profile_app_id!r}"
            )

    if errors:
        name = profile.get("Name", args.profile_plist.name)
        for error in errors:
            print(f"provisioning profile {name!r}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
