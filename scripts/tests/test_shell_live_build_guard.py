"""Exercise the pre-build process guard without launching an app or compiler."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "test-shell.sh"


class LiveBuildGuardTests(unittest.TestCase):
    def run_guard(self, process_status):
        with tempfile.TemporaryDirectory(prefix="onetimepad-build-guard-") as directory:
            root = Path(directory) / "workspace[probe]"
            scripts = root / "scripts"
            commands = root / "commands"
            scripts.mkdir(parents=True)
            commands.mkdir()
            shutil.copy2(SCRIPT, scripts / "test-shell.sh")
            programs = {
                scripts / "build-core.sh": '#!/bin/sh\nprintf core >> "$GUARD_CALLS"\n',
                commands / "swift": '#!/bin/sh\nprintf swift >> "$GUARD_CALLS"\n',
                commands / "pgrep": '#!/bin/sh\nprintf "%s\\n" "$@" > "$GUARD_PATTERN"\nexit "$GUARD_PROCESS_STATUS"\n',
            }
            for path, body in programs.items():
                path.write_text(body)
                path.chmod(0o755)
            calls, pattern = root / "calls", root / "pattern"
            environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                               GUARD_CALLS=str(calls), GUARD_PATTERN=str(pattern),
                               GUARD_PROCESS_STATUS=str(process_status))
            result = subprocess.run(["bash", str(scripts / "test-shell.sh")], env=environment,
                                    text=True, capture_output=True)
            return result, calls.read_text() if calls.exists() else "", pattern.read_text()

    def test_running_build_stops_before_any_build_or_test(self):
        result, calls, pattern = self.run_guard(0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to rebuild", result.stderr)
        self.assertEqual(calls, "")
        self.assertIn(r"workspace\[probe\]", pattern)

    def test_no_running_build_allows_the_existing_test_lane(self):
        result, calls, _ = self.run_guard(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "coreswift")

    def test_process_inspection_failure_stops_before_building(self):
        result, calls, _ = self.run_guard(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot inspect", result.stderr)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
