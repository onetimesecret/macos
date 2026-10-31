"""Mutation checks for the comrak vendor verifier."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import tomllib
import unittest
from unittest import mock

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
        for relative in ["Cargo.toml", "Cargo.lock", "crates/markdown/Cargo.toml", "THIRD_PARTY_NOTICES.md"]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, target)

    def test_pinned_vendor_tree_passes(self):
        self.assertEqual(len(VERIFY.verify_tree(self.root)["files"]), 33)

    def run_cli(self):
        environment = dict(os.environ, LC_ALL="C", PYTHONCOERCECLOCALE="0", PYTHONUTF8="0")
        return subprocess.run(
            [sys.executable, str(REPOSITORY / "scripts/verify-vendored-comrak.py"), "--root", str(self.root)],
            env=environment, capture_output=True, encoding="utf-8", timeout=15, check=False,
        )

    def test_cli_reads_marked_notices_under_ascii_locale(self):
        self.assertIn("\U000E0101", (self.root / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8"))
        completed = self.run_cli()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("33 vendored files and both patches verified", completed.stdout)

    def test_cli_reports_missing_workspace_field_without_traceback(self):
        (self.root / "Cargo.toml").write_text('[package]\nname = "malformed-fixture"\n', encoding="utf-8")
        completed = self.run_cli()
        self.assertEqual(completed.returncode, 1)
        self.assertIn("comrak verification failed:", completed.stderr)
        self.assertIn("workspace", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

    def test_missing_license_notice_is_rejected(self):
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        copying = (self.root / "vendor/comrak/COPYING").read_bytes()
        notices.write_bytes(notices.read_bytes().replace(copying, b""))
        with self.assertRaisesRegex(VERIFY.VerificationError, "COPYING bytes exactly"):
            VERIFY.verify_tree(self.root)
        notices.unlink()
        with self.assertRaisesRegex(VERIFY.VerificationError, "COPYING bytes exactly"):
            VERIFY.verify_tree(self.root)

    def test_changed_license_notice_is_rejected(self):
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        copying = (self.root / "vendor/comrak/COPYING").read_bytes()
        changed = copying.replace(b"All rights reserved.", b"All permissions reserved.", 1)
        notices.write_bytes(notices.read_bytes().replace(copying, changed))
        with self.assertRaisesRegex(VERIFY.VerificationError, "COPYING bytes exactly"):
            VERIFY.verify_tree(self.root)

    def changed_notice_metadata(self, original, changed, message):
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        text = notices.read_text(encoding="utf-8")
        self.assertIn(original, text)
        notices.write_text(text.replace(original, changed, 1) + "\n" + original + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VERIFY.VerificationError, message):
            VERIFY.verify_tree(self.root)

    def test_changed_notice_version_is_rejected(self):
        self.changed_notice_metadata("comrak 0.57.0\n===", "comrak 0.58.0\n===", "notice version differs")

    def test_changed_notice_package_url_is_rejected(self):
        self.changed_notice_metadata("Package: https://crates.io/crates/comrak/0.57.0",
                                     "Package: https://crates.io/crates/comrak/0.58.0", "notice package URL differs")

    def test_changed_notice_checksum_is_rejected(self):
        self.changed_notice_metadata("Registry package checksum SHA-256:\n" + VERIFY.ARCHIVE_SHA256,
                                     "Registry package checksum SHA-256:\n" + "0" * 64,
                                     "notice archive checksum differs")

    def test_changed_notice_license_expression_is_rejected(self):
        self.changed_notice_metadata("Published license expression: BSD-2-Clause",
                                     "Published license expression: MIT", "notice license expression differs")

    def test_changed_notice_upstream_revision_is_rejected(self):
        revision = json.loads((self.root / "vendor/comrak/.cargo_vcs_info.json").read_text(encoding="utf-8"))["git"]["sha1"]
        label = "Upstream revision recorded in the published package:\n"
        self.changed_notice_metadata(label + revision, label + "0" * 40, "notice upstream revision differs")

    def test_notice_metadata_accepts_attribution_markers(self):
        notices = self.root / "THIRD_PARTY_NOTICES.md"
        notices.write_text(notices.read_text(encoding="utf-8").replace("comrak 0.57.0\n===", "c\U000E0101omrak 0.57.0\n===", 1)
                           .replace("Published license expression: BSD-2-Clause",
                                    "Published license expression: B\U000E0101SD-2-Clause", 1), encoding="utf-8")
        VERIFY.verify_tree(self.root)

    def test_source_change_is_rejected(self):
        with (self.root / "vendor/comrak/src/parser/mod.rs").open("a", encoding="utf-8") as source:
            source.write("\n// modified\n")
        with self.assertRaisesRegex(VERIFY.VerificationError, "vendor file changed"):
            VERIFY.verify_tree(self.root)

    def test_extra_vendor_file_is_rejected(self):
        (self.root / "vendor/comrak/extra.rs").write_text("fn extra() {}\n", encoding="utf-8")
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
        manifest.write_text(manifest.read_text(encoding="utf-8").replace("../../vendor/comrak", "../../other/comrak"), encoding="utf-8")
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

    def archive_partition(self, exclusions):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name, content in [("README.md", b"retained"), ("bench.rs", b"omitted")]:
                member = tarfile.TarInfo(f"comrak-{VERIFY.VERSION}/{name}")
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        inventory = {"files": {"README.md": VERIFY.digest(b"retained")},
                     "excluded_files": exclusions, "patches": {}}
        with mock.patch.object(VERIFY, "upstream_archive", return_value=output.getvalue()):
            VERIFY.verify_upstream(self.root, inventory, None)

    def test_archive_partition_accounts_for_every_omitted_file(self):
        self.archive_partition(["bench.rs"])

    def test_unlisted_archive_exclusion_is_rejected(self):
        with self.assertRaisesRegex(VERIFY.VerificationError, "unlisted archive file exclusion"):
            self.archive_partition([])

    def test_nonexistent_archive_exclusion_is_rejected(self):
        with self.assertRaisesRegex(VERIFY.VerificationError, "excluded archive file list differs"):
            self.archive_partition(["bench.rs", "missing.rs"])

    def test_duplicate_and_retained_archive_exclusions_are_rejected(self):
        for exclusions, message in [(["bench.rs", "bench.rs"], "duplicate"),
                                    (["README.md", "bench.rs"], "also vendored")]:
            with self.subTest(exclusions=exclusions), self.assertRaisesRegex(VERIFY.VerificationError, message):
                self.archive_partition(exclusions)

    def test_oversize_download_reports_the_download_limit(self):
        with mock.patch.dict(os.environ, {"CARGO_HOME": str(self.root)}), \
             mock.patch.object(VERIFY.urllib.request, "urlopen", return_value=io.BytesIO(b"x" * 1_000_001)):
            with self.assertRaisesRegex(VERIFY.VerificationError, "archive exceeds the download limit"):
                VERIFY.upstream_archive(None)

    def test_advisory_lock_restores_registry_origin_and_existing_versions(self):
        projected = tomllib.loads(VERIFY.advisory_lock(self.root))["package"]
        comrak = next(package for package in projected if package["name"] == "comrak")
        self.assertEqual(comrak["version"], "0.57.0")
        self.assertEqual(comrak["source"], VERIFY.REGISTRY)
        self.assertEqual(comrak["checksum"], VERIFY.ARCHIVE_SHA256)
        original = tomllib.loads((self.root / "Cargo.lock").read_text(encoding="utf-8"))["package"]
        originals = {(package["name"], package["version"]): package for package in original}
        for package in projected:
            if package["name"] not in {"comrak", "comrak-advisory-probe"}:
                self.assertEqual(package, originals[(package["name"], package["version"])])
        self.assertFalse(any(package["name"].startswith("companion-") for package in projected))

    def test_changed_upstream_version_is_rejected_before_advisory_preparation(self):
        manifest = self.root / "crates/markdown/Cargo.toml"
        manifest.write_text(manifest.read_text(encoding="utf-8").replace('version = "=0.57.0"', 'version = "=0.58.0"'), encoding="utf-8")
        with self.assertRaisesRegex(VERIFY.VerificationError, "must use the vendored comrak"):
            VERIFY.verify_tree(self.root)

    def test_registry_policy_probe_has_the_workspace_license(self):
        destination = self.root / "policy-probe"
        with mock.patch.object(VERIFY.subprocess, "run", return_value=mock.Mock(returncode=0, stderr="")):
            VERIFY.prepare_advisories(self.root, destination)
        manifest = tomllib.loads((destination / "Cargo.toml").read_text(encoding="utf-8"))
        workspace = tomllib.loads((self.root / "Cargo.toml").read_text(encoding="utf-8"))["workspace"]
        self.assertEqual(manifest["package"]["license"], workspace["package"]["license"])


if __name__ == "__main__":
    unittest.main()
