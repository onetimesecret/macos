"""Exercise lane-specific build metadata and signing-variable selection."""

import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "scripts/build-lanes.sh"


class BuildLaneTests(unittest.TestCase):
    def run_shell(self, script, env=None):
        return subprocess.run(
            ["bash", "-euc", f'source "{MANIFEST}"\n{script}'],
            cwd=ROOT,
            env={**os.environ, **(env or {})},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_each_lane_selects_only_its_own_signing_values(self):
        env = {
            "DEV_CODESIGN_IDENTITY": "dev-sign",
            "DEV_PROVISIONING_PROFILE": "dev-profile",
            "LOCAL_CODESIGN_IDENTITY": "local-sign",
            "LOCAL_PROVISIONING_PROFILE": "local-profile",
            "APP_STORE_CODESIGN_IDENTITY": "store-sign",
            "APP_STORE_INSTALLER_IDENTITY": "installer-sign",
            "APP_STORE_PROVISIONING_PROFILE": "store-profile",
        }
        expected = {
            "dev": "debug|dev.onetimesecret.pad|dev-sign||dev-profile|development",
            "local": "release|com.onetimesecret.pad|local-sign||local-profile|development",
            "app-store": "release|com.onetimesecret.pad|store-sign|installer-sign|store-profile|app-store",
        }
        for lane, values in expected.items():
            with self.subTest(lane=lane):
                result = self.run_shell(
                    f"select_build_lane {lane}\n"
                    'printf "%s|%s|%s|%s|%s|%s\\n" "$CONFIG" "$BUILD_BUNDLE_ID" '
                    '"$CODESIGN_IDENTITY" "$INSTALLER_IDENTITY" '
                    '"$PROVISIONING_PROFILE" "$PROFILE_CLASS"',
                    env,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), values)

    def test_legacy_global_values_are_rejected(self):
        for variable in (
            "CODESIGN_IDENTITY",
            "INSTALLER_IDENTITY",
            "PROVISIONING_PROFILE",
        ):
            with self.subTest(variable=variable):
                result = self.run_shell(
                    "reject_legacy_signing_configuration",
                    {variable: "unsafe-shared-value"},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no longer accepted", result.stderr)


if __name__ == "__main__":
    unittest.main()
