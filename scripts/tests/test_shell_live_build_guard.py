"""Exercise the pre-build guard with disposable command-line processes only."""
import errno
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("live_build_guard", SCRIPTS / "check-live-build.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class LiveBuildGuardTests(unittest.TestCase):
    def run_guard(self, process_status):
        with tempfile.TemporaryDirectory(prefix="onetimepad-build-guard-") as directory:
            root = Path(directory) / "workspace[probe]"
            scripts = root / "scripts"
            commands = root / "commands"
            scripts.mkdir(parents=True)
            commands.mkdir()
            shutil.copy2(SCRIPTS / "test-shell.sh", scripts / "test-shell.sh")
            shutil.copy2(SCRIPTS / "build-lanes.sh", scripts / "build-lanes.sh")
            (scripts / "check-live-build.py").write_text(
                "import os, sys\nsys.exit(int(os.environ['GUARD_PROCESS_STATUS']))\n")
            programs = {
                scripts / "build-core.sh": '#!/bin/sh\nprintf core >> "$GUARD_CALLS"\n',
                commands / "swift": '#!/bin/sh\nprintf swift >> "$GUARD_CALLS"\n',
            }
            for path, body in programs.items():
                path.write_text(body)
                path.chmod(0o755)
            calls = root / "calls"
            environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                               GUARD_CALLS=str(calls), GUARD_PROCESS_STATUS=str(process_status))
            result = subprocess.run(["bash", str(scripts / "test-shell.sh")], env=environment,
                                    text=True, capture_output=True)
            return result, calls.read_text() if calls.exists() else ""

    def test_running_build_stops_before_any_build_or_test(self):
        result, calls = self.run_guard(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_no_running_build_allows_the_existing_test_lane(self):
        result, calls = self.run_guard(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "coreswift")

    def test_process_inspection_failure_stops_before_building(self):
        result, calls = self.run_guard(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_inspection_error_is_reported_and_fails_closed(self):
        with patch.object(GUARD, "ProcessPaths", side_effect=OSError(errno.EPERM, "denied")):
            with patch("sys.stderr") as output:
                self.assertEqual(GUARD.main(["/tmp/build"]), 1)
        self.assertIn("Cannot inspect", "".join(call.args[0] for call in output.write.call_args_list))

    def test_running_query_distinguishes_present_absent_and_inspection_error(self):
        with patch.object(GUARD, "ProcessPaths"), patch.object(GUARD, "running_build") as inspect:
            inspect.return_value = True
            self.assertEqual(GUARD.main(["--running", "/tmp/build"]), 0)
            inspect.return_value = False
            self.assertEqual(GUARD.main(["--running", "/tmp/build"]), 1)
            inspect.side_effect = OSError(errno.EPERM, "denied")
            with patch("sys.stderr"):
                self.assertEqual(GUARD.main(["--running", "/tmp/build"]), 2)

    def test_process_enumeration_is_limited_to_the_current_user(self):
        processes = GUARD.ProcessPaths.__new__(GUARD.ProcessPaths)
        processes.library = Mock()

        def list_pids(kind, uid, buffer, size):
            self.assertEqual(kind, 4)
            self.assertEqual(uid, 501)
            buffer[0] = 123
            return GUARD.ctypes.sizeof(GUARD.ctypes.c_int)

        processes.library.proc_listpids.side_effect = list_pids
        with patch.object(GUARD.os, "getuid", return_value=501):
            self.assertEqual(processes.pids(), [123])

    def test_invalid_arguments_show_usage_without_inspecting_processes(self):
        for arguments in ([], ["--running"], ["--unknown"], ["a", "b"],
                          ["--running", "a", "b"]):
            with self.subTest(arguments=arguments), patch("sys.stderr") as output:
                with patch.object(GUARD, "ProcessPaths") as processes:
                    self.assertEqual(GUARD.main(arguments), 2)
                    processes.assert_not_called()
                self.assertIn("Usage:", "".join(call.args[0] for call in output.write.call_args_list))

    def test_missing_path_fails_closed(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.side_effect = OSError(errno.ENOENT, "unavailable path")
        with patch.object(GUARD, "mapped_paths", side_effect=OSError("no mappings")):
            with self.assertRaises(OSError):
                GUARD.running_build("/tmp/build", processes)

    def test_executable_permission_error_stops_inspection(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.side_effect = OSError(errno.EPERM, "denied")
        with patch.object(GUARD, "ProcessPaths", return_value=processes), patch("sys.stderr"):
            self.assertEqual(GUARD.main(["/tmp/build"]), 1)

    def test_symlinked_build_directory_matches_resolved_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "real-build"
            build.mkdir()
            alias = root / "build-alias"
            alias.symlink_to(build, target_is_directory=True)
            processes = Mock()
            processes.pids.return_value = [123]
            processes.executable.return_value = build / "program"
            self.assertTrue(GUARD.running_build(alias, processes))

    def test_unlinked_build_executable_is_detected_through_text_mappings(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.side_effect = OSError(errno.ENOENT, "unlinked")
        with patch.object(GUARD, "mapped_paths", return_value=[Path("/tmp/build/program")]):
            self.assertTrue(GUARD.running_build("/tmp/build", processes))

    def test_unlinked_unrelated_executable_does_not_block(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.side_effect = OSError(errno.ENOENT, "unlinked")
        with patch.object(GUARD, "mapped_paths", return_value=[Path("/tmp/other/program")]):
            self.assertFalse(GUARD.running_build("/tmp/build", processes))

    def test_text_mapping_paths_use_nul_separated_fields(self):
        output = subprocess.CompletedProcess([], 0, b"p123\0\nftxt\0n/tmp/a b/program\0\n", b"")
        with patch.object(GUARD.subprocess, "run", return_value=output):
            self.assertEqual(GUARD.mapped_paths(123), [Path("/tmp/a b/program")])

    def test_text_mapping_failure_does_not_skip_existing_process(self):
        output = subprocess.CompletedProcess([], 1, b"", b"denied")
        with patch.object(GUARD.subprocess, "run", return_value=output), patch.object(GUARD.os, "kill"):
            with self.assertRaises(OSError):
                GUARD.mapped_paths(123)

    def test_exited_process_is_skipped(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.return_value = None
        self.assertFalse(GUARD.running_build("/tmp/build", processes))

    def test_process_exit_during_path_lookup(self):
        processes = GUARD.ProcessPaths.__new__(GUARD.ProcessPaths)
        processes.library = Mock()
        processes.library.proc_pidpath.return_value = 0
        with patch.object(GUARD.ctypes, "get_errno", return_value=errno.ESRCH):
            self.assertIsNone(processes.executable(123))

    def test_sibling_directory_is_not_a_running_build(self):
        processes = Mock()
        processes.pids.return_value = [123]
        processes.executable.return_value = Path("/tmp/build-other/sleep")
        self.assertFalse(GUARD.running_build("/tmp/build", processes))

    @unittest.skipUnless(sys.platform == "darwin", "proc_pidpath is a macOS API")
    def test_absolute_and_relative_executable_paths_are_detected(self):
        for relative in (False, True):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                build = root / "shell" / ".build"
                build.mkdir(parents=True)
                executable = build / "guard-sleep"
                shutil.copy("/bin/sleep", executable)
                command = "./shell/.build/guard-sleep" if relative else str(executable)
                process = subprocess.Popen([command, "30"], cwd=root)
                try:
                    paths = GUARD.ProcessPaths()
                    with patch.object(paths, "pids", return_value=[process.pid]):
                        self.assertTrue(GUARD.running_build(build, paths))
                finally:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
