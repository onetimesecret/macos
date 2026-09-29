"""Check the actual resource assembly fragment without building or signing the app."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class AppLocalizationTests(unittest.TestCase):
    def test_packaging_preserves_all_localizations(self):
        script = (ROOT / "scripts/package-app.sh").read_text()
        start = script.index('mkdir -p "$APP/Contents/MacOS"')
        end = script.index("# A debug build always", start)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "OnetimePad.app"
            binary = Path(directory) / "OnetimePad"
            binary.touch()
            subprocess.run(
                ["bash", "-euc", script[start:end]],
                cwd=ROOT,
                env={**os.environ, "APP": str(app), "BIN": str(binary)},
                check=True,
                capture_output=True,
                text=True,
            )
            resources = ROOT / "shell/Sources/CompanionKit/Resources"
            for source in resources.glob("*.lproj/*"):
                with self.subTest(resource=str(source)):
                    target = (
                        app
                        / "Contents/Resources"
                        / source.relative_to(resources)
                    )
                    self.assertTrue(
                        target.is_file(),
                        f"Missing shipped localization: {target}",
                    )
                    self.assertEqual(source.read_bytes(), target.read_bytes())

    def test_editor_does_not_use_fatal_module_accessor(self):
        source = (
            ROOT / "shell/Sources/CompanionKit/InkEditorView.swift"
        ).read_text()
        self.assertFalse(
            ".module" in source, "Editor uses the fatal SwiftPM accessor"
        )

    @unittest.skipUnless(
        sys.platform == "darwin", "requires macOS Swift and bundles"
    )
    def test_runtime_lookup_in_app_and_swiftpm_layouts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text("""import Foundation
let resources = CompanionLocalization.bundle
if CommandLine.arguments.count > 1 {
    guard let url = resources.url(forResource: "fr", withExtension: "lproj"),
          let french = Bundle(url: url) else { exit(1) }
    print(french.localizedString(forKey: "edited", value: nil, table: nil))
} else {
    print(resources.localizedString(forKey: "edited", value: nil, table: nil))
}
""")
            binary = root / "probe"
            subprocess.run(
                [
                    "swiftc",
                    "-swift-version",
                    "6",
                    str(
                        ROOT
                        / "shell/Sources/CompanionKit/CompanionLocalization.swift"
                    ),
                    str(source),
                    "-o",
                    str(binary),
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=60,
            )

            def run(executable, *args):
                return subprocess.run(
                    [str(executable), *args],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=10,
                ).stdout.strip()

            self.assertEqual(
                run(binary), "edited"
            )  # No resource bundle at all.
            app = root / "Relocated.app"
            executable = app / "Contents/MacOS/OnetimePad"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binary, executable)
            shutil.copy2(
                ROOT / "shell/OnetimePad-Info.plist",
                app / "Contents/Info.plist",
            )
            resources = app / "Contents/Resources"
            resources.mkdir()
            self.assertEqual(
                run(executable), "edited"
            )  # Broken packaging is nonfatal.
            for localization in (
                ROOT / "shell/Sources/CompanionKit/Resources"
            ).glob("*.lproj"):
                shutil.copytree(localization, resources / localization.name)
            self.assertEqual(run(executable), "edited")
            self.assertEqual(run(executable, "fr"), "modifié")
            package = root / "OnetimePad_CompanionKit.bundle"
            shutil.copytree(resources, package)
            self.assertEqual(run(binary, "fr"), "modifié")


if __name__ == "__main__":
    unittest.main()
