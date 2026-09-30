"""Exercise provisioning-profile compatibility checks with synthetic plists."""

import plistlib
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts/validate-provisioning-profile.py"
TEAM = "TESTTEAM01"
BUNDLE = "com.example.pad"
CERTIFICATE = b"synthetic-certificate-der"
DEVICE = "TEST-DEVICE-UDID"


class ProvisioningProfileValidationTests(unittest.TestCase):
    def profile(self, profile_class):
        entitlements = {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
            "keychain-access-groups": [f"{TEAM}.*"],
        }
        profile = {
            "Name": f"Synthetic {profile_class}",
            "TeamIdentifier": [TEAM],
            "DeveloperCertificates": [CERTIFICATE],
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
            "Entitlements": entitlements,
        }
        if profile_class == "development":
            # As the portal issues it: a device list and no get-task-allow.
            profile["ProvisionedDevices"] = [DEVICE]
        return profile

    def validate(
        self, profile, profile_class, *, certificate=CERTIFICATE, device=None
    ):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            profile_path = directory / "profile.plist"
            certificate_path = directory / "certificate.der"
            profile_path.write_bytes(plistlib.dumps(profile))
            certificate_path.write_bytes(certificate)
            command = [
                "python3",
                str(VALIDATOR),
                "--profile-plist",
                str(profile_path),
                "--certificate-der",
                str(certificate_path),
                "--team-id",
                TEAM,
                "--bundle-id",
                BUNDLE,
                "--profile-class",
                profile_class,
            ]
            if device is not None:
                command.extend(("--device-udid", device))
            return subprocess.run(
                command, capture_output=True, text=True, check=False
            )

    def test_matching_development_profile_is_accepted(self):
        result = self.validate(
            self.profile("development"), "development", device=DEVICE
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_matching_app_store_profile_is_accepted(self):
        result = self.validate(self.profile("app-store"), "app-store")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_app_store_profile_is_rejected_for_direct_install(self):
        result = self.validate(
            self.profile("app-store"), "development", device=DEVICE
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a macOS development profile", result.stderr)
        self.assertIn("contains no provisioned devices", result.stderr)

    def test_development_profile_must_authorize_this_mac(self):
        result = self.validate(
            self.profile("development"), "development", device="OTHER-DEVICE"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not authorize this Mac", result.stderr)

    def test_profile_must_include_selected_certificate(self):
        result = self.validate(
            self.profile("development"),
            "development",
            certificate=b"different-certificate",
            device=DEVICE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "does not include the selected signing certificate", result.stderr
        )

    def test_profile_must_authorize_bundle_and_keychain_group(self):
        profile = self.profile("development")
        profile["Entitlements"]["com.apple.application-identifier"] = (
            f"{TEAM}.other"
        )
        profile["Entitlements"]["keychain-access-groups"] = [f"{TEAM}.other"]
        result = self.validate(profile, "development", device=DEVICE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not authorize", result.stderr)
        self.assertIn("keychain access groups", result.stderr)

    def test_expired_profile_is_rejected(self):
        profile = self.profile("development")
        profile["ExpirationDate"] = datetime.now(timezone.utc) - timedelta(
            seconds=1
        )
        result = self.validate(profile, "development", device=DEVICE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expired", result.stderr)


if __name__ == "__main__":
    unittest.main()
