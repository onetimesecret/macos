import importlib.util
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast

SCRIPT = Path(__file__).resolve().parents[1] / "verify-betlang.py"
SPEC = importlib.util.spec_from_file_location("verify_betlang", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VERIFY = cast(Any, importlib.util.module_from_spec(SPEC))
SPEC.loader.exec_module(VERIFY)


class BetlangVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.root = base / "workspace"
        self.package = base / "registry" / "betlang-0.1.1"
        (self.root / "crates/core").mkdir(parents=True)
        (self.root / "tools/language-eval").mkdir(parents=True)
        (self.package / "assets/magika").mkdir(parents=True)
        for relative in VERIFY.DIRECT_USERS:
            (self.root / relative).write_text(
                '[package]\nname = "consumer"\nversion = "0.1.0"\n\n[dependencies]\nbetlang = "=0.1.1"\n'
            )
        (self.root / "Cargo.lock").write_text(
            'version = 4\n\n[[package]]\nname = "betlang"\nversion = "0.1.1"\n'
            f'source = "{VERIFY.EXPECTED_SOURCE}"\nchecksum = "{VERIFY.EXPECTED_CRATE_CHECKSUM}"\n'
        )
        (self.package / "Cargo.toml").write_text(
            '[package]\nname = "betlang"\nversion = "0.1.1"\n'
        )
        (self.package / "assets/magika/source-student-q4.bin").write_bytes(
            b"x" * VERIFY.EXPECTED_MODEL_SIZE
        )
        self.original_sha = VERIFY.EXPECTED_MODEL_SHA256
        VERIFY.EXPECTED_MODEL_SHA256 = VERIFY.sha256(
            self.package / "assets/magika/source-student-q4.bin"
        )
        package_id = f"{VERIFY.EXPECTED_SOURCE}#betlang@0.1.1"
        self.metadata = {
            "packages": [
                {
                    "name": "companion-core",
                    "version": "0.1.0",
                    "id": "path+core",
                    "manifest_path": str(self.root / "crates/core/Cargo.toml"),
                    "dependencies": [
                        {
                            "name": "betlang",
                            "rename": None,
                            "kind": None,
                            "req": "=0.1.1",
                        }
                    ],
                },
                {
                    "name": "language-eval",
                    "version": "0.1.0",
                    "id": "path+eval",
                    "manifest_path": str(
                        self.root / "tools/language-eval/Cargo.toml"
                    ),
                    "dependencies": [
                        {
                            "name": "betlang",
                            "rename": None,
                            "kind": None,
                            "req": "=0.1.1",
                        }
                    ],
                },
                {
                    "name": "betlang",
                    "version": "0.1.1",
                    "id": package_id,
                    "source": VERIFY.EXPECTED_SOURCE,
                    "manifest_path": str(self.package / "Cargo.toml"),
                    "dependencies": [],
                },
            ],
            "resolve": {
                "nodes": [
                    {
                        "id": "path+core",
                        "deps": [{"name": "betlang", "pkg": package_id}],
                    },
                    {
                        "id": "path+eval",
                        "deps": [{"name": "betlang", "pkg": package_id}],
                    },
                    {"id": package_id, "deps": []},
                ]
            },
        }

    def tearDown(self):
        VERIFY.EXPECTED_MODEL_SHA256 = self.original_sha
        self.temporary.cleanup()

    def test_accepts_the_exact_resolved_package_and_model(self):
        record = VERIFY.verify(self.root, self.metadata)
        self.assertIn("model-size=47840", record)

    def test_rejects_loose_manifest_requirement(self):
        manifest = self.root / "crates/core/Cargo.toml"
        manifest.write_text(manifest.read_text().replace('"=0.1.1"', '"0.1.1"'))
        with self.assertRaisesRegex(VERIFY.VerificationError, "must declare"):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_lockfile_version_drift(self):
        lock = self.root / "Cargo.lock"
        lock.write_text(
            lock.read_text().replace('version = "0.1.1"', 'version = "0.1.2"')
        )
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "Cargo.lock betlang version drifted"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_resolved_version_drift(self):
        self.metadata["packages"][2]["version"] = "0.1.2"
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "resolved betlang version drifted"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_lock_checksum_drift(self):
        lock = self.root / "Cargo.lock"
        lock.write_text(
            lock.read_text().replace(VERIFY.EXPECTED_CRATE_CHECKSUM, "0" * 64)
        )
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "package checksum drifted"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_missing_resolved_manifest(self):
        (self.package / "Cargo.toml").unlink()
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "resolved betlang manifest is missing"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_missing_model(self):
        (self.package / "assets/magika/source-student-q4.bin").unlink()
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "resolved Betlang model is missing"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_model_size_drift(self):
        (self.package / "assets/magika/source-student-q4.bin").write_bytes(b"x")
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "model size drifted"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_model_hash_drift(self):
        model = self.package / "assets/magika/source-student-q4.bin"
        model.write_bytes(b"y" * VERIFY.EXPECTED_MODEL_SIZE)
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "model SHA-256 drifted"
        ):
            VERIFY.verify(self.root, self.metadata)

    def test_rejects_path_or_git_resolution(self):
        self.metadata["packages"][2]["source"] = None
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "resolved betlang source drifted"
        ):
            VERIFY.verify(self.root, self.metadata)


if __name__ == "__main__":
    unittest.main()
