"""Mutation checks for the comrak vendor verifier."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import tempfile
import tomllib
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_vendored_comrak", REPOSITORY / "scripts/verify-vendored-comrak.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class VendoredComrakVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="comrak-verifier-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ["vendor/comrak", "crates/markdown/patches"]:
            shutil.copytree(REPOSITORY / directory, self.root / directory)
        for relative in ["Cargo.toml", "Cargo.lock", "crates/markdown/Cargo.toml"]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, target)

    def test_pinned_vendor_tree_passes(self):
        self.assertEqual(len(VERIFY.verify_tree(self.root)["files"]), 33)

    def test_source_change_is_rejected(self):
        with (self.root / "vendor/comrak/src/parser/mod.rs").open("a") as source:
            source.write("\n// modified\n")
        with self.assertRaisesRegex(VERIFY.VerificationError, "vendor file changed"):
            VERIFY.verify_tree(self.root)

    def test_extra_vendor_file_is_rejected(self):
        (self.root / "vendor/comrak/extra.rs").write_text("fn extra() {}\n")
        with self.assertRaisesRegex(VERIFY.VerificationError, "vendor file list changed"):
            VERIFY.verify_tree(self.root)

    def test_patch_change_is_rejected(self):
        patch = self.root / "crates/markdown/patches/comrak-0.57.0-reference-sourcepos.patch"
        patch.write_bytes(patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(VERIFY.VerificationError, "patch changed"):
            VERIFY.verify_tree(self.root)

    def test_inventory_change_is_rejected(self):
        inventory = self.root / VERIFY.INVENTORY
        inventory.write_bytes(inventory.read_bytes() + b"\n")
        with self.assertRaisesRegex(VERIFY.VerificationError, "vendor inventory changed"):
            VERIFY.verify_tree(self.root)

    def test_dependency_source_change_is_rejected(self):
        manifest = self.root / "crates/markdown/Cargo.toml"
        manifest.write_text(manifest.read_text().replace("../../vendor/comrak", "../../other/comrak"))
        with self.assertRaisesRegex(VERIFY.VerificationError, "must use the vendored comrak"):
            VERIFY.verify_tree(self.root)

    def test_symlink_is_rejected_even_when_contents_match(self):
        source = self.root / "vendor/comrak/README.md"
        replacement = self.root / "outside.md"
        source.rename(replacement)
        source.symlink_to(replacement)
        with self.assertRaisesRegex(VERIFY.VerificationError, "symlink"):
            VERIFY.verify_tree(self.root)

    def test_invalid_official_archive_is_rejected_before_extraction(self):
        archive = self.root / "invalid.crate"
        archive.write_bytes(b"not the pinned crate archive")
        with self.assertRaisesRegex(VERIFY.VerificationError, "archive checksum mismatch"):
            VERIFY.verify_upstream(self.root, VERIFY.verify_tree(self.root), archive)

    def test_advisory_lock_restores_registry_origin_and_existing_versions(self):
        projected = tomllib.loads(VERIFY.advisory_lock(self.root))["package"]
        comrak = next(package for package in projected if package["name"] == "comrak")
        self.assertEqual(comrak["version"], "0.57.0")
        self.assertEqual(comrak["source"], VERIFY.REGISTRY)
        self.assertEqual(comrak["checksum"], VERIFY.ARCHIVE_SHA256)
        original = tomllib.loads((self.root / "Cargo.lock").read_text())["package"]
        originals = {(package["name"], package["version"]): package for package in original}
        for package in projected:
            if package["name"] not in {"comrak", "comrak-advisory-probe"}:
                self.assertEqual(package, originals[(package["name"], package["version"])])
        self.assertFalse(any(package["name"].startswith("companion-") for package in projected))

    def test_changed_upstream_version_is_rejected_before_advisory_preparation(self):
        manifest = self.root / "crates/markdown/Cargo.toml"
        manifest.write_text(manifest.read_text().replace('version = "=0.57.0"', 'version = "=0.58.0"'))
        with self.assertRaisesRegex(VERIFY.VerificationError, "must use the vendored comrak"):
            VERIFY.verify_tree(self.root)


if __name__ == "__main__":
    unittest.main()
