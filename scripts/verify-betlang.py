#!/usr/bin/env python3
"""Fail-closed verification of the Betlang package and embedded model."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import tomllib

EXPECTED_VERSION = "0.1.1"
EXPECTED_REQUIREMENT = "=0.1.1"
EXPECTED_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"
EXPECTED_CRATE_CHECKSUM = (
    "5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7"
)
EXPECTED_MODEL_SIZE = 47_840
EXPECTED_MODEL_SHA256 = (
    "8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083"
)
DIRECT_USERS = ("crates/core/Cargo.toml", "tools/language-eval/Cargo.toml")


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def load_toml(path: Path) -> dict:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise VerificationError(f"cannot read {path}: {error}") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise VerificationError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def cargo_metadata(root: Path) -> dict:
    command = ["cargo", "metadata", "--locked", "--format-version", "1"]
    completed = subprocess.run(
        command, cwd=root, capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        detail = (
            completed.stderr.strip()
            or completed.stdout.strip()
            or "no diagnostic"
        )
        raise VerificationError(f"cargo metadata --locked failed: {detail}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise VerificationError(
            f"cargo metadata returned invalid JSON: {error}"
        ) from error


def verify(root: Path, metadata: dict) -> str:
    root = root.resolve()

    for relative in DIRECT_USERS:
        manifest = root / relative
        document = load_toml(manifest)
        requirement = document.get("dependencies", {}).get("betlang")
        require(
            requirement == EXPECTED_REQUIREMENT,
            f'{relative} must declare betlang = "{EXPECTED_REQUIREMENT}" exactly',
        )

    lock = load_toml(root / "Cargo.lock")
    locked = [
        package
        for package in lock.get("package", [])
        if package.get("name") == "betlang"
    ]
    require(
        len(locked) == 1,
        f"Cargo.lock must contain exactly one betlang package; found {len(locked)}",
    )
    locked_package = locked[0]
    require(
        locked_package.get("version") == EXPECTED_VERSION,
        "Cargo.lock betlang version drifted",
    )
    require(
        locked_package.get("source") == EXPECTED_SOURCE,
        "Cargo.lock betlang source drifted",
    )
    require(
        locked_package.get("checksum") == EXPECTED_CRATE_CHECKSUM,
        "Cargo.lock betlang package checksum drifted",
    )

    packages = metadata.get("packages", [])
    resolved = [
        package for package in packages if package.get("name") == "betlang"
    ]
    require(
        len(resolved) == 1,
        f"Cargo must resolve exactly one betlang package; found {len(resolved)}",
    )
    package = resolved[0]
    require(
        package.get("version") == EXPECTED_VERSION,
        "resolved betlang version drifted",
    )
    require(
        package.get("source") == EXPECTED_SOURCE,
        "resolved betlang source drifted",
    )
    package_id = package.get("id")
    require(
        isinstance(package_id, str) and bool(package_id),
        "resolved betlang package has no package ID",
    )

    workspace_users = {}
    for package_entry in packages:
        manifest_path = package_entry.get("manifest_path")
        if not isinstance(manifest_path, str):
            continue
        try:
            relative = str(Path(manifest_path).resolve().relative_to(root))
        except ValueError:
            continue
        if relative in DIRECT_USERS:
            workspace_users[relative] = package_entry

    require(
        set(workspace_users) == set(DIRECT_USERS),
        "cargo metadata omitted a Betlang consumer",
    )
    for relative, package_entry in workspace_users.items():
        direct = [
            dependency
            for dependency in package_entry.get("dependencies", [])
            if dependency.get("name") == "betlang"
        ]
        require(
            len(direct) == 1,
            f"{relative} must have exactly one direct betlang dependency",
        )
        dependency = direct[0]
        require(
            dependency.get("rename") is None,
            f"{relative} must not rename betlang",
        )
        require(
            dependency.get("kind") is None,
            f"{relative} betlang must be a normal dependency",
        )
        require(
            dependency.get("req") == EXPECTED_REQUIREMENT,
            f"{relative} resolved requirement drifted",
        )

    nodes = metadata.get("resolve", {}).get("nodes", [])
    node_by_id = {node.get("id"): node for node in nodes}
    for relative, package_entry in workspace_users.items():
        node = node_by_id.get(package_entry.get("id"))
        if node is None:
            raise VerificationError(f"cargo resolve graph omitted {relative}")
        edges = [
            dependency
            for dependency in node.get("deps", [])
            if dependency.get("name") == "betlang"
        ]
        require(
            len(edges) == 1, f"{relative} must resolve exactly one betlang edge"
        )
        require(
            edges[0].get("pkg") == package_id,
            f"{relative} resolves an unexpected betlang package",
        )

    manifest_path = Path(package.get("manifest_path", ""))
    require(manifest_path.is_file(), "resolved betlang manifest is missing")
    model = manifest_path.parent / "assets/magika/source-student-q4.bin"
    require(model.exists(), f"resolved Betlang model is missing: {model}")
    require(
        not model.is_symlink(),
        f"resolved Betlang model must not be a symlink: {model}",
    )
    require(
        model.is_file(),
        f"resolved Betlang model is not a regular file: {model}",
    )
    require(
        model.stat().st_size == EXPECTED_MODEL_SIZE,
        f"Betlang model size drifted: {model.stat().st_size}",
    )
    model_digest = sha256(model)
    require(
        model_digest == EXPECTED_MODEL_SHA256,
        f"Betlang model SHA-256 drifted: {model_digest}",
    )

    return "\n".join(
        (
            "schema=1",
            f"package-id={package_id}",
            f"crate-checksum={EXPECTED_CRATE_CHECKSUM}",
            f"model-size={EXPECTED_MODEL_SIZE}",
            f"model-sha256={EXPECTED_MODEL_SHA256}",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parent.parent
    )
    parser.add_argument(
        "--metadata",
        type=Path,
        help="Use metadata JSON from this file (tests only)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        metadata = (
            json.loads(args.metadata.read_text())
            if args.metadata
            else cargo_metadata(root)
        )
        print(verify(root, metadata))
    except (OSError, json.JSONDecodeError, VerificationError) as error:
        print(f"betlang verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
