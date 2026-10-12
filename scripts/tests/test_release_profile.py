"""Guard the build-only workaround for stripped Mach-O proc-macro dylibs."""

import unittest
from pathlib import Path

import tomllib

ROOT = Path(__file__).resolve().parents[2]


class ReleaseProfileTests(unittest.TestCase):
    def setUp(self):
        with (ROOT / "Cargo.toml").open("rb") as manifest:
            self.release = tomllib.load(manifest)["profile"]["release"]

    def test_release_build_dependencies_are_not_stripped(self):
        # rust-lang/rust#157750: the pinned rust-objcopy can misalign
        # proc-macro LINKEDIT entries, which macOS 27 refuses to load.
        self.assertEqual(
            self.release.get("build-override", {}).get("strip"), "none"
        )

    def test_target_release_settings_are_preserved(self):
        for name, value in {
            "strip": "symbols",
            "lto": "thin",
            "opt-level": "s",
            "panic": "unwind",
        }.items():
            with self.subTest(setting=name):
                self.assertEqual(self.release[name], value)


if __name__ == "__main__":
    unittest.main()
