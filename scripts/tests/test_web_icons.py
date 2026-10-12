"""Exercise build-icons.sh --web, which exports the glass icon for the websites."""

import os
import shlex
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-icons.sh"
NAMES = ("onetimepad-icon.png", "onetimepad-icon-dark.png")


def solid_png(size=4):
    """A tiny opaque RGBA PNG with no colour profile, standing in for an ictool export."""
    rows = b"".join(b"\x00" + b"\xdc\x4a\x22\xff" * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def image_properties(path):
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "bitsPerSample",
         "-g", "profile", "-g", "hasAlpha", str(path)],
        capture_output=True, text=True, check=True,
    )
    return dict(
        (key.strip(), value.strip())
        for key, value in (line.split(":", 1) for line in result.stdout.splitlines()[1:])
    )


@unittest.skipUnless(sys.platform == "darwin", "requires macOS sips")
class WebIconTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="onetimepad web icons ")
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.web = self.scratch / "web"

    def export(self, env=None, *leading):
        return subprocess.run(
            [str(SCRIPT), *leading, "--web", str(self.web)],
            env={**os.environ, **(env or {})},
            capture_output=True,
            text=True,
            timeout=120,
        )

    def mock_composer(self, skip_rendition="", xcode="27.0", with_ictool=True):
        """Stand in for the selected Xcode so failure paths need no Icon Composer."""
        fixture = self.scratch / "fixture.png"
        fixture.write_bytes(solid_png())
        self.requested = self.scratch / "renditions.log"
        developer = self.scratch / "Xcode.app/Contents/Developer"
        developer.mkdir(parents=True, exist_ok=True)
        if with_ictool:
            executables = self.scratch / "Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables"
            executables.mkdir(parents=True, exist_ok=True)
            ictool = executables / "ictool"
            # The real ictool reports an unknown rendition and still exits 0.
            ictool.write_text(
                "#!/bin/bash\nset -eu\n"
                'while [[ $# -gt 0 ]]; do\n'
                '  case "$1" in\n'
                '    --output-file) output="$2"; shift 2 ;;\n'
                '    --rendition) rendition="$2"; shift 2 ;;\n'
                '    *) shift ;;\n'
                '  esac\n'
                'done\n'
                f'echo "$rendition" >> {shlex.quote(str(self.requested))}\n'
                f'if [[ "$rendition" == {shlex.quote(skip_rendition)} ]]; then\n'
                '  echo "Unknown rendition name: $rendition" >&2\n'
                '  exit 0\n'
                'fi\n'
                f'cp {shlex.quote(str(fixture))} "$output"\n'
            )
            ictool.chmod(0o755)
        commands = self.scratch / "commands"
        commands.mkdir(exist_ok=True)
        xcodebuild = commands / "xcodebuild"
        xcodebuild.write_text(f'#!/bin/bash\nprintf "Xcode {xcode}\\nBuild version mock\\n"\n')
        xcodebuild.chmod(0o755)
        return {"DEVELOPER_DIR": str(developer), "PATH": f'{commands}:{os.environ["PATH"]}'}

    def require_icon_composer(self):
        try:
            version = subprocess.run(
                ["xcodebuild", "-version"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
            )
            developer = os.environ.get("DEVELOPER_DIR") or subprocess.run(
                ["xcode-select", "--print-path"], capture_output=True, text=True, check=True,
            ).stdout.strip()
        except (FileNotFoundError, subprocess.CalledProcessError):
            self.skipTest("requires Xcode 27 or later with Icon Composer")
        major = next(
            (line.split()[1] for line in version.stdout.splitlines()
             if line.startswith("Xcode ") and len(line.split()) > 1),
            "",
        ).split(".")[0]
        ictool = Path(developer).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
        if version.returncode or not major.isdigit() or int(major) < 27 or not os.access(ictool, os.X_OK):
            self.skipTest("requires Xcode 27 or later with Icon Composer")

    def test_exports_light_and_dark_as_8_bit_srgb(self):
        self.require_icon_composer()
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in NAMES:
            with self.subTest(name=name):
                self.assertEqual(image_properties(self.web / name), {
                    "pixelWidth": "1024",
                    "pixelHeight": "1024",
                    "bitsPerSample": "8",
                    "profile": "sRGB IEC61966-2.1",
                    "hasAlpha": "yes",
                })

    def test_requests_both_renditions_and_converts_each(self):
        result = self.export(self.mock_composer())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.requested.read_text().split(), ["Default", "Dark"])
        for name in NAMES:
            with self.subTest(name=name):
                self.assertEqual(image_properties(self.web / name)["profile"], "sRGB IEC61966-2.1")

    def test_rendition_ictool_did_not_write_leaves_earlier_exports(self):
        self.web.mkdir()
        for name in NAMES:
            (self.web / name).write_bytes(b"earlier export")
        result = self.export(self.mock_composer(skip_rendition="Dark"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ictool produced no Dark rendition", result.stderr)
        for name in NAMES:
            with self.subTest(name=name):
                self.assertEqual((self.web / name).read_bytes(), b"earlier export")

    def test_older_xcode_is_rejected_before_export(self):
        result = self.export(self.mock_composer(xcode="26.6"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("--web requires Xcode 27 or later", result.stderr)
        self.assertFalse(self.requested.exists())
        self.assertFalse(self.web.exists())

    def test_missing_icon_composer_is_reported(self):
        result = self.export(self.mock_composer(with_ictool=False))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("--web needs Icon Composer", result.stderr)
        self.assertFalse(self.web.exists())

    def test_mark_is_rejected(self):
        result = self.export(self.mock_composer(), "--mark", "logo")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("--mark applies to rendered artwork only", result.stderr)
        self.assertFalse(self.requested.exists())
        self.assertFalse(self.web.exists())


if __name__ == "__main__":
    unittest.main()
