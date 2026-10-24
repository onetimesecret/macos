#!/usr/bin/env python3
"""Fetch pinned upstreams and compile independent C parser harnesses."""

import datetime
import hashlib
import json
import os
import platform
import shlex
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PIN = "08ddb528923cc1a6527e02b7a1aee9e516ca749a"
CM_PIN = "eec0eeba6d31189fd828314576494566d539b1e3"
GFM = REPO / "shell/.build/index-build/checkouts/swift-cmark"
CM = ROOT / "vendor/cmark-0.31.2"
GFM_OFFICIAL = ROOT / "vendor/cmark-gfm-0.29.0.gfm.0"
GFM_OFFICIAL_PIN = "b8eb2e00de094999f978e9cb02b1a78d810812d3"
ENV = dict(
    os.environ,
    TMPDIR=str(ROOT / "build/tmp"),
    CLANG_MODULE_CACHE_PATH=str(ROOT / "build/module-cache"),
)
LOG = ROOT / "results/build-commands.jsonl"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, cwd=REPO):
    args = [str(a) for a in args]
    print("+ " + shlex.join(args), flush=True)
    result = subprocess.run(
        args,
        cwd=cwd,
        env=ENV,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
    )
    with LOG.open("a") as log:
        log.write(
            json.dumps(
                {
                    "argv": args,
                    "cwd": str(cwd),
                    "exit": result.returncode,
                    "output": result.stdout,
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    return result.stdout.strip()


def source_manifest(path):
    revision = run(["git", "--no-pager", "rev-parse", "HEAD"], path)
    status = run(
        [
            "git",
            "--no-optional-locks",
            "status",
            "--porcelain",
            "--untracked-files=no",
        ],
        path,
    )
    if status:
        raise RuntimeError(f"Modified parser checkout: {path}")
    names = run(["git", "--no-pager", "ls-files"], path).splitlines()
    files = {
        name: sha(path / name) for name in names if (path / name).is_file()
    }
    return {
        "path": str(path.relative_to(REPO)),
        "revision": revision,
        "tracked_status": status,
        "files_sha256": files,
        "manifest_sha256": hashlib.sha256(
            json.dumps(files, sort_keys=True).encode()
        ).hexdigest(),
    }


def download(url, target):
    print("+ GET " + url, flush=True)
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            body = response.read()
            record = {
                "url": url,
                "final_url": response.url,
                "status": response.status,
                "sha256": hashlib.sha256(body).hexdigest(),
                "bytes": len(body),
            }
        target.write_bytes(body)
    except Exception as error:
        record = {"url": url, "error": str(error)}
    with LOG.open("a") as log:
        log.write(json.dumps({"download": record}) + "\n")
    return record


def main():
    for directory in ("vendor", "results", "build/tmp"):
        (ROOT / directory).mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as log:
        log.write(
            json.dumps(
                {
                    "run_started_utc": datetime.datetime.now(
                        datetime.UTC
                    ).isoformat()
                }
            )
            + "\n"
        )
    version = {
        name: run(command)
        for name, command in {
            "clang": ["clang", "--version"],
            "cmake": ["cmake", "--version"],
            "python": ["python3", "--version"],
            "git": ["git", "--version"],
        }.items()
    }
    if run(["git", "--no-pager", "rev-parse", "HEAD"], GFM) != PIN:
        raise RuntimeError(
            "Pinned swift-cmark checkout does not match Package.resolved"
        )
    if not CM.exists():
        run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                "0.31.2",
                "https://github.com/commonmark/cmark.git",
                CM,
            ]
        )
    if run(["git", "--no-pager", "rev-parse", "HEAD"], CM) != CM_PIN:
        raise RuntimeError("Official cmark tag revision mismatch")
    if not GFM_OFFICIAL.exists():
        run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                "0.29.0.gfm.0",
                "https://github.com/github/cmark-gfm.git",
                GFM_OFFICIAL,
            ]
        )
    if (
        run(["git", "--no-pager", "rev-parse", "HEAD"], GFM_OFFICIAL)
        != GFM_OFFICIAL_PIN
    ):
        raise RuntimeError("Official GFM tag revision mismatch")
    cm_source = source_manifest(CM)
    gfm_source = source_manifest(GFM)
    gfm_official_source = source_manifest(GFM_OFFICIAL)
    corpora = {
        "commonmark": download(
            "https://spec.commonmark.org/0.31.2/spec.json",
            ROOT / "results/commonmark-0.31.2-spec.json",
        ),
        "gfm": download(
            "https://github.github.com/gfm/",
            ROOT / "results/gfm-0.29-spec.html",
        ),
    }
    corpus_pins = {
        "commonmark": "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20",
        "gfm": "b153d814fdfc8624bb6da7449162c1cd707a637f7d1c1b636eb44b9cf63fa220",
    }
    for name, expected_hash in corpus_pins.items():
        if corpora[name].get("sha256") != expected_hash:
            raise RuntimeError(
                f"Official corpus unavailable or checksum changed: {name}"
            )
    run(
        [
            "cmake",
            "-S",
            CM,
            "-B",
            ROOT / "build/commonmark",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_TESTING=OFF",
            "-DCMARK_SHARED=OFF",
            "-DCMARK_STATIC=ON",
        ]
    )
    run(
        [
            "cmake",
            "--build",
            ROOT / "build/commonmark",
            "--target",
            "cmark_static",
            "--parallel",
            "4",
        ]
    )
    run(
        [
            "clang",
            "-std=c99",
            "-O2",
            "-Wall",
            "-Wextra",
            "-DCMARK_STATIC_DEFINE",
            "-I" + str(CM / "src"),
            "-I" + str(ROOT / "build/commonmark/src"),
            ROOT / "harness.c",
            ROOT / "build/commonmark/src/libcmark.a",
            "-o",
            ROOT / "build/commonmark-parser",
        ]
    )
    run(
        [
            "clang",
            "-std=c99",
            "-O2",
            "-Wall",
            "-Wextra",
            "-DLAB_GFM",
            "-DCMARK_GFM_STATIC_DEFINE",
            "-I" + str(GFM / "src/include"),
            "-I" + str(GFM / "extensions/include"),
            ROOT / "harness.c",
            *sorted((GFM / "src").glob("*.c")),
            *sorted((GFM / "extensions").glob("*.c")),
            "-o",
            ROOT / "build/gfm-parser",
        ]
    )
    run(
        [
            "cmake",
            "-S",
            GFM_OFFICIAL,
            "-B",
            ROOT / "build/gfm-official",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMARK_TESTS=OFF",
            "-DCMARK_SHARED=OFF",
            "-DCMARK_STATIC=ON",
        ]
    )
    run(
        [
            "cmake",
            "--build",
            ROOT / "build/gfm-official",
            "--target",
            "libcmark-gfm_static",
            "libcmark-gfm-extensions_static",
            "--parallel",
            "4",
        ]
    )
    run(
        [
            "clang",
            "-std=c99",
            "-O2",
            "-Wall",
            "-Wextra",
            "-DLAB_GFM",
            "-DCMARK_STATIC_DEFINE",
            "-DCMARKEXTENSIONS_STATIC_DEFINE",
            "-I" + str(GFM_OFFICIAL / "src"),
            "-I" + str(GFM_OFFICIAL / "extensions"),
            "-I" + str(ROOT / "build/gfm-official/src"),
            "-I" + str(ROOT / "build/gfm-official/extensions"),
            ROOT / "harness.c",
            ROOT / "build/gfm-official/extensions/libcmark-gfm-extensions.a",
            ROOT / "build/gfm-official/src/libcmark-gfm.a",
            "-o",
            ROOT / "build/gfm-official-parser",
        ]
    )
    provenance = {
        "created_utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "repository_revision": run(["git", "--no-pager", "rev-parse", "HEAD"]),
        "platform": platform.platform(),
        "tools": version,
        "package_resolved_sha256": sha(REPO / "shell/Package.resolved"),
        "commonmark": cm_source,
        "gfm": gfm_source,
        "gfm-official": gfm_official_source,
        "corpora": corpora,
        "harness_sha256": sha(ROOT / "harness.c"),
        "binaries": {},
    }
    for name in ("commonmark", "gfm", "gfm-official"):
        binary = ROOT / f"build/{name}-parser"
        provenance["binaries"][name] = {
            "version": run([binary, "--version"]),
            "sha256": sha(binary),
            "punctuation": json.loads(run([binary, "--classify"])),
        }
    (ROOT / "results/provenance.json").write_text(
        json.dumps(provenance, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
