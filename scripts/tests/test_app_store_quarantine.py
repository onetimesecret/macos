"""Exercise quarantine cleanup with real macOS extended attributes, without signing."""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()
QUARANTINE = "com.apple.quarantine"
EMBED = '  cp "$PROVISIONING_PROFILE"'
CLEANUP = 'xattr -drs com.apple.quarantine "$APP"'
CHECK = "  APP_XATTRS="
BUNDLE_WRITE = re.compile(
    r'\b(?:cp|ditto|install|ln|mv|rsync|tee)\b.*"\$APP[/"]|>\s*"\$APP[/"]'
)


def locate(marker):
    count = SCRIPT.count(marker)
    if count != 1:
        raise AssertionError(
            f"expected one {marker!r} in package-app.sh, found {count}"
        )
    return SCRIPT.index(marker)


def fragment(start_marker, end_marker):
    start, end = locate(start_marker), locate(end_marker)
    if end <= start:
        raise AssertionError(f"{end_marker!r} precedes {start_marker!r}")
    return SCRIPT[start:end]


class AppStoreQuarantineLayoutTests(unittest.TestCase):
    """Pin the ordering and scoping that the fragments below assume."""

    def test_cleanup_follows_the_profile_copy_and_precedes_signing(self):
        self.assertIn(CLEANUP, fragment(EMBED, "  SIGNED_BUNDLE_ID="))
        self.assertLess(
            locate(CLEANUP), locate("codesign --force --options runtime")
        )

    def test_nothing_writes_into_the_bundle_after_cleanup(self):
        after = SCRIPT[locate(CLEANUP) : locate("productbuild --component")]
        writes = [
            line for line in after.splitlines() if BUNDLE_WRITE.search(line)
        ]
        self.assertEqual(writes, [])

    def test_prepackage_check_applies_to_the_app_store_lane_only(self):
        before = SCRIPT[: locate(CHECK)].splitlines()
        block = next(
            line
            for line in reversed(before)
            if re.match(r"(?:if|elif|else|fi)\b", line)
        )
        self.assertEqual(block, "if ((APP_STORE_MODE)); then")


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

    def quarantine(self, path, *options):
        self.xattr(*options, "-w", QUARANTINE, "0081;00000000;Test;", path)

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
        return self.run_fragment(
            fragment(EMBED, "  SIGNED_BUNDLE_ID="), app_store
        )

    def verify(self):
        return self.run_fragment(fragment(CHECK, "  SIGNATURE_DETAILS="))

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

    def test_symbolic_links_are_cleaned_but_never_followed(self):
        outside = self.directory / "outside.txt"
        outside.write_bytes(b"outside the bundle")
        self.quarantine(outside)
        link = self.resources / "outside"
        link.symlink_to(outside)
        self.quarantine(link, "-s")
        (self.resources / "dangling").symlink_to(self.directory / "missing")
        result = self.embed()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(QUARANTINE, self.xattr("-s", link).splitlines())
        self.assertIn(QUARANTINE, self.xattr(outside).splitlines())
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
        self.xattr("-w", "com.onetimesecret.test", "unrelated", self.resource)
        for path in (self.app, self.resources, self.resource, self.embedded):
            with self.subTest(path=path):
                self.quarantine(path)
                result = self.verify()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{path}: {QUARANTINE}", result.stderr)
                self.assertNotIn("com.onetimesecret.test", result.stderr)
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
        result = self.run_fragment(
            f'PATH="{commands}:$PATH"\n'
            + fragment(EMBED, "  SIGNED_BUNDLE_ID=")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
