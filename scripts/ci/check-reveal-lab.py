#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
from pathlib import Path


def main():
    commands = """set -euo pipefail
swift build --package-path tools/reveal-lab
swift run --skip-build --package-path tools/reveal-lab RevealLab --self-test
sh tools/reveal-lab/run.sh --build-only
"""
    root = Path(__file__).resolve().parents[2]
    process = subprocess.Popen(
        ["bash", "-c", commands], cwd=root, start_new_session=True
    )
    try:
        return process.wait(timeout=300)
    except subprocess.TimeoutExpired:
        print("RevealLab checks exceeded five minutes", file=sys.stderr)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
