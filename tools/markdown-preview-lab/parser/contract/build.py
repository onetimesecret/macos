#!/usr/bin/env python3
"""Offline-only direct C builds. No downloads, package resolution, or app build."""

import sys

sys.dont_write_bytecode = True
import datetime
import hashlib
import json
import os
import platform
import shlex
import subprocess
from pathlib import Path

from profiles import MODES

ROOT = Path(__file__).resolve().parent
LAB = ROOT.parent
REPO = LAB.parents[2]
BUILD = ROOT / "build/review"
RESULTS = ROOT / "results/review"
ENV = dict(
    os.environ,
    TMPDIR=str(BUILD / "tmp"),
    CLANG_MODULE_CACHE_PATH=str(BUILD / "module-cache"),
)
PINS = {
    "commonmark": (
        LAB / "vendor/cmark-0.31.2",
        "eec0eeba6d31189fd828314576494566d539b1e3",
        "0.31.2",
    ),
    "gfm": (
        REPO / "shell/.build/index-build/checkouts/swift-cmark",
        "08ddb528923cc1a6527e02b7a1aee9e516ca749a",
        "0.29.0.gfm.13",
    ),
    "gfm-official": (
        LAB / "vendor/cmark-gfm-0.29.0.gfm.0",
        "b8eb2e00de094999f978e9cb02b1a78d810812d3",
        "0.29.0.gfm.0",
    ),
}
WRAPPER = REPO / "shell/.build/index-build/checkouts/swift-markdown"
WRAPPER_PIN = "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv, cwd=REPO):
    argv = [str(arg) for arg in argv]
    result = subprocess.run(
        argv,
        cwd=cwd,
        env=ENV,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    with (RESULTS / "build-commands.jsonl").open("a") as output:
        output.write(
            json.dumps(
                dict(
                    argv=argv,
                    cwd=str(cwd),
                    exit=result.returncode,
                    output=result.stdout,
                )
            )
            + "\n"
        )
    result.check_returncode()
    return result.stdout.strip()


def validate_source_manifest(source, expected):
    actual = {}
    for name, digest in expected.items():
        try:
            actual[name] = sha(source / name)
        except OSError as error:
            raise RuntimeError(
                f"Pinned source unavailable: {source / name}"
            ) from error
        if actual[name] != digest:
            raise RuntimeError(f"Pinned source changed: {source / name}")
    return actual


def dependency_name(path, repo=REPO):
    try:
        return str(path.relative_to(repo))
    except ValueError:
        return str(path)


def read_dependencies(path, cwd=REPO):
    text = path.read_text().replace("\\\r\n", " ").replace("\\\n", " ")
    if ":" not in text:
        raise RuntimeError(f"Invalid compiler dependency output: {path}")
    dependencies = shlex.split(text.split(":", 1)[1], comments=False)
    if not dependencies:
        raise RuntimeError(f"Empty compiler dependency output: {path}")
    return sorted(
        {(cwd / name.replace("$$", "$")).resolve() for name in dependencies}
    )


def protected_files():
    paths = [
        path
        for path in LAB.rglob("*")
        if path.is_file()
        and ROOT not in path.parents
        and ".git" not in path.relative_to(LAB).parts
    ]
    paths += [
        REPO / name
        for name in (
            "AGENTS.md",
            "shell/Package.swift",
            "shell/Package.resolved",
            "shell/Sources/CompanionKit/MarkdownPreviewView.swift",
            "docs/spec/design/2026-1016-markdown-dialects-and-preview.md",
        )
    ]
    return {str(path.relative_to(REPO)): sha(path) for path in sorted(paths)}


def wrapper_evidence():
    if (
        command(["git", "--no-pager", "rev-parse", "HEAD"], WRAPPER)
        != WRAPPER_PIN
    ):
        raise RuntimeError("Swift wrapper revision changed")
    ranges = {
        "Sources/Markdown/Parser/CommonMarkConverter.swift": [(588, 627)],
        "Sources/Markdown/Parser/ParseOptions.swift": [(19, 32)],
    }
    result = {"revision": WRAPPER_PIN, "files": {}}
    for name, slices in ranges.items():
        path = WRAPPER / name
        lines = path.read_text().splitlines()
        result["files"][name] = {
            "sha256": sha(path),
            "excerpts": [
                {
                    "first_line": first,
                    "last_line": last,
                    "text": "\n".join(lines[first - 1 : last]),
                }
                for first, last in slices
            ],
        }
    converter = (
        WRAPPER / "Sources/Markdown/Parser/CommonMarkConverter.swift"
    ).read_text()
    for required in (
        "var cmarkOptions = CMARK_OPT_TABLE_SPANS",
        "cmarkOptions |= CMARK_OPT_SMART",
        "cmarkOptions |= CMARK_OPT_SOURCEPOS",
    ):
        if required not in converter:
            raise RuntimeError("Wrapper option mapping changed")
    return result


def main():
    for directory in (BUILD / "tmp", RESULTS):
        directory.mkdir(parents=True, exist_ok=True)
    baseline = protected_files()
    start = {
        "utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "repository_revision": command(
            ["git", "--no-pager", "rev-parse", "HEAD"]
        ),
        "status": command(
            ["git", "--no-pager", "--no-optional-locks", "status", "--short"]
        ),
        "protected_sha256": baseline,
    }
    (RESULTS / "start-state.json").write_text(
        json.dumps(start, indent=2) + "\n"
    )
    old = json.loads((LAB / "results/provenance.json").read_text())
    source_manifests = {
        candidate: validate_source_manifest(
            source, old[candidate]["files_sha256"]
        )
        for candidate, (source, _, _) in PINS.items()
    }
    provenance = {
        "created_utc": start["utc"],
        "repository_revision": start["repository_revision"],
        "platform": platform.platform(),
        "offline": True,
        "clang": command(["clang", "--version"]),
        "python": sys.version,
        "wrapper": wrapper_evidence(),
        "candidates": {},
        "contract_inputs_sha256": {
            name: sha(ROOT / name)
            for name in ("build.py", "profiles.py", "harness.c")
        },
        "prior_provenance_sha256": sha(LAB / "results/provenance.json"),
    }
    for candidate, (source, pin, version) in PINS.items():
        revision = command(["git", "--no-pager", "rev-parse", "HEAD"], source)
        if revision != pin:
            raise RuntimeError(f"Revision mismatch: {candidate}")
        source_hashes = source_manifests[candidate]
        sources = sorted(
            path
            for path in (source / "src").glob("*.c")
            if path.name != "main.c"
        )
        flags = [
            "clang",
            "-std=c99",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-mmacosx-version-min=13.0",
        ]
        if candidate == "commonmark":
            includes = [source / "src", LAB / "build/commonmark/src"]
            flags += ["-DCMARK_STATIC_DEFINE"]
        elif candidate == "gfm":
            includes = [source / "src/include", source / "extensions/include"]
            flags += ["-DLAB_GFM", "-DLAB_SWIFT", "-DCMARK_GFM_STATIC_DEFINE"]
            sources += sorted((source / "extensions").glob("*.c"))
        else:
            includes = [
                source / "src",
                source / "extensions",
                LAB / "build/gfm-official/src",
                LAB / "build/gfm-official/extensions",
            ]
            flags += [
                "-DLAB_GFM",
                "-DCMARK_STATIC_DEFINE",
                "-DCMARKEXTENSIONS_STATIC_DEFINE",
            ]
            sources += sorted((source / "extensions").glob("*.c"))
        binary = BUILD / f"{candidate}-contract"
        object_dir = BUILD / candidate
        object_dir.mkdir(parents=True, exist_ok=True)
        translation_units, objects, dependencies = [], [], set()
        for index, unit in enumerate([ROOT / "harness.c", *sources]):
            object_file = object_dir / f"{index:02d}-{unit.stem}.o"
            depfile = object_file.with_suffix(".d")
            compile_argv = (
                flags
                + ["-I" + str(path) for path in includes]
                + [
                    "-MMD",
                    "-MF",
                    str(depfile),
                    "-MT",
                    str(object_file),
                    "-c",
                    str(unit),
                    "-o",
                    str(object_file),
                ]
            )
            command(compile_argv)
            unit_dependencies = read_dependencies(depfile)
            if unit.resolve() not in unit_dependencies:
                raise RuntimeError(
                    f"Translation unit absent from dependencies: {unit}"
                )
            dependencies.update(unit_dependencies)
            objects.append(object_file)
            translation_units.append(
                dict(
                    source=str(unit.relative_to(REPO)),
                    object=str(object_file.relative_to(REPO)),
                    dependency_file=str(depfile.relative_to(REPO)),
                    dependency_file_sha256=sha(depfile),
                    dependencies=[
                        dependency_name(path) for path in unit_dependencies
                    ],
                    compile_argv=compile_argv,
                )
            )
        argv = [
            "clang",
            "-mmacosx-version-min=13.0",
            *map(str, objects),
            "-o",
            str(binary),
        ]
        command(argv)
        validate_source_manifest(source, source_hashes)
        compile_hashes = {
            dependency_name(path): sha(path) for path in sorted(dependencies)
        }
        meta = {}
        for name, mode in MODES.items():
            if mode["candidate"] != candidate:
                continue
            value = json.loads(command([binary, mode["profile"], "--meta"]))
            if (
                value["version"] != version
                or value["compiled_version"] != version
            ):
                raise RuntimeError(
                    f"Header/runtime version mismatch: {candidate}"
                )
            if (
                value["parse_options"] != mode["parse_options"]
                or value["extensions"] != mode["extensions"]
            ):
                raise RuntimeError(f"Mode configuration mismatch: {name}")
            meta[name] = value

        previous_binary = LAB / f"build/{candidate}-parser"
        previous_sha = sha(previous_binary)
        if previous_sha != old["binaries"][candidate]["sha256"]:
            raise RuntimeError(
                f"Prior executable differs from saved evidence: {candidate}"
            )
        provenance["candidates"][candidate] = {
            "source": str(source.relative_to(REPO)),
            "revision": revision,
            "version": version,
            "source_files_sha256": source_hashes,
            "compile_input_sha256": compile_hashes,
            "dependency_method": "clang -MMD -MF per translation unit; every emitted dependency hashed, including SDK metadata",
            "translation_units": translation_units,
            "binary_sha256": sha(binary),
            "previous_binary_sha256": previous_sha,
            "modes": meta,
            "build_argv": argv,
            "mach_o_load_commands": command(["otool", "-l", binary]),
        }
        print(
            f"Built {candidate} {version}: {len(sources)} C sources; {len(meta)} verified modes",
            flush=True,
        )
    if protected_files() != baseline:
        raise RuntimeError("A protected input changed during the build")
    for candidate, (source, _, _) in PINS.items():
        validate_source_manifest(source, source_manifests[candidate])
    provenance["protected_inputs_unchanged"] = True
    provenance["complete_source_manifests_match"] = True
    (RESULTS / "provenance.json").write_text(
        json.dumps(provenance, indent=2) + "\n"
    )
    print("Offline build and protected-input hash checks: PASS")


if __name__ == "__main__":
    main()
