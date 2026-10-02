"""Exercise quarantine cleanup with real macOS extended attributes, without signing."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()
QUARANTINE = "com.apple.quarantine"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS xattr and cp")
class AppStoreQuarantineTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="onetimepad quarantine ")
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)
        self.app = self.directory / "OnetimePad.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        self.profile = self.directory / "distribution.provisionprofile"
        self.profile.write_bytes(b"test profile content")
        self.embedded = self.app / "Contents/embedded.provisionprofile"
        self.resource = self.resources / "resource.txt"
        self.resource.write_bytes(b"test resource content")

    def xattr(self, *arguments):
        return subprocess.run(
            ["/usr/bin/xattr", *map(str, arguments)],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout

    def quarantine(self, path):
        self.xattr("-w", QUARANTINE, "0081;00000000;Test;", path)

    def run_fragment(self, fragment, app_store=1):
        return subprocess.run(
            ["bash", "-euc", fragment],
            cwd=ROOT,
            env={
                **os.environ,
                "APP": str(self.app),
                "PROVISIONING_PROFILE": str(self.profile),
                "APP_STORE_MODE": str(app_store),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )

    def embed(self, app_store=1):
        start = SCRIPT.index('  cp "$PROVISIONING_PROFILE"')
        end = SCRIPT.index("  SIGNED_BUNDLE_ID=", start)
        return self.run_fragment(SCRIPT[start:end], app_store)

    def verify(self):
        start = SCRIPT.index("  APP_XATTRS=")
        end = SCRIPT.index('  rm -f "$PKG"', start)
        return self.run_fragment(SCRIPT[start:end])

    def test_profile_copy_preserves_quarantine_without_cleanup(self):
        self.quarantine(self.profile)
        subprocess.run(["/bin/cp", self.profile, self.embedded], check=True)
        self.assertIn(QUARANTINE, self.xattr(self.embedded).splitlines())

    def test_cleans_entire_bundle_after_embedding_but_preserves_source(self):
        for path in (self.profile, self.app, self.resources, self.resource):
            self.quarantine(path)
        self.xattr("-w", "com.onetimesecret.test", "retain", self.resource)
        result = self.embed()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in (self.app, self.resources, self.resource, self.embedded):
            self.assertNotIn(QUARANTINE, self.xattr(path).splitlines())
        self.assertIn(QUARANTINE, self.xattr(self.profile).splitlines())
        self.assertEqual(self.embedded.read_bytes(), self.profile.read_bytes())
        self.assertEqual(self.resource.read_bytes(), b"test resource content")
        self.assertEqual(
            self.xattr("-p", "com.onetimesecret.test", self.resource).strip(),
            "retain",
        )

    def test_clean_bundle_is_accepted_and_cleanup_is_repeatable(self):
        for _ in range(2):
            result = self.embed()
            self.assertEqual(
                result.returncode, 0, result.stdout + result.stderr
            )
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_app_store_profile_copy_is_unchanged(self):
        self.quarantine(self.profile)
        result = self.embed(app_store=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(QUARANTINE, self.xattr(self.embedded).splitlines())

    def test_prepackage_check_rejects_quarantine_anywhere_in_bundle(self):
        result = self.embed()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in (self.app, self.resources, self.resource, self.embedded):
            with self.subTest(path=path):
                self.quarantine(path)
                result = self.verify()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(QUARANTINE, result.stderr)
                self.assertIn(str(path), result.stderr)
                self.xattr("-d", QUARANTINE, path)

    def test_prepackage_attribute_read_failure_stops_packaging(self):
        self.resource.unlink()
        self.resources.rmdir()
        self.resources.parent.rmdir()
        self.app.rmdir()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No such file", result.stderr)

    def test_cleanup_failure_stops_packaging(self):
        commands = self.directory / "commands"
        commands.mkdir()
        xattr = commands / "xattr"
        xattr.write_text("#!/bin/sh\necho 'cleanup failed' >&2\nexit 1\n")
        xattr.chmod(0o755)
        start = SCRIPT.index('  cp "$PROVISIONING_PROFILE"')
        end = SCRIPT.index("  SIGNED_BUNDLE_ID=", start)
        result = self.run_fragment(
            f'PATH="{commands}:$PATH"\n' + SCRIPT[start:end]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
