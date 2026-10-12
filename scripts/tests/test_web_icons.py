"""Exercise build-icons.sh --web, which exports the glass icon for the websites."""

import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-icons.sh"
DOCUMENT = ROOT / "artwork/OnetimePad-Glass.icon/icon.json"
LOGO = ROOT / "shell/Sources/CompanionKit/Resources/onetime-logo-v3-xl.svg"
RASTERS = ("onetimepad-icon.png", "onetimepad-icon-dark.png")
VECTORS = ("onetimepad-icon.svg", "onetimepad-icon-dark.svg")
NAMES = RASTERS + VECTORS
FIXTURE_SHADE = "dc4a22"
SVG = "{http://www.w3.org/2000/svg}"


def document_fill():
    """The saved document's fill shade as rrggbb, converted independently of the script."""
    fill = json.loads(DOCUMENT.read_text())["fill"]
    value = fill.get("automatic-gradient") or fill["solid"]
    components = value.removeprefix("extended-srgb:").split(",")
    return "".join(f"{int(float(c) * 255 + 0.5):02x}" for c in components[:3])


def logo_mark_paths():
    """The brand asset's own path data, minus its full bleed plate (the first path)."""
    paths = ElementTree.parse(LOGO).getroot().findall(f"{SVG}path")
    return [(p.get("transform"), p.get("d")) for p in paths[1:]]


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

    def run_script(self, arguments, env=None, script=SCRIPT):
        return subprocess.run(
            [str(script), *arguments],
            env={**os.environ, **(env or {})},
            capture_output=True,
            text=True,
            timeout=120,
        )

    def export(self, env=None, *leading):
        return self.run_script([*leading, "--web", str(self.web)], env)

    def scratch_checkout(self):
        """A copy of what the script reads and writes, for tests that change the document."""
        checkout = self.scratch / "checkout"
        for relative in ("scripts/build-icons.sh", "scripts/render-icon.swift", LOGO.relative_to(ROOT)):
            (checkout / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, checkout / relative)
        shutil.copytree(DOCUMENT.parent, checkout / DOCUMENT.parent.relative_to(ROOT))
        return checkout

    def mock_composer(self, skip_rendition="", xcode="27.0", with_ictool=True):
        """Stand in for the selected Xcode so failure paths need no Icon Composer."""
        fixture = self.scratch / "fixture.png"
        fixture.write_bytes(solid_png())
        self.requested = self.scratch / "renditions.log"
        self.layers_seen = self.scratch / "layers.log"
        developer = self.scratch / "Xcode.app/Contents/Developer"
        developer.mkdir(parents=True, exist_ok=True)
        if with_ictool:
            executables = self.scratch / "Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables"
            executables.mkdir(parents=True, exist_ok=True)
            ictool = executables / "ictool"
            # The real ictool reports an unknown rendition and still exits 0.
            # The stand-in also notes the first bytes of the document's
            # foreground layer, so a test can see which layer it exported.
            ictool.write_text(
                "#!/bin/bash\nset -eu\n"
                'head -c 4 "$1/Assets/01-logo-foreground.png" | LC_ALL=C tr -dc A-Za-z'
                f' >> {shlex.quote(str(self.layers_seen))}\n'
                f'echo >> {shlex.quote(str(self.layers_seen))}\n'
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
        # The vector export runs the real renderer, and the swift shim
        # resolves its toolchain through DEVELOPER_DIR, so hand it the
        # selected Xcode rather than the stand-in.
        selected = os.environ.get("DEVELOPER_DIR") or subprocess.run(
            ["xcode-select", "--print-path"], capture_output=True, text=True, check=True,
        ).stdout.strip()
        swift = commands / "swift"
        swift.write_text(
            f'#!/bin/bash\nexport DEVELOPER_DIR={shlex.quote(selected)}\nexec /usr/bin/swift "$@"\n'
        )
        swift.chmod(0o755)
        # macOS mktemp prefers the per user temporary directory to
        # TMPDIR, so the scratch directories the script makes are logged
        # here to check that a failed export takes them back.
        self.scratch_made = self.scratch / "mktemp.log"
        mktemp = commands / "mktemp"
        mktemp.write_text(
            '#!/bin/bash\ncreated="$(/usr/bin/mktemp "$@")" || exit\n'
            f'echo "$created" >> {shlex.quote(str(self.scratch_made))}\n'
            'echo "$created"\n'
        )
        mktemp.chmod(0o755)
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
        for name in RASTERS:
            with self.subTest(name=name):
                self.assertEqual(image_properties(self.web / name), {
                    "pixelWidth": "1024",
                    "pixelHeight": "1024",
                    "bitsPerSample": "8",
                    "profile": "sRGB IEC61966-2.1",
                    "hasAlpha": "yes",
                })
        self.assert_vector_export("onetimepad-icon.svg", document_fill())
        # The dark plate is Composer's, sampled from its rendition: a dark grey.
        dark = ElementTree.parse(self.web / "onetimepad-icon-dark.svg").getroot()
        fill = dark.find(f"{SVG}path").get("fill")
        self.assertTrue(all(int(fill[i:i + 2], 16) < 0x40 for i in (1, 3, 5)), fill)
        self.assert_vector_export("onetimepad-icon-dark.svg", fill[1:])

    def assert_vector_export(self, name, fill):
        """The SVG is the icon shape in one fill under the asset's own mark paths."""
        root = ElementTree.parse(self.web / name).getroot()
        self.assertEqual(root.tag, f"{SVG}svg")
        self.assertEqual(root.get("viewBox"), "0 0 1024 1024")
        # Inlined, the SVG is one image named by its title.
        self.assertEqual(root.get("role"), "img")
        self.assertEqual(root.find(f"{SVG}title").text, "OnetimePad")
        plate, group = list(root.findall(f"{SVG}path")), root.find(f"{SVG}g")
        self.assertEqual(len(plate), 1)
        self.assertEqual(plate[0].get("fill"), "#" + fill)
        self.assertRegex(plate[0].get("d"), r"^M [\d.]+ 0 .* Z$")
        self.assertEqual(group.get("fill"), "#ffffff")
        self.assertRegex(
            group.get("transform"),
            r"^translate\(-?[\d.]+ -?[\d.]+\) scale\([\d.]+\) translate\(-?[\d.]+ -?[\d.]+\)$",
        )
        self.assertEqual(
            [(p.get("transform"), p.get("d")) for p in group.findall(f"{SVG}path")],
            logo_mark_paths(),
        )
        self.assertNotIn("<image", (self.web / name).read_text())

    def test_exports_flat_vectors_in_the_document_and_rendition_fills(self):
        result = self.export(self.mock_composer())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"onetimepad-icon.svg (flat, fill {document_fill()} from icon.json)", result.stdout)
        self.assert_vector_export("onetimepad-icon.svg", document_fill())
        # The stand-in ictool renders every rendition as the solid fixture,
        # so the dark SVG sampling the Dark rendition gets the fixture's shade.
        self.assertIn(
            f"onetimepad-icon-dark.svg (flat, fill {FIXTURE_SHADE} from the Dark rendition)",
            result.stdout,
        )
        self.assert_vector_export("onetimepad-icon-dark.svg", FIXTURE_SHADE)

    def test_comma_decimal_locale_reads_the_same_fill(self):
        result = self.export({**self.mock_composer(), "LC_ALL": "de_DE.UTF-8"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_vector_export("onetimepad-icon.svg", document_fill())

    def test_requests_both_renditions_and_converts_each(self):
        result = self.export(self.mock_composer())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.requested.read_text().split(), ["Default", "Dark"])
        for name in RASTERS:
            with self.subTest(name=name):
                self.assertEqual(image_properties(self.web / name)["profile"], "sRGB IEC61966-2.1")
        self.assertEqual(sorted(p.name for p in self.web.iterdir()), sorted(NAMES))

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
        # The staged Default rendition goes with the failed export.
        staged = self.scratch_made.read_text().splitlines()
        self.assertTrue(staged)
        for directory in staged:
            with self.subTest(directory=directory):
                self.assertFalse(Path(directory).exists())

    def test_update_glass_artwork_exports_the_refreshed_layers(self):
        checkout = self.scratch_checkout()
        assets = checkout / DOCUMENT.parent.relative_to(ROOT) / "Assets"
        web = checkout / "artwork/web"
        web.mkdir(parents=True)
        layers = ("00-logo-cast-shadow.png", "01-logo-foreground.png")
        for layer in layers:
            (assets / layer).write_bytes(b"earlier layer")
        for name in NAMES:
            (web / name).write_bytes(b"earlier export")
        result = self.run_script(
            ["--update-glass-artwork"], self.mock_composer(), checkout / "scripts/build-icons.sh",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for layer in layers:
            with self.subTest(layer=layer):
                self.assertEqual(image_properties(assets / layer)["pixelWidth"], "1024")
        # Both renditions are exported from the rewritten foreground, not the earlier one.
        self.assertEqual(self.requested.read_text().split(), ["Default", "Dark"])
        self.assertEqual(self.layers_seen.read_text().split(), ["PNG", "PNG"])
        for name in NAMES:
            with self.subTest(name=name):
                self.assertNotEqual((web / name).read_bytes(), b"earlier export")
        self.web = web
        self.assert_vector_export("onetimepad-icon.svg", document_fill())

    def test_signed_shade_never_reaches_the_svg(self):
        output = self.scratch / "signed.svg"
        result = subprocess.run(
            ["swift", str(ROOT / "scripts/render-icon.swift"), "--mark", "logo", "--svg", "+dc4a2", str(output)],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('shade must be six hex digits, got "+dc4a2"', result.stderr)
        self.assertFalse(output.exists())

    def test_fill_outside_srgb_is_refused_by_name(self):
        checkout = self.scratch_checkout()
        document = checkout / DOCUMENT.relative_to(ROOT)
        saved = json.loads(document.read_text())
        key = "automatic-gradient" if "automatic-gradient" in saved["fill"] else "solid"
        saved["fill"] = {key: "extended-srgb:1.07000,-0.02000,0.13333,1.00000"}
        document.write_text(json.dumps(saved))
        result = self.run_script(["--web", str(self.web)], self.mock_composer(), checkout / "scripts/build-icons.sh")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("1.07000,-0.02000,0.13333 in artwork/OnetimePad-Glass.icon/icon.json is outside sRGB", result.stderr)
        self.assertFalse(self.requested.exists())
        self.assertFalse(self.web.exists())

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
