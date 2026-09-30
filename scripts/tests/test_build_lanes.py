"""Exercise lane-specific build metadata and signing-variable selection."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "scripts/build-lanes.sh"
SIGNING_VARIABLES = (
    "CODESIGN_IDENTITY",
    "INSTALLER_IDENTITY",
    "PROVISIONING_PROFILE",
)
PREFIXES = ("DEV_", "LOCAL_", "APP_STORE_")
SELECTION = (
    'printf "%s|%s|%s|%s|%s|%s\\n" "$CONFIG" "$BUILD_BUNDLE_ID" '
    '"$CODESIGN_IDENTITY" "$INSTALLER_IDENTITY" '
    '"$PROVISIONING_PROFILE" "$PROFILE_CLASS"'
)


class BuildLaneTests(unittest.TestCase):
    def setUp(self):
        # Each test runs from an empty checkout stand-in and an empty
        # environments directory, so this Mac's real signing files never
        # reach the assertions.
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.checkout = Path(scratch.name) / "checkout"
        self.environments = Path(scratch.name) / "environments"
        self.checkout.mkdir()
        self.environments.mkdir()

    def run_shell(self, script, env=None):
        inherited = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(PREFIXES) and k not in SIGNING_VARIABLES
        }
        return subprocess.run(
            ["bash", "-euc", f'source "{MANIFEST}"\n{script}'],
            cwd=self.checkout,
            env={
                **inherited,
                "ONETIMEPAD_ENVIRONMENTS_DIR": str(self.environments),
                **(env or {}),
            },
            capture_output=True,
            text=True,
            check=False,
        )

    def write_environment(self, name, text):
        directory = self.environments / name
        directory.mkdir()
        (directory / ".env").write_text(text)

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
                result = self.run_shell(f"select_build_lane {lane}\n{SELECTION}", env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), values)

    def test_each_lane_reads_only_its_own_environment_file(self):
        # Every file assigns every lane's prefix, so a lane that read another
        # lane's file would print that file's values.
        for name in ("dev", "local", "staging"):
            self.write_environment(
                name,
                "".join(
                    f'{prefix}{variable}="{name}-file"\n'
                    for prefix in PREFIXES
                    for variable in SIGNING_VARIABLES
                ),
            )
        expected = {
            "dev": f"{self.environments}/dev/.env|dev-file||dev-file",
            "local": f"{self.environments}/local/.env|local-file||local-file",
            "app-store": f"{self.environments}/staging/.env|staging-file|staging-file|staging-file",
        }
        for lane, values in expected.items():
            with self.subTest(lane=lane):
                result = self.run_shell(
                    f"select_build_lane {lane}\n"
                    'printf "%s|%s|%s|%s\\n" "$BUILD_ENVIRONMENT_FILE" '
                    '"$CODESIGN_IDENTITY" "$INSTALLER_IDENTITY" '
                    '"$PROVISIONING_PROFILE"'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), values)

    def test_environment_file_values_override_inherited_ones(self):
        self.write_environment("local", 'LOCAL_CODESIGN_IDENTITY="from-file"\n')
        result = self.run_shell(
            'select_build_lane local\necho "$CODESIGN_IDENTITY"',
            {"LOCAL_CODESIGN_IDENTITY": "inherited"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "from-file")

    def test_environment_file_expands_home(self):
        self.write_environment(
            "staging", 'APP_STORE_PROVISIONING_PROFILE="$HOME/profile"\n'
        )
        result = self.run_shell(
            'select_build_lane app-store\necho "$PROVISIONING_PROFILE"',
            {"HOME": "/home-for-test"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/home-for-test/profile")

    def test_missing_environment_file_leaves_the_lane_unsigned(self):
        for lane in ("dev", "local", "app-store"):
            with self.subTest(lane=lane):
                result = self.run_shell(
                    f"select_build_lane {lane}\n"
                    'printf "%s|%s|%s\\n" "$CODESIGN_IDENTITY" '
                    '"$INSTALLER_IDENTITY" "$PROVISIONING_PROFILE"'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "||")

    def test_default_environments_directory_is_under_home(self):
        result = subprocess.run(
            ["bash", "-euc", f'source "{MANIFEST}"\necho "$ENVIRONMENTS_DIR"'],
            cwd=self.checkout,
            env={
                k: v
                for k, v in os.environ.items()
                if k != "ONETIMEPAD_ENVIRONMENTS_DIR"
            }
            | {"HOME": "/home-for-test"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "/home-for-test/.local/appledev/CompanionApp/environments",
        )

    def test_unknown_lane_is_rejected(self):
        result = self.run_shell("select_build_lane production")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown build lane", result.stderr)

    def test_legacy_global_values_are_rejected(self):
        for variable in SIGNING_VARIABLES:
            with self.subTest(variable=variable):
                result = self.run_shell(
                    "reject_legacy_signing_configuration",
                    {variable: "unsafe-shared-value"},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no longer accepted", result.stderr)

    def test_legacy_global_values_in_an_environment_file_are_rejected(self):
        self.write_environment("local", 'CODESIGN_IDENTITY="unsafe-shared-value"\n')
        result = self.run_shell("select_build_lane local")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no longer accepted", result.stderr)

    def test_legacy_checkout_file_is_rejected(self):
        (self.checkout / "scripts").mkdir()
        (self.checkout / "scripts/local.env").write_text("")
        for lane in ("dev", "local", "app-store"):
            with self.subTest(lane=lane):
                result = self.run_shell(f"select_build_lane {lane}")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("scripts/local.env is no longer read", result.stderr)


if __name__ == "__main__":
    unittest.main()
