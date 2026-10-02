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
    'printf "%s|%s|%s|%s|%s|%s|%s\\n" "$CONFIG" "$BUILD_BUNDLE_ID" '
    '"$BUILD_APP_NAME" "$CODESIGN_IDENTITY" "$INSTALLER_IDENTITY" '
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

    def write_every_environment(self):
        # Every file assigns all three names, so a lane that read another
        # lane's file would print that file's values.
        for name in ("dev", "local", "staging"):
            self.write_environment(
                name,
                "".join(
                    f'{variable}="{name}-file"\n' for variable in SIGNING_VARIABLES
                ),
            )

    def test_each_lane_selects_its_metadata_and_its_own_signing_values(self):
        # The dev and local files name an installer identity too; only the
        # App Store lane keeps one.
        self.write_every_environment()
        expected = {
            "dev": "debug|dev.onetimesecret.pad.debug|OnetimePad Debug|dev-file||dev-file|development",
            "local": "release|dev.onetimesecret.pad|OnetimePad Local|local-file||local-file|development",
            "app-store": "release|com.onetimesecret.pad|OnetimePad|staging-file|staging-file|staging-file|app-store",
        }
        for lane, values in expected.items():
            with self.subTest(lane=lane):
                result = self.run_shell(f"select_build_lane {lane}\n{SELECTION}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), values)

    def test_each_lane_reads_only_its_own_environment_file(self):
        self.write_every_environment()
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
        self.write_environment("local", 'CODESIGN_IDENTITY="from-file"\n')
        result = self.run_shell(
            'select_build_lane local\necho "$CODESIGN_IDENTITY"',
            {"CODESIGN_IDENTITY": "inherited"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "from-file")

    def test_inherited_signing_values_are_discarded(self):
        # What another environment's .envrc exported into the shell must not
        # sign this lane, whether its file is absent or leaves a name out.
        inherited = {variable: "inherited" for variable in SIGNING_VARIABLES}
        selection = (
            'printf "%s|%s|%s\\n" "$CODESIGN_IDENTITY" '
            '"$INSTALLER_IDENTITY" "$PROVISIONING_PROFILE"'
        )
        for lane in ("dev", "local", "app-store"):
            with self.subTest(lane=lane, file="absent"):
                result = self.run_shell(
                    f"select_build_lane {lane}\n{selection}", inherited
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "||")
        self.write_environment("local", 'CODESIGN_IDENTITY="from-file"\n')
        result = self.run_shell(f"select_build_lane local\n{selection}", inherited)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "from-file||")

    def test_environment_file_expands_home(self):
        self.write_environment(
            "staging", 'PROVISIONING_PROFILE="$HOME/profile"\n'
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

    def test_lane_prefixed_names_in_an_environment_file_are_rejected(self):
        for prefix in PREFIXES:
            for variable in SIGNING_VARIABLES:
                name = f"{prefix}{variable}"
                with self.subTest(name=name):
                    (self.environments / "local").mkdir(exist_ok=True)
                    (self.environments / "local/.env").write_text(
                        f'{name}="stale"\n'
                    )
                    result = self.run_shell("select_build_lane local")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"{name} is no longer read", result.stderr)
                    self.assertIn(f"Rename it to {variable}", result.stderr)

    def test_inherited_lane_prefixed_names_are_ignored(self):
        # A shell that loaded an environment before the rename still exports
        # the old names; only a file that uses them is refused.
        self.write_environment("local", 'CODESIGN_IDENTITY="from-file"\n')
        result = self.run_shell(
            'select_build_lane local\necho "$CODESIGN_IDENTITY"',
            {"LOCAL_CODESIGN_IDENTITY": "stale"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "from-file")

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
