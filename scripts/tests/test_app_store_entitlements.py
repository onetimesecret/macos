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

    def test_local_lane_keeps_existing_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            entitlements = self.render(directory, 0)
            self.assertEqual(
                entitlements,
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True,
                    "keychain-access-groups": ["TESTTEAM01.com.example.test"],
                },
            )


if __name__ == "__main__":
    unittest.main()
