"""Run copied build lanes with mocked process checks and build commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class BuildProcessGuardTests(unittest.TestCase):
    def run_lane(self, lane, *, blocked="", inspection_error=False, dist_running=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts, commands = root / "scripts", root / "commands"
            scripts.mkdir()
            commands.mkdir()
            for name in (lane, "build-lanes.sh"):
                shutil.copy(SCRIPTS / name, scripts / name)
            (scripts / "check-live-build.py").write_text('''import os, sys
from pathlib import Path
calls = Path(os.environ["GUARD_CALLS"])
args = sys.argv[1:]
with calls.open("a") as output:
    output.write("check " + " ".join(args) + "\\n")
if os.environ["GUARD_ERROR"] == "1": sys.exit(2)
if args[0] == "--running":
    marker = calls.with_suffix(".seen")
    running = os.environ["GUARD_RUNNING"] == "1" and not marker.exists()
    marker.touch()
    sys.exit(0 if running else 1)
sys.exit(1 if os.environ["GUARD_BLOCK"] and os.environ["GUARD_BLOCK"] in args[0] else 0)
''')
            programs = {
                scripts / "build-core.sh": '#!/bin/sh\necho core >> "$GUARD_CALLS"\n',
                commands / "osascript": '#!/bin/sh\necho quit >> "$GUARD_CALLS"\n',
                commands / "swift": '#!/bin/sh\necho swift >> "$GUARD_CALLS"\nexit 90\n',
                commands / "pgrep": '#!/bin/sh\necho legacy-pgrep >> "$GUARD_CALLS"\nexit 90\n',
                commands / "uname": '#!/bin/sh\necho Darwin\n',
                commands / "plutil": '#!/bin/sh\necho plutil >> "$GUARD_CALLS"\nexit 90\n',
            }
            if lane == "install.sh":
                programs[commands / "rm"] = '#!/bin/sh\necho remove >> "$GUARD_CALLS"\n'
                programs[commands / "ditto"] = '#!/bin/sh\necho copy >> "$GUARD_CALLS"\nexit 90\n'
            if lane in ("dev.sh", "install.sh"):
                programs[scripts / "package-app.sh"] = '#!/bin/sh\necho package >> "$GUARD_CALLS"\n'
            for path, body in programs.items():
                path.write_text(body)
                path.chmod(0o755)
            calls = root / "calls"
            result = subprocess.run(["bash", str(scripts / lane), "--no-launch"]
                                    if lane in ("dev.sh", "install.sh") else ["bash", str(scripts / lane)],
                                    env=dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                                             GUARD_CALLS=str(calls), GUARD_ERROR=str(int(inspection_error)),
                                             GUARD_RUNNING=str(int(dist_running)), GUARD_BLOCK=blocked,
                                             ONETIMEPAD_ENVIRONMENTS_DIR=str(root / "environments"),
                                             APP_DEST=str(root / "installed[local]")),
                                    text=True, capture_output=True)
            return result, calls.read_text().splitlines()

    def test_both_lanes_stop_before_core_when_build_executable_is_running(self):
        for lane in ("dev.sh", "package-app.sh"):
            with self.subTest(lane=lane):
                result, calls = self.run_lane(lane, blocked="shell/.build")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertIn("shell/.build", calls[0])

    def test_both_lanes_stop_on_build_process_inspection_error(self):
        for lane in ("dev.sh", "package-app.sh"):
            with self.subTest(lane=lane):
                result, calls = self.run_lane(lane, inspection_error=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_package_refuses_live_dist_before_core_or_assembly(self):
        result, calls = self.run_lane("package-app.sh", blocked="/dist/")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)
        self.assertIn("OnetimePad Local.app/Contents/MacOS", calls[1])

    def test_dev_preserves_graceful_dist_quit_before_building(self):
        result, calls = self.run_lane("dev.sh", dist_running=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls[0].endswith("shell/.build"))
        self.assertIn("--running", calls[1])
        self.assertLess(calls.index("quit"), calls.index("core"))
        self.assertLess(calls.index("core"), calls.index("package"))
        self.assertNotIn("swift", calls)

    def test_install_stops_on_inspection_error_before_quit_or_replacement(self):
        result, calls = self.run_lane("install.sh", inspection_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[0], "package")
        self.assertEqual(len(calls), 2)
        self.assertIn("--running", calls[1])
        self.assertIn("installed[local]/OnetimePad Local.app/Contents/MacOS", calls[1])
        self.assertIn("Process inspection failed", result.stderr)

    def test_install_shared_query_checks_graceful_quit_before_replacement(self):
        result, calls = self.run_lane("install.sh", dist_running=True)
        self.assertEqual(result.returncode, 90, result.stderr)
        self.assertEqual(calls[0], "package")
        self.assertLess(calls.index("quit"), calls.index("remove"))
        self.assertEqual(sum("--running" in call for call in calls), 2)
        self.assertNotIn("legacy-pgrep", calls)
        self.assertEqual(calls[-2:], ["remove", "copy"])

    def test_install_absent_process_does_not_send_quit(self):
        result, calls = self.run_lane("install.sh")
        self.assertEqual(result.returncode, 90, result.stderr)
        self.assertNotIn("quit", calls)
        self.assertNotIn("legacy-pgrep", calls)
        self.assertEqual(calls[-2:], ["remove", "copy"])

    def test_running_query_propagates_inspection_errors(self):
        source = SCRIPTS / "build-lanes.sh"
        result = subprocess.run(["bash", "-euc", f'source "{source}"\n'
                                 'python3() { return 2; }\n'
                                 'if running_from /unused; then :; fi\necho continued'],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("continued", result.stdout)
        self.assertIn("Process inspection failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
