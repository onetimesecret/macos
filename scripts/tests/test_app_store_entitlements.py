"""Exercise the packaging script's entitlement rendering and read-back checks.

No signing identity, profile, compilation, or replacement of dist/ is needed.
"""

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()
USER_SELECTED_FILES = "com.apple.security.files.user-selected.read-write"


@unittest.skipUnless(sys.platform == "darwin", "requires Apple's plist tools")
class AppStoreEntitlementsTests(unittest.TestCase):
    def render(self, directory, app_store):
        start = SCRIPT.index('  SIGN_ENTITLEMENTS="$(mktemp')
        end = SCRIPT.index('  echo "==> entitlements:', start)
        output = Path(directory) / "entitlements.plist"
        subprocess.run(
            [
                "bash",
                "-euc",
                SCRIPT[start:end] + '\nmv "$SIGN_ENTITLEMENTS" "$OUTPUT"',
            ],
            cwd=ROOT,
            env={
                **os.environ,
                "APP_STORE_MODE": str(app_store),
                "TEAM_ID": "TESTTEAM01",
                "SIGNED_BUNDLE_ID": "com.example.test",
                "PROFILE_APP_ID": "TESTTEAM01.com.example.test",
                "OUTPUT": str(output),
            },
            check=True,
            capture_output=True,
            text=True,
        )
        return plistlib.loads(output.read_bytes())

    def verify(self, directory, entitlements):
        path = Path(directory) / "signed.plist"
        path.write_bytes(plistlib.dumps(entitlements))
        start = SCRIPT.index("  SIGNED_SANDBOX=")
        end = SCRIPT.index("  PKG=dist/", start)
        return subprocess.run(
            ["bash", "-euc", SCRIPT[start:end]],
            cwd=ROOT,
            env={
                **os.environ,
                "SIGNED_ENTITLEMENTS": str(path),
                "ACCESS_GROUP": "TESTTEAM01.com.example.test",
                "PROFILE_APP_ID": "TESTTEAM01.com.example.test",
                "TEAM_ID": "TESTTEAM01",
            },
            capture_output=True,
            text=True,
        )

    def test_app_store_signs_profile_identity_and_verifies_it(self):
        with tempfile.TemporaryDirectory() as directory:
            entitlements = self.render(directory, 1)
            self.assertEqual(
                entitlements.get("com.apple.application-identifier"),
                "TESTTEAM01.com.example.test",
            )
            self.assertEqual(
                entitlements.get("com.apple.developer.team-identifier"),
                "TESTTEAM01",
            )
            self.assertEqual(self.verify(directory, entitlements).returncode, 0)

    def test_missing_or_mismatched_identity_is_rejected(self):
        for key in (
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
        ):
            for value in (None, "WRONG"):
                with (
                    self.subTest(key=key, value=value),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    entitlements = self.render(directory, 1)
                    if value is None:
                        entitlements.pop(key, None)
                    else:
                        entitlements[key] = value
                    self.assertNotEqual(
                        self.verify(directory, entitlements).returncode, 0
                    )

    def test_user_selected_file_access_is_rendered_and_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            entitlements = self.render(directory, 1)
            self.assertIs(entitlements.get(USER_SELECTED_FILES), True)
            result = self.verify(directory, entitlements)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_false_user_selected_file_access_is_rejected(self):
        # A sandboxed build without the entitlement signs and launches; it
        # fails only when a person opens a file, so the read back must name it.
        for value in (None, False):
            with (
                self.subTest(value=value),
                tempfile.TemporaryDirectory() as directory,
            ):
                entitlements = self.render(directory, 1)
                if value is None:
                    entitlements.pop(USER_SELECTED_FILES)
                else:
                    entitlements[USER_SELECTED_FILES] = value
                result = self.verify(directory, entitlements)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(USER_SELECTED_FILES, result.stderr)

    def test_a_missing_sandbox_or_network_entitlement_is_rejected(self):
        for key in (
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
        ):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                entitlements = self.render(directory, 1)
                entitlements.pop(key)
                self.assertNotEqual(
                    self.verify(directory, entitlements).returncode, 0
                )

    def test_the_bookmark_app_scope_entitlement_is_not_declared(self):
        # Security scoped bookmarks were measured to work without it
        # (2026-09-30), so the signature asks for nothing it does not need.
        with tempfile.TemporaryDirectory() as directory:
            entitlements = self.render(directory, 1)
            self.assertNotIn(
                "com.apple.security.files.bookmarks.app-scope", entitlements
            )

    def test_local_lane_keeps_existing_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            entitlements = self.render(directory, 0)
            self.assertEqual(
                entitlements,
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True,
                    USER_SELECTED_FILES: True,
                    "keychain-access-groups": ["TESTTEAM01.com.example.test"],
                },
            )


if __name__ == "__main__":
    unittest.main()
