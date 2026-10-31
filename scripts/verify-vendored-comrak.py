#!/usr/bin/env python3
"""Check the comrak source inventory and optionally reproduce it from crates.io."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

if sys.version_info < (3, 11):
    sys.exit("verify-vendored-comrak.py needs Python 3.11 or later (for tomllib)")

import tomllib  # noqa: E402

VERSION = "0.57.0"
ARCHIVE_SHA256 = "b5ef59c72b988dfc7c73ec58ec0dc50f95dd87d7f1f39f428902bc379cea8507"
ARCHIVE_URL = "https://static.crates.io/crates/comrak/comrak-0.57.0.crate"
INVENTORY = "crates/markdown/patches/comrak-0.57.0-vendor.json"
INVENTORY_SHA256 = "140779a3fcfbcf33107445313d614686978356552e7bbb7f157b206e6e495eca"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_notice_metadata(notices: str, vendor: Path) -> None:
    visible = re.sub(r"[\uFE00-\uFE0F\U000E0100-\U000E01EF]", "", notices)
    sections = re.findall(r"^=+\n(comrak[^\n]*)\n=+\n(.*?)(?=^=+\n|\Z)", visible, re.MULTILINE | re.DOTALL)
    require(len(sections) == 1, "comrak notice section is missing or duplicated")
    title, section = sections[0]
    package = tomllib.loads((vendor / "Cargo.toml").read_text(encoding="utf-8"))["package"]
    revision = json.loads((vendor / ".cargo_vcs_info.json").read_text(encoding="utf-8"))["git"]["sha1"]
    require(title == f'comrak {package["version"]}', "comrak notice version differs")
    for label, pattern, expected in [
        ("package URL", r"^Package: ([^\n]+)$", f"https://crates.io/crates/comrak/{VERSION}"),
        ("archive checksum", r"^Registry package checksum SHA-256:\n([^\n]+)$", ARCHIVE_SHA256),
        ("upstream revision", r"^Upstream revision recorded in the published package:\n([^\n]+)$", revision),
        ("license expression", r"^Published license expression: ([^\n]+)$", package["license"]),
    ]:
        require(re.findall(pattern, section, re.MULTILINE) == [expected], f"comrak notice {label} differs")


def verify_tree(root: Path) -> dict:
    inventory_bytes = (root / INVENTORY).read_bytes()
    require(digest(inventory_bytes) == INVENTORY_SHA256, "vendor inventory changed")
    inventory = json.loads(inventory_bytes)
    require(inventory["archive_sha256"] == ARCHIVE_SHA256, "archive checksum changed")
    require(inventory["archive_url"] == ARCHIVE_URL, "archive URL changed")
    vendor = root / "vendor/comrak"
    require(not vendor.is_symlink(), "vendor root is a symlink")
    pinned_roots = {Path(relative).parts[0] for relative in inventory["files"]}
    generated = {"target", "Cargo.lock"} - pinned_roots
    paths = []
    for path in vendor.iterdir():
        if path.name in generated:
            continue
        paths.append(path)
        if path.is_dir() and not path.is_symlink():
            paths.extend(path.rglob("*"))
    require(not any(path.is_symlink() for path in paths), "vendor tree contains a symlink")
    actual = {str(path.relative_to(vendor)) for path in paths if path.is_file()}
    require(actual == set(inventory["files"]), "vendor file list changed")
    for relative, expected in inventory["files"].items():
        require(digest((vendor / relative).read_bytes()) == expected, f"vendor file changed: {relative}")
    notices = root / "THIRD_PARTY_NOTICES.md"
    require(notices.is_file() and (vendor / "COPYING").read_bytes() in notices.read_bytes(),
            "THIRD_PARTY_NOTICES.md must reproduce vendored comrak COPYING bytes exactly")
    verify_notice_metadata(notices.read_text(encoding="utf-8"), vendor)
    for name, expected in inventory["patches"].items():
        patch = root / "crates/markdown/patches" / name
        require(digest(patch.read_bytes()) == expected, f"patch changed: {name}")

    manifest = tomllib.loads((root / "crates/markdown/Cargo.toml").read_text(encoding="utf-8"))
    require(manifest["dependencies"]["comrak"] == {
        "version": f"={VERSION}", "path": "../../vendor/comrak", "default-features": False,
    }, "companion-markdown must use the vendored comrak with default features disabled")
    require(any(target.get("name") == "comrak_reference_sourcepos" and
                target.get("path") == "../../vendor/comrak/tests/reference_sourcepos.rs"
                for target in manifest.get("test", [])), "comrak regression test target is missing")
    workspace = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))["workspace"]
    require("vendor/comrak" in workspace.get("exclude", []), "vendor/comrak must be outside the workspace")
    lock = tomllib.loads((root / "Cargo.lock").read_text(encoding="utf-8"))
    packages = [package for package in lock["package"] if package["name"] == "comrak"]
    require(len(packages) == 1 and packages[0]["version"] == VERSION and
            "source" not in packages[0] and "checksum" not in packages[0],
            "Cargo.lock must resolve only the vendored comrak package")
    return inventory


def upstream_archive(archive: Path | None) -> bytes:
    if archive is not None:
        data = archive.read_bytes()
    else:
        cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
        cached = sorted((cargo_home / "registry/cache").glob(f"*/comrak-{VERSION}.crate"))
        if cached:
            data = cached[0].read_bytes()
        else:
            with urllib.request.urlopen(ARCHIVE_URL, timeout=30) as response:
                data = response.read(1_000_001)
            require(len(data) <= 1_000_000, "upstream archive exceeds the download limit")
    require(digest(data) == ARCHIVE_SHA256, "upstream archive checksum mismatch")
    return data


def verify_upstream(root: Path, inventory: dict, archive: Path | None) -> None:
    data = upstream_archive(archive)
    prefix = f"comrak-{VERSION}/"
    expected = inventory["files"]
    excluded = set(inventory["excluded_files"])
    require(len(excluded) == len(inventory["excluded_files"]), "duplicate excluded archive files")
    require(not excluded.intersection(expected), "excluded archive file is also vendored")
    observed_exclusions = set()
    with tempfile.TemporaryDirectory(prefix="verify-comrak-") as temporary:
        rebuilt = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as package:
            for member in package.getmembers():
                if not member.isfile() or not member.name.startswith(prefix):
                    continue
                relative = member.name[len(prefix):]
                if relative not in expected:
                    require(relative in excluded, f"unlisted archive file exclusion: {relative}")
                    observed_exclusions.add(relative)
                    continue
                source = package.extractfile(member)
                require(source is not None, f"cannot read archive member: {relative}")
                target = rebuilt / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read())
        require(observed_exclusions == excluded, "excluded archive file list differs")
        (rebuilt / "tests").mkdir(exist_ok=True)
        for name in inventory["patches"]:
            completed = subprocess.run(
                ["patch", "-p1", "-F", "0", "-t", "-i", str(root / "crates/markdown/patches" / name)],
                cwd=rebuilt, capture_output=True, text=True, encoding="utf-8", check=False,
            )
            require(completed.returncode == 0, f"cannot apply {name}: {completed.stdout}{completed.stderr}")
        actual = {str(path.relative_to(rebuilt)) for path in rebuilt.rglob("*") if path.is_file()}
        require(actual == set(expected), "reproduced vendor file list differs")
        for relative, checksum in expected.items():
            require(digest((rebuilt / relative).read_bytes()) == checksum,
                    f"archive plus patches differs: {relative}")


def advisory_lock(root: Path) -> str:
    text = (root / "Cargo.lock").read_text(encoding="utf-8")
    blocks = re.split(r"(?=^\[\[package\]\]$)", text, flags=re.MULTILINE)
    packages = [(tomllib.loads(block)["package"][0], block) for block in blocks[1:]]
    selected = {}
    pending = ["comrak"]
    while pending:
        dependency = pending.pop()
        fields = dependency.split()
        matches = [(package, block) for package, block in packages
                   if package["name"] == fields[0] and
                   (len(fields) == 1 or package["version"] == fields[1]) and
                   (len(fields) < 3 or package.get("source") == fields[2].strip("()"))]
        require(len(matches) == 1, f"cannot identify locked advisory dependency: {dependency}")
        package, block = matches[0]
        key = (package["name"], package["version"])
        if key in selected:
            continue
        if package["name"] == "comrak":
            block = block.replace(f'version = "{VERSION}"\n',
                                  f'version = "{VERSION}"\nsource = "{REGISTRY}"\n'
                                  f'checksum = "{ARCHIVE_SHA256}"\n', 1)
        else:
            require(package.get("source") == REGISTRY, f"non-registry advisory dependency: {dependency}")
        selected[key] = block.strip() + "\n"
        pending.extend(package.get("dependencies", []))
    probe = ('[[package]]\nname = "comrak-advisory-probe"\nversion = "0.0.0"\n'
             'dependencies = ["comrak"]\n')
    return blocks[0].rstrip() + "\n\n" + "\n".join(selected[key] for key in sorted(selected)) + "\n" + probe


def prepare_advisories(root: Path, destination: Path) -> None:
    require(not destination.exists(), f"advisory workspace already exists: {destination}")
    destination.mkdir(parents=True)
    (destination / "Cargo.toml").write_text(
        '[workspace]\n[package]\nname = "comrak-advisory-probe"\nversion = "0.0.0"\n'
        'edition = "2024"\nlicense = "MIT"\npublish = false\n[lib]\npath = "lib.rs"\n[dependencies]\n'
        f'comrak = {{ version = "={VERSION}", default-features = false }}\n', encoding="utf-8"
    )
    (destination / "lib.rs").write_text("", encoding="utf-8")
    projected = advisory_lock(root)
    (destination / "Cargo.lock").write_text(projected, encoding="utf-8")
    completed = subprocess.run(
        ["cargo", "metadata", "--manifest-path", str(destination / "Cargo.toml"), "--format-version", "1"],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    require(completed.returncode == 0, f"cannot normalize advisory workspace: {completed.stderr}")
    package_pins = lambda lock: {(package["name"], package["version"], package.get("source"), package.get("checksum"))
                                 for package in tomllib.loads(lock)["package"]}
    require(package_pins((destination / "Cargo.lock").read_text(encoding="utf-8")) == package_pins(projected),
            "advisory workspace changed locked package versions or sources")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--upstream", action="store_true", help="reproduce from the cached or downloaded official archive")
    parser.add_argument("--archive", type=Path, help="use this official archive and reproduce the vendor tree")
    parser.add_argument("--advisory-workspace", type=Path, help="prepare a new registry-origin advisory workspace with the current locked dependency versions")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        inventory = verify_tree(root)
        if args.upstream or args.archive is not None:
            verify_upstream(root, inventory, args.archive)
        if args.advisory_workspace is not None:
            prepare_advisories(root, args.advisory_workspace)
            print(f"registry-origin advisory workspace: {args.advisory_workspace}")
        print(f"comrak {VERSION}: {len(inventory['files'])} vendored files and both patches verified")
        if args.upstream or args.archive is not None:
            print(f"reproduced from crates.io archive SHA-256 {ARCHIVE_SHA256}")
    except (VerificationError, OSError, ValueError, LookupError, tarfile.TarError) as error:
        print(f"comrak verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
