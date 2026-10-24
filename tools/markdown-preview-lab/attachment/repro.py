#!/usr/bin/env python3
"""Build and run the bounded AppKit and external-AX experiments (stdlib only)."""

import argparse
import datetime
import json
import platform
import plistlib
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ".build"
BUNDLE = BUILD / "AttachmentLab.app"
BINARY = BUNDLE / "Contents/MacOS/AttachmentLab"
CLIENT = BUILD / "AXClient"


def run(command, timeout=90):
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {command}")
    return result.stdout


def build():
    (BUNDLE / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    cache = BUILD / "module-cache"
    cache.mkdir(exist_ok=True)
    flags = [
        "-swift-version",
        "5",
        "-module-cache-path",
        str(cache),
        "-framework",
        "AppKit",
        "-framework",
        "ApplicationServices",
    ]
    for source, binary in [("Lab.swift", BINARY), ("AXClient.swift", CLIENT)]:
        run(
            ["xcrun", "swiftc", *flags, str(ROOT / source), "-o", str(binary)],
            120,
        )
    with (BUNDLE / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "AttachmentLab",
                "CFBundleIdentifier": "dev.onetime.research.attachment-lab",
                "CFBundleName": "Attachment AX Lab",
                "CFBundlePackageType": "APPL",
                "NSHighResolutionCapable": True,
            },
            file,
        )


def execute(gui, duration):
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    output = ROOT / "runs" / stamp
    output.mkdir(parents=True)
    metadata = {
        "startedUTC": stamp,
        "platform": platform.platform(),
        "gui": gui,
        "durationSeconds": duration,
        "voiceOverVerification": "NOT PERFORMED",
        "globalSettingsChanged": False,
    }
    command = [
        str(BINARY),
        "--duration",
        str(duration),
        "--output",
        str(output),
    ]
    if not gui:
        command.append("--self-test")
    metadata["command"] = command
    with (output / "app-console.txt").open("w") as log:
        app = subprocess.Popen(
            command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT
        )
        try:
            deadline = time.monotonic() + 12
            while (
                not (output / "ready.pid").exists()
                and app.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.1)
            if not (output / "ready.pid").exists():
                raise RuntimeError(
                    f"app not ready; inspect {output / 'app-console.txt'}"
                )
            pid = int((output / "ready.pid").read_text().strip())
            metadata["targetPID"] = pid
            client_command = [
                str(CLIENT),
                str(pid),
                str(output / "external-ax.json"),
            ]
            if gui:
                client_command.append("--inspect-only")
            client = subprocess.run(
                client_command,
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=18,
            )
            (output / "ax-console.txt").write_text(client.stdout)
            metadata["axClientExit"] = client.returncode
            print(client.stdout, end="", flush=True)
            print(f"GUI PID {pid}; results: {output}", flush=True)
            app.wait(timeout=duration + 8)
            metadata["appExit"] = app.returncode
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait(timeout=3)
            (output / "run.json").write_text(
                json.dumps(metadata, indent=2) + "\n"
            )
    report = json.loads((output / "app-report.json").read_text())
    checks = report["checks"]
    failed = [check for check in checks if not check["passed"]]
    if gui:
        print(
            f"GUI run completed; self-test not requested; VoiceOver enabled={report['voiceOverEnabled']}"
        )
    else:
        print(
            f"Self-test: {len(checks) - len(failed)}/{len(checks)} passed; VoiceOver enabled={report['voiceOverEnabled']}"
        )
    for check in failed:
        print("FAIL", check["name"], check["observed"])
    ax = json.loads((output / "external-ax.json").read_text())
    outcome = {
        "selfTestPassed": None if gui else not failed,
        "selfTestCount": len(checks),
        "externalAX": "BLOCKED_TCC"
        if ax["windowsError"] == -25211
        else "INSPECTED"
        if ax["windowsError"] == 0
        else "AX_ERROR",
        "voiceOver": "NOT MANUALLY VERIFIED",
    }
    if ax["windowsError"] == -25211:
        outcome["externalActionResult"] = ax.get("deniedPressError")
    elif not gui:
        required = {
            "action-custom-quiet-plain": 2,
            "action-custom-selected-linked": 1,
            "action-custom-selected-table-image": 1,
            "native-cell-press-proxy": 1,
        }
        missing = {
            name: count
            for name, count in required.items()
            if sum(
                p["identifier"] == name and p["result"] == 0
                for p in ax["presses"]
            )
            != count
        }
        marker = next(
            (
                i
                for i, event in enumerate(report["events"])
                if event["route"] == "self-test"
                and event["object"] == "complete"
            ),
            -1,
        )
        external_events = report["events"][marker + 1 :]
        promotion = any(
            e["object"] == "plain" and e["result"] == "promoted only"
            for e in external_events
        )
        load = any(
            e["object"] == "plain" and e["result"] == "simulated load 1"
            for e in external_events
        )
        outcome.update(
            externalMissingActions=missing,
            externalPromotionAndLoadObserved=promotion and load,
        )
        if missing or not (promotion and load):
            failed.append({"name": "external AX action verification"})
    (output / "outcome.json").write_text(json.dumps(outcome, indent=2) + "\n")
    if failed or metadata["appExit"]:
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--gui",
        action="store_true",
        help="manual GUI run; no self-test mutation",
    )
    parser.add_argument(
        "--duration", type=int, help="bounded GUI lifetime, 15–900 seconds"
    )
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    if not args.no_build:
        build()
    if args.build_only:
        return 0
    duration = min(900, max(15, args.duration or (300 if args.gui else 15)))
    return execute(args.gui, duration)


if __name__ == "__main__":
    sys.exit(main())
