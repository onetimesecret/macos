"""Exercise the actual icon assembly fragment, without building or installing the app."""

import os
import plistlib
import shlex
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
        # Run the real compiler script from the stable repository directory.
        # ibtoold may outlive its caller; deleting its working directory
        # between tests can poison later compiler invocations.
        renderer = self.checkout / "scripts/build-icons.sh"
        renderer.write_text(
            '#!/bin/bash\nset -eu\n[[ "$1" == "--glass" ]]\n'
            f'exec {shlex.quote(str(ROOT / "scripts/build-icons.sh"))} '
            f'--glass {shlex.quote(str(self.checkout / "dist/icons/glass"))}\n'
        )
        renderer.chmod(0o755)
        self.icons = self.checkout / "dist/icons"
        self.icons.mkdir(parents=True)
        # An experiment must never replace the saved Composer release icon.
        (self.icons / "OnetimePad-experiment.icns").write_bytes(b"experiment")

    def assemble(self, config, env=None, closed_stdin=False):
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
            preexec_fn=(lambda: os.close(0)) if closed_stdin else None,
            timeout=120,
        )

    def read_metadata(self):
        with self.plist.open("rb") as file:
            return plistlib.load(file)

    def require_icon_composer(self):
        try:
            available = subprocess.run(
                ["xcrun", "--find", "actool"], capture_output=True, check=False
            )
            version = subprocess.run(
                ["xcodebuild", "-version"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            self.skipTest("requires Xcode 27 or later with actool")
        selected = next(
            (line.split()[1] for line in version.stdout.splitlines()
             if line.startswith("Xcode ") and len(line.split()) > 1),
            "",
        )
        major = selected.split(".")[0]
        if available.returncode or version.returncode or not major.isdigit() or int(major) < 27:
            self.skipTest("requires Xcode 27 or later with actool")

    def mock_toolchain(self, xcodebuild_body=None, compiler_exit=None):
        """Keep failure-path tests independent of the installed Xcode selection."""
        commands = self.checkout / "commands"
        commands.mkdir(exist_ok=True)
        xcodebuild = commands / "xcodebuild"
        xcodebuild.write_text(
            "#!/bin/bash\n" + (xcodebuild_body or
            'printf "Xcode 27.0\\nBuild version 27A266a\\n"\n')
        )
        xcodebuild.chmod(0o755)
        fixture = commands / "icon-info.plist"
        fixture.write_bytes(plistlib.dumps({
            "CFBundleIconFile": "OnetimePad-Glass",
            "CFBundleIconName": "OnetimePad-Glass",
        }))
        xcrun = commands / "xcrun"
        compile_body = f"exit {compiler_exit}\n" if compiler_exit is not None else (
            'set -eu\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  case "$1" in\n'
            '    --compile) compiled="$2"; shift 2 ;;\n'
            '    --output-partial-info-plist) partial="$2"; shift 2 ;;\n'
            '    *) shift ;;\n'
            '  esac\n'
            'done\n'
            'mkdir -p "$compiled"\n'
            'printf "compiled glass catalog" > "$compiled/Assets.car"\n'
            'printf "generated glass fallback" > "$compiled/OnetimePad-Glass.icns"\n'
            f'cp {shlex.quote(str(fixture))} "$partial"\n'
            'if [[ -n "${MOCK_MISSING:-}" ]]; then rm "$compiled/$MOCK_MISSING"; fi\n'
            'if [[ -n "${MOCK_EMPTY:-}" ]]; then : > "$compiled/$MOCK_EMPTY"; fi\n'
        )
        xcrun.write_text(
            '#!/bin/bash\nif [[ "$1" == "--find" ]]; then exit 0; fi\n' + compile_body
        )
        xcrun.chmod(0o755)
        return {"PATH": f'{commands}:{os.environ["PATH"]}'}

    def compile_glass(self, env=None):
        return subprocess.run(
            [str(ROOT / "scripts/build-icons.sh"), "--glass", str(self.icons / "glass")],
            env={**os.environ, **(env or {})},
            capture_output=True,
            text=True,
            timeout=120,
        )

    def test_release_bundles_compiled_glass_and_generated_fallback(self):
        self.require_icon_composer()
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

    def test_release_compiles_when_invoker_has_closed_stdin(self):
        self.require_icon_composer()
        result = self.assemble("release", closed_stdin=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater((self.resources / "Assets.car").stat().st_size, 0)

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

    def test_older_xcode_is_rejected_before_icon_compilation(self):
        env = self.mock_toolchain(
            xcodebuild_body='printf "Xcode 26.6\\nBuild version 17F113\\n"\n'
        )
        result = self.assemble("release", env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("requires Xcode 27 or later", result.stderr)
        self.assertFalse((self.icons / "glass").exists())
        self.assertFalse(list(self.resources.iterdir()))

    def test_failed_xcode_version_reports_required_toolchain(self):
        env = self.mock_toolchain(
            xcodebuild_body='printf "toolchain unavailable\\n" >&2\nexit 70\n'
        )
        result = self.compile_glass(env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("requires Xcode 27 or later", result.stderr)
        self.assertFalse((self.icons / "glass").exists())

    def test_failed_compile_does_not_package_stale_glass_outputs(self):
        compiled = self.icons / "glass"
        compiled.mkdir()
        for name in ("Assets.car", "OnetimePad-Glass.icns", "icon-info.plist"):
            (compiled / name).write_bytes(b"stale")
        result = self.assemble("release", self.mock_toolchain(compiler_exit=42))
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertFalse(list(compiled.iterdir()))
        self.assertFalse(list(self.resources.iterdir()))

    def test_successful_compile_rejects_missing_or_empty_outputs(self):
        env = self.mock_toolchain()
        for name in ("Assets.car", "icon-info.plist", "OnetimePad-Glass.icns"):
            for kind in ("MISSING", "EMPTY"):
                with self.subTest(output=name, kind=kind):
                    result = self.compile_glass({**env, f"MOCK_{kind}": name})
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("glass icon", result.stderr.lower())
                    self.assertIn(name, result.stderr)

    def test_release_rejects_missing_or_empty_icon_metadata(self):
        # Bypass compiler validation to exercise the packaging guard itself.
        renderer = self.checkout / "scripts/build-icons.sh"
        renderer.write_text(
            '#!/bin/bash\nset -eu\n[[ "$1" == "--glass" ]]\n'
            'mkdir -p dist/icons/glass\n'
            'printf "compiled glass catalog" > dist/icons/glass/Assets.car\n'
            'printf "generated fallback" > dist/icons/glass/OnetimePad-Glass.icns\n'
            'cp icon-fixture.plist dist/icons/glass/icon-info.plist\n'
        )
        for key in ("CFBundleIconFile", "CFBundleIconName"):
            for kind in ("missing", "empty"):
                with self.subTest(key=key, kind=kind):
                    metadata = {
                        "CFBundleIconFile": "OnetimePad-Glass",
                        "CFBundleIconName": "OnetimePad-Glass",
                    }
                    if kind == "missing":
                        del metadata[key]
                    else:
                        metadata[key] = ""
                    (self.checkout / "icon-fixture.plist").write_bytes(plistlib.dumps(metadata))
                    result = self.assemble("release")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("glass icon", result.stderr.lower())
                    self.assertIn(key, result.stderr)
                    self.assertFalse(list(self.resources.iterdir()))


if __name__ == "__main__":
    unittest.main()
