"""Exercise the actual icon assembly fragment, without building or installing the app."""

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()
ICON_ASSEMBLY = SCRIPT[
    SCRIPT.index("# A debug build always") : SCRIPT.index("# App Store Connect identifies")
]


@unittest.skipUnless(sys.platform == "darwin", "requires macOS actool and plutil")
class AppIconTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="onetimepad icons ")
        self.addCleanup(scratch.cleanup)
        self.checkout = Path(scratch.name)
        self.resources = self.checkout / "OnetimePad.app/Contents/Resources"
        self.resources.mkdir(parents=True)
        self.plist = self.resources.parent / "Info.plist"
        shutil.copy2(ROOT / "shell/OnetimePad-Info.plist", self.plist)
        (self.checkout / "scripts").mkdir()
        (self.checkout / "shell").mkdir()
        shutil.copy2(ROOT / "scripts/build-icons.sh", self.checkout / "scripts")
        shutil.copy2(ROOT / "shell/OnetimePad-Info.plist", self.checkout / "shell")
        shutil.copytree(
            ROOT / "artwork/OnetimePad-Glass.icon",
            self.checkout / "artwork/OnetimePad-Glass.icon",
        )
        self.icons = self.checkout / "dist/icons"
        self.icons.mkdir(parents=True)
        # An experiment must never replace the saved Composer release icon.
        (self.icons / "OnetimePad-experiment.icns").write_bytes(b"experiment")

    def assemble(self, config, env=None):
        return subprocess.run(
            ["bash", "-euc", ICON_ASSEMBLY],
            cwd=self.checkout,
            env={
                **os.environ,
                "CONFIG": config,
                "APP": str(self.resources.parent.parent),
                **(env or {}),
            },
            capture_output=True,
            text=True,
            timeout=120,
        )

    def read_metadata(self):
        with self.plist.open("rb") as file:
            return plistlib.load(file)

    def test_release_bundles_compiled_glass_and_generated_fallback(self):
        available = subprocess.run(
            ["xcrun", "--find", "actool"], capture_output=True, check=False
        )
        if available.returncode:
            self.skipTest("requires Xcode with actool")
        result = self.assemble("release")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        metadata = self.read_metadata()
        with (self.icons / "glass/icon-info.plist").open("rb") as file:
            generated = plistlib.load(file)
        self.assertEqual(metadata["CFBundleIconName"], generated["CFBundleIconName"])
        catalog = self.resources / "Assets.car"
        self.assertGreater(catalog.stat().st_size, 0)
        self.assertEqual(catalog.read_bytes(), (self.icons / "glass/Assets.car").read_bytes())
        fallback = self.resources / f'{metadata["CFBundleIconFile"]}.icns'
        source = self.icons / "glass" / f'{generated["CFBundleIconFile"]}.icns'
        self.assertGreater(source.stat().st_size, 0)
        self.assertEqual(fallback.read_bytes(), source.read_bytes())
        self.assertTrue(metadata["CFBundleIconFile"].startswith("AppIcon-"))
        self.assertNotIn(b"experiment", fallback.read_bytes())

    def test_debug_selects_black_icon_without_compiling_glass(self):
        # Stub only rendering; run the packaging branch and metadata writes.
        renderer = self.checkout / "scripts/build-icons.sh"
        renderer.write_text(
            '#!/bin/bash\nset -eu\n[[ "$1" == "--dev" ]]\n'
            'printf "black development icon" > dist/icons/OnetimePad-dev.icns\n'
        )
        result = self.assemble("debug")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        metadata = self.read_metadata()
        self.assertNotIn("CFBundleIconName", metadata)
        self.assertFalse((self.resources / "Assets.car").exists())
        fallback = self.resources / f'{metadata["CFBundleIconFile"]}.icns'
        self.assertEqual(fallback.read_bytes(), b"black development icon")

    def test_failed_compile_does_not_package_stale_glass_outputs(self):
        compiled = self.icons / "glass"
        compiled.mkdir()
        for name in ("Assets.car", "OnetimePad-Glass.icns", "icon-info.plist"):
            (compiled / name).write_bytes(b"stale")
        commands = self.checkout / "commands"
        commands.mkdir()
        xcrun = commands / "xcrun"
        xcrun.write_text(
            '#!/bin/bash\nif [[ "$1" == "--find" ]]; then exit 0; fi\nexit 42\n'
        )
        xcrun.chmod(0o755)
        result = self.assemble("release", {"PATH": f'{commands}:{os.environ["PATH"]}'})
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertFalse(list(compiled.iterdir()))
        self.assertFalse(list(self.resources.iterdir()))


if __name__ == "__main__":
    unittest.main()
