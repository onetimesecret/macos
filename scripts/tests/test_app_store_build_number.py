"""Exercise the packaging script's App Store build number arguments and counter.

No signing identity, profile, compilation, or replacement of dist/ is needed.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()


def section(start_marker, end_marker, include_end=False):
    start = SCRIPT.index(start_marker)
    end = SCRIPT.index(end_marker, start)
    if include_end:
        end += len(end_marker)
    return SCRIPT[start:end]


PARSE = section("APP_STORE_MODE=0\n", "\nreject_legacy_signing_configuration\n")
RESOLVE = section(
    '  if [[ -z "${APP_STORE_BUILD_NUMBER_FILE:-}" ]]; then',
    'onetimepad-app-store-build-number"\n  fi\n',
    include_end=True,
)
RESERVE = section(
    "reserve_app_store_build_number() {", "\n}\n", include_end=True
)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS lockf")
class AppStoreBuildNumberTests(unittest.TestCase):
    def parse(self, *args):
        return subprocess.run(
            [
                "bash",
                "-euc",
                "CONFIG=release\n"
                + PARSE
                + 'echo "$CONFIG $APP_STORE_MODE $REQUESTED_BUILD_NUMBER"',
                "package-app.sh",
                *args,
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def reserve(self, counter, requested=""):
        return subprocess.run(
            [
                "bash",
                "-euc",
                RESERVE
                + 'reserve_app_store_build_number "$1" "$2"\n'
                + 'echo "$APP_STORE_BUILD_NUMBER"',
                "package-app.sh",
                str(counter),
                requested,
            ],
            capture_output=True,
            text=True,
        )

    def test_arguments_select_the_lane_and_explicit_number(self):
        for args, expected in (
            ((), "release 0 "),
            (("--debug",), "debug 0 "),
            (("--app-store",), "release 1 "),
            (("--app-store", "--build-number", "7"), "release 1 7"),
            (("--build-number", "7", "--app-store"), "release 1 7"),
        ):
            with self.subTest(args=args):
                result = self.parse(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip("\n"), expected)

    def test_invalid_arguments_are_rejected(self):
        for args in (
            ("--build-number", "7"),
            ("--app-store", "--build-number"),
            ("--app-store", "--build-number", ""),
            ("--app-store", "--build-number", "1.2"),
            ("--app-store", "--build-number", "-1"),
            ("--app-store", "--debug"),
            ("--app-store", "7"),
            ("--release",),
        ):
            with self.subTest(args=args):
                self.assertNotEqual(self.parse(*args).returncode, 0)

    def test_counter_lives_in_the_common_dir_shared_by_worktrees(self):
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main"
            linked = Path(directory) / "linked"
            git = [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.com",
            ]
            subprocess.run(["git", "init", "-q", str(main)], check=True)
            subprocess.run(
                [
                    *git,
                    "-C",
                    str(main),
                    "commit",
                    "-q",
                    "--allow-empty",
                    "-m",
                    "t",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(main), "worktree", "add", "-q", str(linked)],
                check=True,
            )
            env = {
                k: v for k, v in os.environ.items() if not k.startswith("GIT_")
            }
            env.pop("APP_STORE_BUILD_NUMBER_FILE", None)
            paths = []
            for checkout in (main, linked):
                result = subprocess.run(
                    [
                        "bash",
                        "-euc",
                        RESOLVE + 'echo "$APP_STORE_BUILD_NUMBER_FILE"',
                    ],
                    cwd=checkout,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                paths.append(result.stdout.strip())
            expected = (
                main.resolve() / ".git" / "onetimepad-app-store-build-number"
            )
            self.assertEqual(paths, [str(expected), str(expected)])

    def test_first_reservation_is_one_and_each_run_increments(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "counter"
            for expected in ("1", "2", "3"):
                result = self.reserve(counter)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(counter.read_text(), expected + "\n")
            self.assertEqual(
                sorted(p.name for p in Path(directory).iterdir()),
                ["counter", "counter.lock"],
            )

    def test_explicit_number_is_used_and_raises_the_counter(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "counter"
            counter.write_text("4\n")
            result = self.reserve(counter, "010")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "10")
            self.assertEqual(result.stderr, "")
            self.assertEqual(counter.read_text(), "10\n")
            self.assertEqual(self.reserve(counter).stdout.strip(), "11")

    def test_explicit_number_at_or_below_the_counter_warns_and_keeps_it(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "counter"
            counter.write_text("10\n")
            for requested in ("3", "10"):
                with self.subTest(requested=requested):
                    result = self.reserve(counter, requested)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), requested)
                    self.assertIn(
                        "not above the last reserved number 10", result.stderr
                    )
                    self.assertEqual(counter.read_text(), "10\n")

    def test_unreadable_counter_is_rejected_and_left_alone(self):
        for contents in ("", "abc\n", "1.2\n", "-3\n"):
            with (
                self.subTest(contents=contents),
                tempfile.TemporaryDirectory() as directory,
            ):
                counter = Path(directory) / "counter"
                counter.write_text(contents)
                self.assertNotEqual(self.reserve(counter).returncode, 0)
                self.assertEqual(counter.read_text(), contents)

    def test_concurrent_runs_never_share_a_number(self):
        runs = 24
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "counter"
            command = [
                "bash",
                "-euc",
                RESERVE
                + 'reserve_app_store_build_number "$1"\n'
                + 'echo "$APP_STORE_BUILD_NUMBER"',
                "package-app.sh",
                str(counter),
            ]
            processes = [
                subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
                for _ in range(runs)
            ]
            numbers = [int(p.communicate()[0]) for p in processes]
            self.assertEqual([p.returncode for p in processes], [0] * runs)
            self.assertEqual(sorted(numbers), list(range(1, runs + 1)))
            self.assertEqual(counter.read_text(), f"{runs}\n")


if __name__ == "__main__":
    unittest.main()
