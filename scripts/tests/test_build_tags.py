"""Exercise the git record package-app.sh leaves for each packaged build.

The source state, stamp, and record steps are sliced from the script and run in
throwaway repositories; nothing is compiled, signed, or written to a bundle.
The last class runs build-core.sh's staleness check in a scratch checkout.
"""

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/package-app.sh").read_text()
CORE_SCRIPT = (ROOT / "scripts/build-core.sh").read_text()


def section(start_marker, end_marker, include_end=False, text=SCRIPT):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    if include_end:
        end += len(end_marker)
    return text[start:end]


READ_CALL = "\nread_source_state\n"
COMPILE = '\nif [[ "$CONFIG" == "debug" ]]; then\n  scripts/build-core.sh'
STAMPS_START = "# The stamps below and the record name"
STAMPS_END = "\n# Each lane writes its own id"
NAME_PROBE = '  ref_name_ok "refs/tags/build/$BUILD_LANE/$VERSION-1" || exit 1\n'
CI_REFUSAL = "if ((APP_STORE_MODE)) && in_ci; then\n"
REQUESTED_CHECK = (
    '  if [[ -n "$REQUESTED_BUILD_NUMBER" ]]'
    ' && ! app_store_tag_free "$REQUESTED_BUILD_NUMBER"; then\n'
)
RESERVE_CALL = '  reserve_app_store_build_number "$APP_STORE_BUILD_NUMBER_FILE"'
RESERVED_CHECK = '  if ! app_store_tag_free "$APP_STORE_BUILD_NUMBER"; then\n'
CLEANUP = section("TEMP_FILES=()\n", "trap cleanup_temp_files EXIT\n", include_end=True)
FUNCTIONS = section("worktree_tree() {", READ_CALL)
READ_SOURCE = section(READ_CALL, COMPILE)
STAMPS = section(STAMPS_START, STAMPS_END)
RESERVE = section("reserve_app_store_build_number() {", "\n}\n", include_end=True)

CORE_MARKER_START = 'BUILD_START="$(mktemp -t companion-core-build-start)"'
CORE_MARKER = section(CORE_MARKER_START, "\n\nfor t in", text=CORE_SCRIPT)
CORE_DATE = 'touch -r "$BUILD_START" "$XCF"\n'
CORE_CURRENT = section(
    '[[ -d "$XCF" && -f "$STAMP"',
    '; then\n    echo "==> $XCF is current',
    text=CORE_SCRIPT,
)

VERSION = "1.4.0"
NUMBER = "17"
DIGEST = "ab" * 32
LANES = {
    "dev": ("debug", "dev.onetimesecret.pad.debug"),
    "local": ("release", "dev.onetimesecret.pad"),
    "app-store": ("release", "com.onetimesecret.pad"),
}
KEYS = [
    "Version",
    "Build",
    "Lane",
    "Configuration",
    "Bundle identifier",
    "Source",
    "Signing",
    "Pre-signature digest",
    "Core",
    "FFI",
    "Swift",
    "Rust",
    "Xcode",
    "Built",
]
SWIFT = (
    "swift-driver version: 1.127.14.1 Apple Swift version 6.2 "
    "(swiftlang-6.2.0.19.9 clang-1700.3.19.1)"
)
TOOLS = {
    "swift": SWIFT + "\nTarget: arm64-apple-macosx26.0",
    "rustc": "rustc 1.90.0 (1159e78c4 2025-09-14)",
    "xcodebuild": "Xcode 26.0\nBuild version 17A324",
}
# Replace the steps the slices skip: plutil prints each stamp, and the
# counter hands out the requested number or else NEXT_NUMBER.
PLUTIL_STUB = """
plutil() {
  [[ $1 == -replace && $3 == -string ]] || return 1
  printf 'stamp %s=%s\\n' "$2" "$4"
}
"""
RESERVE_STUB = """
reserve_app_store_build_number() {
  APP_STORE_BUILD_NUMBER=${2:-$NEXT_NUMBER}
}
"""
CI_NOTICE = "==> CI is set, so this build writes no tag or record."
RESERVED = "==> App Store build number:"
COMPILED = "==> compiled"
REUSED = "already names this commit; its annotation is from an earlier build."
NO_SNAPSHOT = "no record: no snapshot was made of the uncommitted changes."
FIELD = re.compile(r"^([A-Z][A-Za-z -]*): (.*)$")


def tool_stubs(tools):
    lines = []
    for name, output in tools.items():
        if output is None:
            lines.append(f"{name}() {{ return 127; }}")
        else:
            lines.append(f"{name}() {{ printf '%s\\n' {shlex.quote(output)}; }}")
    return "\n".join(lines)


def write_mktemp_shim(directory, made, log):
    # Logs every path, and gives BSD `mktemp -t name` a template GNU takes too.
    real = shutil.which("mktemp")
    if real is None:
        raise unittest.SkipTest("no mktemp on PATH")
    shim = directory / "mktemp"
    shim.write_text(
        "#!/bin/sh\n"
        'if [ "$#" -eq 2 ] && [ "$1" = -t ]; then'
        f' set -- "{made}/$2.XXXXXX"; fi\n'
        f'path=$("{real}" "$@") || exit 1\n'
        f'printf \'%s\\n\' "$path" >> "{log}"\n'
        "printf '%s\\n' \"$path\"\n"
    )
    shim.chmod(0o755)


class BuildRecordTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch_name = scratch.name
        self.tmp = Path(os.path.realpath(scratch.name))
        self.home = self.tmp / "home"
        self.bin = self.tmp / "bin"
        self.made = self.tmp / "made"
        for directory in (self.home, self.bin, self.made):
            directory.mkdir()
        self.mktemp_log = self.tmp / "mktemp.log"
        self.counter = self.tmp / "counter"
        write_mktemp_shim(self.bin, self.made, self.mktemp_log)
        inherited = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("GIT_") and k not in ("CI", "XDG_CONFIG_HOME")
        }
        self.env = {
            **inherited,
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": str(self.tmp),
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
        }
        self.repo = self.init_repo(self.tmp / "repo")

    def run_git(self, *args, cwd=None):
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.repo,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def git(self, *args, cwd=None):
        result = self.run_git(*args, cwd=cwd)
        if result.returncode:
            self.fail(f"git {' '.join(args)} failed: {result.stderr}")
        return result.stdout.rstrip("\n")

    def run_bash(self, command, cwd=None):
        return subprocess.run(
            ["bash", "-c", command],
            cwd=cwd or self.repo,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def init_repo(self, path):
        path.mkdir()
        self.git("init", "-q", "-b", "main", cwd=path)
        for key, value in (
            ("user.name", "Tester"),
            ("user.email", "tester@example.com"),
            ("commit.gpgSign", "false"),
            ("tag.gpgSign", "false"),
        ):
            self.git("config", key, value, cwd=path)
        (path / "a.txt").write_text("one\n")
        (path / ".gitignore").write_text("*.log\n.build/\n")
        self.git("add", "-A", cwd=path)
        self.git("commit", "-q", "-m", "first", cwd=path)
        return path

    def build(
        self,
        lane="local",
        *,
        during="",
        before_tag="",
        real_counter=False,
        ci=None,
        cwd=None,
        tools=None,
        env=None,
        **settings,
    ):
        config, bundle_id = LANES[lane]
        values = {
            "VERSION": VERSION,
            "BUILD_LANE": lane,
            "CONFIG": config,
            "BUILD_BUNDLE_ID": bundle_id,
            "APP_STORE_MODE": "1" if lane == "app-store" else "0",
            "APP_STORE_BUILD_NUMBER": "",
            "REQUESTED_BUILD_NUMBER": NUMBER if lane == "app-store" else "",
            "NEXT_NUMBER": NUMBER,
            "APP_STORE_BUILD_NUMBER_FILE": str(self.counter),
            "APP": f"{self.tmp}/dist/OnetimePad.app",
            "BUILD_ENVIRONMENT_FILE": f"{self.tmp}/environments/{lane}/.env",
            "PROVISIONING_PROFILE": "",
            "CODESIGN_IDENTITY": "",
            "TEAM_ID": "",
            "DIGEST": DIGEST,
            "CORE_VERSION": "0.34.4",
            "FFI_VERSION": "0.41.0",
            **settings,
        }
        program = "\n".join(
            [
                "set -euo pipefail",
                CLEANUP,
                *(f"{k}={shlex.quote(v)}" for k, v in values.items()),
                PLUTIL_STUB,
                RESERVE if real_counter else RESERVE_STUB,
                tool_stubs(TOOLS if tools is None else tools),
                FUNCTIONS,
                READ_SOURCE,
                f'echo "{COMPILED}"',
                during,
                STAMPS,
                before_tag,
                "tag_build",
            ]
        )
        env = {**self.env, **(env or {})}
        if ci is not None:
            env["CI"] = ci
        result = subprocess.run(
            ["bash", "-c", program, "package-app.sh"],
            cwd=cwd or self.repo,
            env=env,
            capture_output=True,
            text=True,
        )
        if self.mktemp_log.exists():
            for path in self.mktemp_log.read_text().split():
                self.assertFalse(Path(path).exists(), f"temp file left: {path}")
        return result

    def stamps(self, result):
        return dict(
            line[len("stamp ") :].split("=", 1)
            for line in result.stdout.splitlines()
            if line.startswith("stamp ")
        )

    def refs(self, *patterns, cwd=None):
        out = self.git("for-each-ref", "--format=%(refname)", *patterns, cwd=cwd)
        return out.split("\n") if out else []

    def unreachable_commits(self, cwd=None):
        out = self.git("fsck", "--unreachable", "--no-reflogs", cwd=cwd)
        return [line for line in out.splitlines() if "unreachable commit" in line]

    def annotation(self, ref, cwd=None):
        raw = self.git("cat-file", "tag", ref, cwd=cwd)
        header, _, message = raw.partition("\n\n")
        self.assertNotIn("-----BEGIN", raw)
        self.assertNotRegex(header, r"(?m)^gpgsig")
        fields = [
            match.groups() for match in map(FIELD.match, message.split("\n")) if match
        ]
        return message, fields

    def assert_build_fields(self, fields, **expected):
        self.assertEqual([key for key, _ in fields], KEYS)
        values = dict(fields)
        self.assertRegex(values.pop("Built"), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        defaults = {
            "Signing": "ad-hoc",
            "Pre-signature digest": DIGEST,
            "Core": "0.34.4",
            "FFI": "0.41.0",
            "Swift": SWIFT,
            "Rust": "rustc 1.90.0 (1159e78c4 2025-09-14)",
            "Xcode": "Xcode 26.0 Build version 17A324",
        }
        self.assertEqual(values, {**defaults, **expected})

    def assert_git_text_shown(self, probe, stderr):
        self.assertNotEqual(probe.returncode, 0)
        lines = [line for line in probe.stderr.splitlines() if line]
        self.assertTrue(lines)
        for line in lines:
            self.assertIn(f"    {line}\n", stderr)

    def hand_command(self, stderr, after):
        lines = stderr.splitlines()
        matches = [i for i, line in enumerate(lines) if after in line]
        self.assertEqual(len(matches), 1, stderr)
        line = lines[matches[0]]
        if line.rstrip().endswith(":"):
            return lines[matches[0] + 1].strip()
        return line.split(after, 1)[1]

    def push_hints(self, result):
        return [line for line in result.stdout.splitlines() if "push with:" in line]

    def dirty(self, repo=None):
        repo = repo or self.repo
        (repo / "a.txt").write_text("one\ntwo\n")
        (repo / "new.txt").write_text("new\n")

    def second_commit(self, repo=None):
        repo = repo or self.repo
        (repo / "b.txt").write_text("b\n")
        self.git("add", "b.txt", cwd=repo)
        self.git("commit", "-q", "-m", "second", cwd=repo)
        return self.git("rev-parse", "HEAD", cwd=repo)

    def test_sliced_steps_run_in_this_order_in_the_script(self):
        for marker in (
            "TEMP_FILES=()\n",
            "trap cleanup_temp_files EXIT\n",
            "worktree_tree() {",
            READ_CALL,
            COMPILE,
            STAMPS_START,
            STAMPS_END,
            "\ncheck_source_unchanged\n",
            "\nsnapshot_source\n",
            NAME_PROBE,
            CI_REFUSAL,
            REQUESTED_CHECK,
            RESERVE_CALL,
            RESERVED_CHECK,
            "\ntag_build\n",
        ):
            self.assertEqual(SCRIPT.count(marker), 1, marker)
        for call in (CI_REFUSAL, REQUESTED_CHECK):
            self.assertIn(call, READ_SOURCE)
        for call in (
            "\ncheck_source_unchanged\n",
            "\nsnapshot_source\n",
            NAME_PROBE,
            RESERVE_CALL,
            RESERVED_CHECK,
        ):
            self.assertIn(call, STAMPS)
        order = [
            READ_CALL,
            CI_REFUSAL,
            REQUESTED_CHECK,
            COMPILE,
            'swift build --package-path shell -c "$CONFIG" --product OnetimePad',
            "\ncheck_source_unchanged\n",
            "\nsnapshot_source\n",
            NAME_PROBE,
            RESERVE_CALL,
            RESERVED_CHECK,
            "plutil -replace CFBundleVersion",
            "plutil -replace OnetimePadSourceRevision",
            "codesign --verify",
            'echo "Built $APP. Launch with',
            "\ntag_build\n",
        ]
        positions = [SCRIPT.index(marker) for marker in order]
        self.assertEqual(positions, sorted(positions))

    def test_clean_build_records_head_under_refs_builds(self):
        self.git("config", "core.abbrev", "7")
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(len(self.git("rev-parse", "--short", "HEAD")), 7)
        short = head[:12]
        for lane in ("dev", "local"):
            with self.subTest(lane=lane):
                result = self.build(lane)
                self.assertEqual(result.returncode, 0, result.stderr)
                record = f"refs/builds/{lane}/{VERSION}-{short}"
                self.assertIn(f"==> recorded {record}", result.stdout)
                self.assertEqual(self.refs(f"refs/builds/{lane}"), [record])
                self.assertEqual(self.git("cat-file", "-t", record), "tag")
                self.assertEqual(self.git("rev-parse", f"{record}^{{commit}}"), head)
                stamps = self.stamps(result)
                self.assertEqual(stamps["CFBundleVersion"], f"{VERSION}+{short}")
                self.assertEqual(stamps["OnetimePadSourceRevision"], head)
                _, fields = self.annotation(record)
                config, bundle_id = LANES[lane]
                self.assert_build_fields(
                    fields,
                    Version=VERSION,
                    Build=f"{VERSION}+{short}",
                    Lane=lane,
                    Configuration=config,
                    **{"Bundle identifier": bundle_id, "Source": head},
                )
                self.assertEqual(self.refs("refs/tags"), [])
        self.assertEqual(self.unreachable_commits(), [])

    def test_rerun_on_the_same_commit_keeps_one_record(self):
        head = self.git("rev-parse", "HEAD")
        record = f"refs/builds/local/{VERSION}-{head[:12]}"
        first = self.build("local")
        self.assertEqual(first.returncode, 0, first.stderr)
        tag = self.git("rev-parse", record)
        second = self.build("local")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn(f"record {record} {REUSED}", second.stdout)
        self.assertNotIn("==> recorded", second.stdout)
        self.assertEqual(self.refs("refs/builds", "refs/tags"), [record])
        self.assertEqual(self.git("rev-parse", record), tag)

    def test_record_on_another_commit_is_left_alone(self):
        old = self.git("rev-parse", "HEAD")
        head = self.second_commit()
        record = f"refs/builds/local/{VERSION}-{head[:12]}"
        self.git("update-ref", record, old)
        result = self.build("local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"warning: {record} names {old[:12]}, not this build's source;"
            " left as it is.",
            result.stderr,
        )
        self.assertEqual(self.git("rev-parse", record), old)
        self.assertEqual(self.refs("refs/builds", "refs/tags"), [record])

    def test_signing_config_signs_no_record_and_blocks_only_the_version_tag(self):
        failing = shutil.which("false")
        self.assertIsNotNone(failing)
        for key, value in (
            ("tag.gpgSign", "true"),
            ("commit.gpgSign", "true"),
            ("gpg.program", failing),
        ):
            self.git("config", key, value)
        # A plain annotated tag fails here, so the config is live.
        self.assertNotEqual(self.run_git("tag", "-a", "-m", "p", "probe").returncode, 0)
        head = self.git("rev-parse", "HEAD")
        clean = self.build("local")
        self.assertEqual(clean.returncode, 0, clean.stderr)
        record = f"refs/builds/local/{VERSION}-{head[:12]}"
        self.assertEqual(self.refs("refs/builds"), [record])
        self.annotation(record)

        build_tag = f"build/app-store/{VERSION}-{NUMBER}"
        app = self.build("app-store")
        self.assertEqual(app.returncode, 0, app.stderr)
        self.assertEqual(self.refs("refs/tags"), [f"refs/tags/{build_tag}"])
        self.annotation(f"refs/tags/{build_tag}")
        self.assertIn(f"warning: could not create tag v{VERSION}:", app.stderr)
        self.assertNotIn("error: the App Store package", app.stderr)
        self.assertEqual(
            self.push_hints(app), [f"    push with: git push origin {build_tag}"]
        )

        self.dirty()
        dirty = self.build("local")
        self.assertEqual(dirty.returncode, 0, dirty.stderr)
        records = [ref for ref in self.refs("refs/builds") if ref != record]
        self.assertEqual(len(records), 1, dirty.stderr)
        self.annotation(records[0])
        snapshot = self.git("rev-parse", f"{records[0]}^{{commit}}")
        self.assertNotRegex(self.git("cat-file", "commit", snapshot), r"(?m)^gpgsig")

    def test_dirty_build_records_a_snapshot_outside_refs_tags(self):
        self.dirty()
        (self.repo / "staged.txt").write_text("staged\n")
        self.git("add", "staged.txt")
        (self.repo / "ignored.log").write_text("ignored\n")
        head = self.git("rev-parse", "HEAD")
        status = self.git("status", "--porcelain")
        index = self.repo / ".git" / "index"
        before = index.read_bytes()
        result = self.build("local")
        self.assertEqual(index.read_bytes(), before)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.refs("refs/tags"), [])
        records = self.refs("refs/builds")
        self.assertEqual(len(records), 1, result.stderr)
        record = records[0]
        self.assertEqual(self.git("cat-file", "-t", record), "tag")
        snapshot = self.git("rev-parse", f"{record}^{{commit}}")
        self.assertEqual(
            self.git("rev-list", "--parents", "-n", "1", snapshot).split(),
            [snapshot, head],
        )
        tree = self.git("rev-parse", f"{snapshot}^{{tree}}")
        self.assertEqual(record, f"refs/builds/local/{VERSION}-{head[:12]}-{tree[:12]}")
        self.assertEqual(self.git("show", f"{snapshot}:a.txt"), "one\ntwo")
        self.assertEqual(self.git("show", f"{snapshot}:new.txt"), "new")
        self.assertEqual(self.git("show", f"{snapshot}:staged.txt"), "staged")
        self.assertNotEqual(
            self.run_git("cat-file", "-e", f"{snapshot}:ignored.log").returncode, 0
        )
        stamps = self.stamps(result)
        self.assertEqual(stamps["OnetimePadSourceRevision"], snapshot)
        self.assertEqual(stamps["CFBundleVersion"], f"{VERSION}+{head[:12]}.dirty")
        _, fields = self.annotation(record)
        self.assert_build_fields(
            fields,
            Version=VERSION,
            Build=f"{VERSION}+{head[:12]}.dirty",
            Lane="local",
            Configuration="release",
            **{
                "Bundle identifier": "dev.onetimesecret.pad",
                "Source": f"{head} with uncommitted changes in snapshot {snapshot}",
            },
        )
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("status", "--porcelain"), status)

        tag = self.git("rev-parse", record)
        # Another date, so a second snapshot would get another id.
        date = "2001-02-03T04:05:06Z"
        again = self.build(
            "local", env={"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
        )
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn(f"record {record} {REUSED}", again.stdout)
        self.assertEqual(self.refs("refs/builds"), [record])
        self.assertEqual(self.git("rev-parse", record), tag)
        self.assertEqual(self.stamps(again)["OnetimePadSourceRevision"], snapshot)
        self.assertEqual(self.refs("refs/tags"), [])

    def test_dirty_build_in_a_linked_worktree(self):
        linked = self.tmp / "linked"
        self.git("worktree", "add", "-q", "-b", "side", str(linked))
        (linked / "a.txt").write_text("linked\n")
        head = self.git("rev-parse", "HEAD", cwd=linked)
        linked_index = (
            Path(self.git("rev-parse", "--absolute-git-dir", cwd=linked)) / "index"
        )
        main_index = self.repo / ".git" / "index"
        before = (linked_index.read_bytes(), main_index.read_bytes())
        result = self.build("local", cwd=linked)
        self.assertEqual((linked_index.read_bytes(), main_index.read_bytes()), before)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.refs("refs/builds")
        self.assertEqual(len(records), 1, result.stderr)
        snapshot = self.git("rev-parse", f"{records[0]}^{{commit}}")
        self.assertEqual(self.git("rev-parse", f"{snapshot}^1"), head)
        self.assertEqual(self.git("show", f"{snapshot}:a.txt"), "linked")
        self.assertEqual(self.stamps(result)["OnetimePadSourceRevision"], snapshot)

    def test_tree_change_during_the_build_leaves_no_record(self):
        scenarios = (
            ("edit on a clean tree", False, "echo more >> a.txt"),
            ("edit on a dirty tree", True, "echo more >> a.txt"),
            ("untracked file appears", False, "echo x > late.txt"),
            (
                "HEAD moves and a file changes",
                False,
                "git commit -q --allow-empty -m moved && echo more >> a.txt",
            ),
        )
        for index, (name, dirty, during) in enumerate(scenarios):
            with self.subTest(name):
                repo = self.init_repo(self.tmp / f"changed{index}")
                if dirty:
                    self.dirty(repo)
                head = self.git("rev-parse", "HEAD", cwd=repo)
                result = self.build("local", during=during, cwd=repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("warning: files changed during the build", result.stderr)
                self.assertIn(
                    f"warning: stamping the build dirty against {head[:12]},"
                    " with no record.",
                    result.stderr,
                )
                self.assertIn(
                    "no record: the source changed during the build.", result.stderr
                )
                self.assertEqual(self.refs("refs/tags", "refs/builds", cwd=repo), [])
                self.assertEqual(self.unreachable_commits(cwd=repo), [])
                stamps = self.stamps(result)
                self.assertEqual(
                    stamps["CFBundleVersion"], f"{VERSION}+{head[:12]}.dirty"
                )
                self.assertEqual(stamps["OnetimePadSourceRevision"], f"{head}.dirty")

    def test_head_moving_to_the_built_tree_adopts_that_commit(self):
        cases = (
            ("clean", "local", False, "git commit -q --allow-empty -m moved"),
            ("dirty", "local", True, "git add -A && git commit -q -m moved"),
            ("app store", "app-store", False, "git commit -q --allow-empty -m moved"),
        )
        for index, (name, lane, dirty, during) in enumerate(cases):
            with self.subTest(name):
                repo = self.init_repo(self.tmp / f"adopt{index}")
                if dirty:
                    self.dirty(repo)
                old = self.git("rev-parse", "HEAD", cwd=repo)
                result = self.build(lane, during=during, cwd=repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                new = self.git("rev-parse", "HEAD", cwd=repo)
                self.assertNotEqual(new, old)
                self.assertIn(
                    f"note: HEAD moved during the build to {new[:12]}, whose tree is"
                    " the one built; recording that commit.",
                    result.stdout,
                )
                self.assertNotIn("warning", result.stderr)
                self.assertEqual(self.unreachable_commits(cwd=repo), [])
                stamps = self.stamps(result)
                self.assertEqual(stamps["OnetimePadSourceRevision"], new)
                if lane == "app-store":
                    names = [f"build/app-store/{VERSION}-{NUMBER}", f"v{VERSION}"]
                    for tag in names:
                        self.assertEqual(
                            self.git("rev-parse", f"{tag}^{{commit}}", cwd=repo), new
                        )
                    continue
                record = f"refs/builds/local/{VERSION}-{new[:12]}"
                self.assertEqual(
                    self.refs("refs/builds", "refs/tags", cwd=repo), [record]
                )
                self.assertEqual(
                    self.git("rev-parse", f"{record}^{{commit}}", cwd=repo), new
                )
                self.assertEqual(stamps["CFBundleVersion"], f"{VERSION}+{new[:12]}")
                _, fields = self.annotation(record, cwd=repo)
                self.assertEqual(dict(fields)["Source"], new)

    def test_head_moving_to_another_tree_keeps_the_original_source(self):
        for dirty in (False, True):
            with self.subTest(dirty=dirty):
                repo = self.init_repo(self.tmp / f"kept{int(dirty)}")
                first = self.git("rev-parse", "HEAD", cwd=repo)
                original = self.second_commit(repo)
                if dirty:
                    self.dirty(repo)
                result = self.build(
                    "local", during="git reset -q --soft HEAD~1", cwd=repo
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD", cwd=repo), first)
                self.assertIn(
                    "note: HEAD moved during the build, but the tree did not;"
                    f" recording against {original[:12]}.",
                    result.stdout,
                )
                records = self.refs("refs/builds", "refs/tags", cwd=repo)
                self.assertEqual(len(records), 1, result.stderr)
                stamps = self.stamps(result)
                prefix = f"refs/builds/local/{VERSION}-{original[:12]}"
                if not dirty:
                    self.assertEqual(records, [prefix])
                    self.assertEqual(
                        self.git("rev-parse", f"{prefix}^{{commit}}", cwd=repo),
                        original,
                    )
                    self.assertEqual(stamps["OnetimePadSourceRevision"], original)
                    continue
                self.assertTrue(records[0].startswith(prefix + "-"), records)
                snapshot = self.git("rev-parse", f"{records[0]}^{{commit}}", cwd=repo)
                self.assertEqual(
                    self.git("rev-parse", f"{snapshot}^1", cwd=repo), original
                )
                self.assertEqual(stamps["OnetimePadSourceRevision"], snapshot)
                self.assertEqual(
                    stamps["CFBundleVersion"], f"{VERSION}+{original[:12]}.dirty"
                )

    def test_ignored_output_during_the_build_is_no_change(self):
        during = "mkdir -p .build && echo x > .build/out && echo x > build.log"
        head = self.git("rev-parse", "HEAD")
        clean = self.build("local", during=during)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertNotIn("warning", clean.stderr)
        self.assertEqual(
            self.refs("refs/builds"), [f"refs/builds/local/{VERSION}-{head[:12]}"]
        )
        self.dirty()
        dirty = self.build("local", during=during)
        self.assertEqual(dirty.returncode, 0, dirty.stderr)
        self.assertEqual(len(self.refs("refs/builds")), 2, dirty.stderr)

    def test_flagged_index_entries_make_the_build_dirty_with_no_record(self):
        names = [f"f{i}.txt" for i in range(7)]
        for name in names:
            (self.repo / name).write_text(f"{name}\n")
        self.git("add", *names)
        self.git("commit", "-q", "-m", "flagged")
        self.git("update-index", "--assume-unchanged", *names[:3])
        self.git("update-index", "--skip-worktree", *names[3:])
        # An edit `git add -A` cannot see, so the tree alone reads as clean.
        (self.repo / "f0.txt").write_text("edited\n")
        head = self.git("rev-parse", "HEAD")
        result = self.build("local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assume-unchanged or skip-worktree", result.stderr)
        listed = [
            line.strip()
            for line in result.stderr.splitlines()
            if line.startswith(" " * 6)
        ]
        self.assertEqual(listed, names[:5])
        self.assertIn(NO_SNAPSHOT, result.stderr)
        self.assertIn(
            f"==> Source: {head[:12]} with uncommitted changes", result.stdout
        )
        self.assertEqual(self.refs("refs/builds", "refs/tags"), [])
        self.assertEqual(self.unreachable_commits(), [])
        stamps = self.stamps(result)
        self.assertEqual(stamps["CFBundleVersion"], f"{VERSION}+{head[:12]}.dirty")
        self.assertEqual(stamps["OnetimePadSourceRevision"], f"{head}.dirty")

        with self.subTest("app store refuses"):
            refused = self.build("app-store")
            self.assertEqual(refused.returncode, 1, refused.stdout)
            self.assertIn("--app-store packages only a committed tree", refused.stderr)
            self.assertNotIn(COMPILED, refused.stdout)
            self.assertNotIn(RESERVED, refused.stdout)
        with self.subTest("HEAD moving to the same tree stays dirty"):
            moved = self.build("local", during="git commit -q --allow-empty -m moved")
            self.assertEqual(moved.returncode, 0, moved.stderr)
            new = self.git("rev-parse", "HEAD")
            self.assertEqual(
                self.stamps(moved)["OnetimePadSourceRevision"], f"{new}.dirty"
            )
            self.assertEqual(self.refs("refs/builds", "refs/tags"), [])
        with self.subTest("one flag and no edit"):
            repo = self.init_repo(self.tmp / "flag-only")
            self.git("update-index", "--assume-unchanged", "a.txt", cwd=repo)
            only = self.build("local", cwd=repo)
            self.assertEqual(only.returncode, 0, only.stderr)
            self.assertIn(NO_SNAPSHOT, only.stderr)
            self.assertEqual(self.refs("refs/builds", "refs/tags", cwd=repo), [])
            self.assertTrue(
                self.stamps(only)["OnetimePadSourceRevision"].endswith(".dirty")
            )

    def test_app_store_refuses_a_dirty_tree_before_compiling(self):
        cases = (
            ("tracked edit", "a.txt", False, " M a.txt"),
            ("untracked file", "new.txt", False, "?? new.txt"),
            ("staged file", "staged.txt", True, "A  staged.txt"),
        )
        for index, (name, path, stage, status) in enumerate(cases):
            with self.subTest(name):
                repo = self.init_repo(self.tmp / f"refused{index}")
                (repo / path).write_text("changed\n")
                if stage:
                    self.git("add", path, cwd=repo)
                before = (repo / ".git" / "index").read_bytes()
                result = self.build("app-store", cwd=repo)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(
                    "--app-store packages only a committed tree", result.stderr
                )
                self.assertIn(status, result.stderr)
                self.assertNotIn(COMPILED, result.stdout)
                self.assertNotIn(RESERVED, result.stdout)
                self.assertEqual(self.refs("refs/tags", "refs/builds", cwd=repo), [])
                self.assertEqual((repo / ".git" / "index").read_bytes(), before)
        with self.subTest("ignored file only"):
            (self.repo / "ignored.log").write_text("x\n")
            result = self.build("app-store")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(COMPILED, result.stdout)

    def unreadable_trees(self):
        # Each yields a checkout whose HEAD resolves but whose tree cannot be read.
        corrupt = self.init_repo(self.tmp / "corrupt-index")
        (corrupt / ".git" / "index").write_bytes(b"not an index\n")
        yield "corrupt index", corrupt
        if os.geteuid() != 0:
            locked = self.init_repo(self.tmp / "unreadable-file")
            (locked / "locked.txt").write_text("secret\n")
            (locked / "locked.txt").chmod(0)
            yield "unreadable file", locked

    def test_app_store_refuses_without_a_head_or_a_readable_tree(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        unborn = self.tmp / "unborn"
        unborn.mkdir()
        self.git("init", "-q", cwd=unborn)
        no_head = "--app-store packages only a commit, and HEAD names none here"
        no_tree = (
            "--app-store packages only a commit it can compare with the tree,"
            " and the tree could not be read."
        )
        cases = [
            ("plain directory", plain, no_head),
            ("unborn branch", unborn, no_head),
        ]
        cases += [(name, repo, no_tree) for name, repo in self.unreadable_trees()]
        for name, where, message in cases:
            with self.subTest(name):
                result = self.build("app-store", cwd=where)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stderr)
                self.assertNotIn(COMPILED, result.stdout)
                self.assertNotIn(RESERVED, result.stdout)

    def test_unreadable_tree_makes_a_dev_build_dirty_with_no_record(self):
        for name, repo in self.unreadable_trees():
            with self.subTest(name):
                head = self.git("rev-parse", "HEAD", cwd=repo)
                result = self.build("local", cwd=repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    "warning: could not read the source tree, so this build counts"
                    " as dirty.",
                    result.stderr,
                )
                self.assertIn(NO_SNAPSHOT, result.stderr)
                self.assertEqual(self.refs("refs/builds", "refs/tags", cwd=repo), [])
                stamps = self.stamps(result)
                self.assertEqual(
                    stamps["CFBundleVersion"], f"{VERSION}+{head[:12]}.dirty"
                )
                self.assertEqual(stamps["OnetimePadSourceRevision"], f"{head}.dirty")

    def test_app_store_stops_before_reserving_when_the_tree_changes(self):
        result = self.build("app-store", during="echo more >> a.txt")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("warning: files changed during the build", result.stderr)
        self.assertIn(
            "--app-store stops instead, before a build number is reserved",
            result.stderr,
        )
        self.assertNotIn(RESERVED, result.stdout)
        self.assertEqual(self.stamps(result), {})
        self.assertEqual(self.refs("refs/tags", "refs/builds"), [])

    def test_app_store_build_tags_number_and_version(self):
        head = self.git("rev-parse", "HEAD")
        build_tag = f"build/app-store/{VERSION}-{NUMBER}"
        result = self.build("app-store")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(self.refs("refs/tags")),
            [f"refs/tags/{build_tag}", f"refs/tags/v{VERSION}"],
        )
        for name in (build_tag, f"v{VERSION}"):
            self.assertEqual(
                self.git("rev-parse", f"refs/tags/{name}^{{commit}}"), head
            )
        self.assertEqual(self.git("cat-file", "-t", f"refs/tags/{build_tag}"), "tag")
        self.assertEqual(
            self.push_hints(result),
            [f"    push with: git push origin {build_tag} v{VERSION}"],
        )
        stamps = self.stamps(result)
        self.assertEqual(stamps["CFBundleVersion"], NUMBER)
        self.assertEqual(stamps["OnetimePadSourceRevision"], head)
        _, fields = self.annotation(f"refs/tags/{build_tag}")
        self.assert_build_fields(
            fields,
            Version=VERSION,
            Build=NUMBER,
            Lane="app-store",
            Configuration="release",
            **{"Bundle identifier": "com.onetimesecret.pad", "Source": head},
        )
        self.assertEqual(self.refs("refs/builds"), [])

        with self.subTest("v tag already on this commit"):
            again = self.build("app-store", REQUESTED_BUILD_NUMBER="18")
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertIn(f"tag v{VERSION} {REUSED}", again.stdout)
            self.assertEqual(
                self.push_hints(again),
                [
                    "    push with: git push origin"
                    f" build/app-store/{VERSION}-18 v{VERSION}"
                ],
            )

    def test_app_store_leaves_a_version_tag_on_another_commit(self):
        old = self.git("rev-parse", "HEAD")
        self.git("tag", "-a", "-m", "by hand", f"v{VERSION}", old)
        version_tag = self.git("rev-parse", f"refs/tags/v{VERSION}")
        self.second_commit()
        result = self.build("app-store")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"warning: tag v{VERSION} names {old[:12]}, not this build's commit;"
            " left as it is.",
            result.stderr,
        )
        self.assertEqual(
            self.push_hints(result),
            [f"    push with: git push origin build/app-store/{VERSION}-{NUMBER}"],
        )
        self.assertEqual(self.git("rev-parse", f"refs/tags/v{VERSION}"), version_tag)

    def test_app_store_build_tag_failure_exits_1_before_the_version_tag(self):
        name = f"build/app-store/{VERSION}-{NUMBER}"
        error = (
            "    error: the App Store package was built, but it has no record:"
            f" tag {name} was not written,\n"
            f"    so v{VERSION} was not tagged and there is nothing to push.\n"
        )
        # The blocking tag appears after both early checks, as during signing.
        with self.subTest("git refuses the tag"):
            head = self.git("rev-parse", "HEAD")
            result = self.build("app-store", before_tag="git tag build")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(self.stamps(result)["CFBundleVersion"], NUMBER)
            self.assertIn(f"warning: could not create tag {name}:", result.stderr)
            probe = self.run_git("tag", "-a", "--no-sign", "-m", "probe", name, head)
            self.assert_git_text_shown(probe, result.stderr)
            self.assertIn(error, result.stderr)
            self.assertLess(
                result.stderr.index("run by hand: "), result.stderr.index(error)
            )
            self.assertEqual(self.refs("refs/tags", "refs/builds"), ["refs/tags/build"])
            self.assertEqual(self.push_hints(result), [])
            command = self.hand_command(result.stderr, "run by hand: ")
            self.git("tag", "-d", "build")
            by_hand = self.run_bash(command)
            self.assertEqual(by_hand.returncode, 0, by_hand.stderr)
            self.assertEqual(self.git("cat-file", "-t", f"refs/tags/{name}"), "tag")
            self.assertEqual(self.git("rev-parse", f"{name}^{{commit}}"), head)
            _, fields = self.annotation(f"refs/tags/{name}")
            self.assertEqual([key for key, _ in fields], KEYS)
        with self.subTest("tag taken after the stamps"):
            repo = self.init_repo(self.tmp / "taken-late")
            old = self.git("rev-parse", "HEAD", cwd=repo)
            self.second_commit(repo)
            result = self.build(
                "app-store",
                cwd=repo,
                before_tag=f"git tag -a -m late {shlex.quote(name)} {old}",
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(self.stamps(result)["CFBundleVersion"], NUMBER)
            self.assertIn(
                f"warning: tag {name} names {old[:12]}, not this build's commit;"
                " left as it is.",
                result.stderr,
            )
            self.assertIn(error, result.stderr)
            self.assertEqual(self.refs("refs/tags", cwd=repo), [f"refs/tags/{name}"])
            self.assertEqual(self.git("rev-parse", f"{name}^{{commit}}", cwd=repo), old)
            self.assertEqual(self.push_hints(result), [])
        with self.subTest("version tag left untouched"):
            repo = self.init_repo(self.tmp / "blocked")
            old = self.git("rev-parse", "HEAD", cwd=repo)
            self.git("tag", "-a", "-m", "by hand", f"v{VERSION}", old, cwd=repo)
            self.second_commit(repo)
            result = self.build("app-store", cwd=repo, before_tag="git tag build")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(error, result.stderr)
            self.assertNotIn(f"tag v{VERSION}", result.stderr)
            self.assertEqual(self.push_hints(result), [])

    def test_app_store_checks_the_build_tag_before_compiling_and_stamping(self):
        name = f"build/app-store/{VERSION}-{NUMBER}"
        lockf = shutil.which("lockf") is not None

        def taken_repo(directory):
            repo = self.init_repo(self.tmp / directory)
            old = self.git("rev-parse", "HEAD", cwd=repo)
            self.git("tag", "-a", "-m", "by hand", name, old, cwd=repo)
            return repo, old, self.second_commit(repo)

        with self.subTest("requested number taken"):
            repo, old, _ = taken_repo("requested-taken")
            result = self.build("app-store", cwd=repo, real_counter=lockf)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(
                f"    error: tag {name} already names {old[:12]},"
                " not this build's commit.\n"
                "--app-store stops before compiling; choose another --build-number.\n",
                result.stderr,
            )
            self.assertNotIn(COMPILED, result.stdout)
            self.assertNotIn(RESERVED, result.stdout)
            self.assertFalse(self.counter.exists())
            self.assertEqual(self.refs("refs/tags", cwd=repo), [f"refs/tags/{name}"])
        with self.subTest("requested number on this commit"):
            repo = self.init_repo(self.tmp / "requested-here")
            head = self.git("rev-parse", "HEAD", cwd=repo)
            self.git("tag", "-a", "-m", "earlier", name, head, cwd=repo)
            result = self.build("app-store", cwd=repo)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"tag {name} {REUSED}", result.stdout)
            self.assertEqual(
                self.push_hints(result),
                [f"    push with: git push origin {name} v{VERSION}"],
            )
        with self.subTest("automatic number taken"):
            repo, old, head = taken_repo("automatic-taken")
            if lockf:
                self.counter.write_text(f"{int(NUMBER) - 1}\n")
            result = self.build(
                "app-store", cwd=repo, REQUESTED_BUILD_NUMBER="", real_counter=lockf
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(COMPILED, result.stdout)
            self.assertIn(f"{RESERVED} {NUMBER} ", result.stdout)
            self.assertIn(
                f"    error: tag {name} already names {old[:12]},"
                " not this build's commit.\n"
                "--app-store stops before stamping or signing;"
                " package again to take another build number.\n",
                result.stderr,
            )
            self.assertEqual(self.stamps(result), {})
            self.assertEqual(self.refs("refs/tags", cwd=repo), [f"refs/tags/{name}"])
            if not lockf:
                return
            # The real counter keeps the number as a gap, so the next run moves on.
            self.assertEqual(self.counter.read_text(), f"{NUMBER}\n")
            again = self.build(
                "app-store", cwd=repo, REQUESTED_BUILD_NUMBER="", real_counter=True
            )
            self.assertEqual(again.returncode, 0, again.stderr)
            following = f"build/app-store/{VERSION}-{int(NUMBER) + 1}"
            self.assertEqual(
                self.git("rev-parse", f"{following}^{{commit}}", cwd=repo), head
            )
            self.assertEqual(self.counter.read_text(), f"{int(NUMBER) + 1}\n")

    def test_app_store_dry_run_finds_a_tag_in_the_way(self):
        name = f"build/app-store/{VERSION}-{NUMBER}"
        lockf = shutil.which("lockf") is not None
        stops = {
            False: "--app-store stops before compiling; choose another --build-number.",
            True: "--app-store stops before stamping or signing;"
            " package again to take another build number.",
        }
        for automatic, stop in stops.items():
            with self.subTest(automatic=automatic):
                repo = self.init_repo(self.tmp / f"in-the-way-{int(automatic)}")
                head = self.git("rev-parse", "HEAD", cwd=repo)
                self.git("tag", "build", cwd=repo)
                if automatic and lockf:
                    self.counter.write_text(f"{int(NUMBER) - 1}\n")
                settings = {"REQUESTED_BUILD_NUMBER": ""} if automatic else {}
                result = self.build(
                    "app-store", cwd=repo, real_counter=lockf, **settings
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                probe = subprocess.run(
                    ["git", "update-ref", "--stdin"],
                    input=f"start\ncreate refs/tags/{name} {head}\nprepare\nabort\n",
                    cwd=repo,
                    env=self.env,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(probe.returncode, 0)
                self.assertIn("'refs/tags/build' exists", probe.stderr)
                git_text = "".join(
                    f"    {line}\n" for line in probe.stderr.splitlines() if line
                )
                self.assertIn(
                    f"    error: tag {name} cannot be written:\n{git_text}{stop}\n",
                    result.stderr,
                )
                self.assertEqual(
                    self.refs("refs/tags", "refs/builds", cwd=repo), ["refs/tags/build"]
                )
                locks = list((repo / ".git").rglob("*.lock"))
                self.assertEqual(locks, [])
                self.assertEqual(self.stamps(result), {})
                if not automatic:
                    self.assertNotIn(COMPILED, result.stdout)
                    self.assertNotIn(RESERVED, result.stdout)
                    self.assertFalse(self.counter.exists())
                    continue
                self.assertIn(COMPILED, result.stdout)
                self.assertIn(f"{RESERVED} {NUMBER} ", result.stdout)
                if lockf:
                    self.assertEqual(self.counter.read_text(), f"{NUMBER}\n")

    def test_ci_writes_no_record_and_refuses_app_store(self):
        refusal = (
            "--app-store does not package in CI, where no build record is written."
        )
        for ci in ("true", "1"):
            with self.subTest(ci=ci, lane="app-store"):
                repo = self.init_repo(self.tmp / f"ci-{ci}-app-store")
                result = self.build("app-store", ci=ci, cwd=repo)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(refusal, result.stderr)
                self.assertNotIn(COMPILED, result.stdout)
                self.assertNotIn(RESERVED, result.stdout)
                self.assertEqual(self.refs("refs/tags", "refs/builds", cwd=repo), [])
            for lane, dirty in (("local", False), ("local", True), ("dev", False)):
                with self.subTest(ci=ci, lane=lane, dirty=dirty):
                    repo = self.init_repo(self.tmp / f"ci-{ci}-{lane}-{dirty}")
                    if dirty:
                        self.dirty(repo)
                    head = self.git("rev-parse", "HEAD", cwd=repo)
                    result = self.build(lane, ci=ci, cwd=repo)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.count(CI_NOTICE), 1)
                    self.assertEqual(
                        self.refs("refs/tags", "refs/builds", cwd=repo), []
                    )
                    self.assertEqual(self.unreachable_commits(cwd=repo), [])
                    revision = self.stamps(result)["OnetimePadSourceRevision"]
                    self.assertEqual(revision, f"{head}.dirty" if dirty else head)
        for ci in ("", "false", "0"):
            with self.subTest(ci=ci):
                repo = self.init_repo(self.tmp / f"not-ci-{ci or 'empty'}")
                head = self.git("rev-parse", "HEAD", cwd=repo)
                result = self.build("local", ci=ci, cwd=repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(CI_NOTICE, result.stdout)
                app = self.build("app-store", ci=ci, cwd=repo)
                self.assertEqual(app.returncode, 0, app.stderr)
                self.assertIn(COMPILED, app.stdout)
                self.assertEqual(
                    self.refs("refs/builds", "refs/tags", cwd=repo),
                    [
                        f"refs/builds/local/{VERSION}-{head[:12]}",
                        f"refs/tags/build/app-store/{VERSION}-{NUMBER}",
                        f"refs/tags/v{VERSION}",
                    ],
                )

    def test_failed_record_warns_and_the_build_succeeds(self):
        self.git("update-ref", "refs/builds/local", "HEAD")
        head = self.git("rev-parse", "HEAD")
        for dirty in (False, True):
            with self.subTest(dirty=dirty):
                if dirty:
                    self.dirty()
                result = self.build("local")
                self.assertEqual(result.returncode, 0, result.stderr)
                revision = self.stamps(result)["OnetimePadSourceRevision"]
                source = revision if dirty else head
                self.assertEqual(self.git("cat-file", "-t", source), "commit")
                if dirty:
                    self.assertNotEqual(source, head)
                warnings = [
                    line
                    for line in result.stderr.splitlines()
                    if "could not record" in line
                ]
                self.assertEqual(len(warnings), 1, result.stderr)
                record = warnings[0].split("could not record ", 1)[1].rstrip(":")
                self.assertTrue(record.startswith(f"refs/builds/local/{VERSION}-"))
                probe = self.run_git("update-ref", record, source, "")
                self.assert_git_text_shown(probe, result.stderr)
                self.assertIn(
                    f"    this build's source is {source}; once the cause is fixed,"
                    " keep a plain record with:\n"
                    f"    git update-ref {record} {source}\n",
                    result.stderr,
                )
                self.assertEqual(
                    self.refs("refs/builds", "refs/tags"), ["refs/builds/local"]
                )

    def test_invalid_ref_name_records_nothing(self):
        version = "1.0 beta"
        head = self.git("rev-parse", "HEAD")
        short = head[:12]
        invalid = (
            "is not a valid ref name (git check-ref-format), so it is not written."
        )
        with self.subTest("clean"):
            result = self.build("local", VERSION=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                f"warning: refs/builds/local/{version}-{short} {invalid}", result.stderr
            )
            self.assertEqual(self.refs("refs/builds", "refs/tags"), [])
            stamps = self.stamps(result)
            self.assertEqual(stamps["CFBundleVersion"], f"{version}+{short}")
            self.assertEqual(stamps["OnetimePadSourceRevision"], head)
        with self.subTest("dirty"):
            self.dirty()
            result = self.build("local", VERSION=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(
                result.stderr,
                re.escape(f"warning: refs/builds/local/{version}-{short}-")
                + r"[0-9a-f]{12} "
                + re.escape(invalid),
            )
            self.assertIn(NO_SNAPSHOT, result.stderr)
            self.assertEqual(self.refs("refs/builds", "refs/tags"), [])
            self.assertEqual(self.unreachable_commits(), [])
            stamps = self.stamps(result)
            self.assertEqual(stamps["CFBundleVersion"], f"{version}+{short}.dirty")
            self.assertEqual(stamps["OnetimePadSourceRevision"], f"{head}.dirty")
        repo = self.init_repo(self.tmp / "app-store")
        with self.subTest("app store with a requested number"):
            result = self.build("app-store", VERSION=version, cwd=repo)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn(
                f"warning: refs/tags/build/app-store/{version}-{NUMBER} {invalid}",
                result.stderr,
            )
            self.assertNotIn(COMPILED, result.stdout)
            self.assertEqual(self.refs("refs/tags", "refs/builds", cwd=repo), [])
        with self.subTest("app store with an automatic number"):
            result = self.build(
                "app-store", VERSION=version, REQUESTED_BUILD_NUMBER="", cwd=repo
            )
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn(
                f"warning: refs/tags/build/app-store/{version}-1 {invalid}",
                result.stderr,
            )
            self.assertIn(COMPILED, result.stdout)
            self.assertNotIn(RESERVED, result.stdout)
            self.assertEqual(self.stamps(result), {})
            self.assertEqual(self.refs("refs/tags", "refs/builds", cwd=repo), [])

    def test_hand_commands_paste_with_shell_characters_in_the_version(self):
        version = "1.4.0(rc)&x;y"
        head = self.git("rev-parse", "HEAD")
        build_tag = f"build/app-store/{version}-{NUMBER}"
        with self.subTest("push hint"):
            remote = self.tmp / "remote.git"
            self.git("init", "-q", "--bare", str(remote), cwd=self.tmp)
            self.git("remote", "add", "origin", str(remote))
            result = self.build("app-store", VERSION=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            hints = self.push_hints(result)
            self.assertEqual(len(hints), 1, result.stdout)
            pushed = self.run_bash(hints[0].split("push with: ", 1)[1])
            self.assertEqual(pushed.returncode, 0, pushed.stderr)
            self.assertEqual(
                self.refs("refs/tags", cwd=remote),
                sorted([f"refs/tags/{build_tag}", f"refs/tags/v{version}"]),
            )
        with self.subTest("record hint"):
            self.git("update-ref", "refs/builds/local", "HEAD")
            result = self.build("local", VERSION=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            command = self.hand_command(result.stderr, "keep a plain record with:")
            self.git("update-ref", "-d", "refs/builds/local")
            by_hand = self.run_bash(command)
            self.assertEqual(by_hand.returncode, 0, by_hand.stderr)
            self.assertEqual(
                self.git("rev-parse", f"refs/builds/local/{version}-{head[:12]}"), head
            )
        with self.subTest("tag hint"):
            repo = self.init_repo(self.tmp / "tag-hint")
            commit = self.git("rev-parse", "HEAD", cwd=repo)
            result = self.build(
                "app-store", VERSION=version, cwd=repo, before_tag="git tag build"
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            command = self.hand_command(result.stderr, "run by hand: ")
            self.git("tag", "-d", "build", cwd=repo)
            by_hand = self.run_bash(command, cwd=repo)
            self.assertEqual(by_hand.returncode, 0, by_hand.stderr)
            self.assertEqual(
                self.git("rev-parse", f"refs/tags/{build_tag}^{{commit}}", cwd=repo),
                commit,
            )

    def test_outside_a_checkout_nothing_fails_or_is_recorded(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        (plain / "a.txt").write_text("one\n")
        unborn = self.tmp / "unborn"
        unborn.mkdir()
        self.git("init", "-q", cwd=unborn)
        (unborn / "a.txt").write_text("one\n")
        for where in (plain, unborn):
            for lane in ("dev", "local"):
                with self.subTest(where=where.name, lane=lane):
                    result = self.build(lane, cwd=where)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")
                    self.assertNotIn("==> Source", result.stdout)
                    stamps = self.stamps(result)
                    self.assertEqual(stamps["CFBundleVersion"], VERSION)
                    self.assertEqual(stamps["OnetimePadSourceRevision"], "unknown")
        self.assertEqual(self.refs(cwd=unborn), [])

    def test_annotations_name_no_path_or_certificate_subject(self):
        settings = {
            "CODESIGN_IDENTITY": "Apple Development: Jane Example (ABCDE12345)",
            "TEAM_ID": "ABCDE12345",
            "PROVISIONING_PROFILE": f"{self.tmp}/profiles/dev.provisionprofile",
            "APP": f"{self.tmp}/dist/OnetimePad Local.app",
        }
        tools = {
            "swift": "/Library/Developer/Toolchains/swift-6.2/usr/bin/swift 6.2",
            "rustc": "rustc 1.90.0 (/Users/jane/.rustup/toolchains/stable)",
            "xcodebuild": None,
        }
        for lane, dirty in (("local", False), ("app-store", False), ("dev", True)):
            if dirty:
                self.dirty()
            result = self.build(lane, tools=tools, **settings)
            self.assertEqual(result.returncode, 0, result.stderr)
        refs = self.refs("refs/tags", "refs/builds")
        self.assertEqual(len(refs), 4, refs)
        for ref in refs:
            with self.subTest(ref=ref):
                message, fields = self.annotation(ref)
                self.assertNotIn("Jane Example", message)
                self.assertNotIn("Apple Development", message)
                for line in message.split("\n"):
                    value = line.split(": ", 1)[-1]
                    self.assertFalse(value.startswith("/"), line)
                    for path in (
                        "/Users/",
                        str(self.tmp),
                        self.scratch_name,
                        str(self.home),
                    ):
                        self.assertNotIn(path, line)
                if ref.startswith("refs/tags/v"):
                    continue
                values = dict(fields)
                self.assertEqual(values["Signing"], "team ABCDE12345")
                for key in ("Swift", "Rust", "Xcode"):
                    self.assertEqual(values[key], "unknown")


class CoreBuildDateTests(unittest.TestCase):
    """build-core.sh --if-stale against a scratch checkout, dated by hand."""

    INPUTS = (
        "THIRD_PARTY_NOTICES.md",
        "rust-toolchain.toml",
        "scripts/build-core.sh",
        "Cargo.toml",
        "Cargo.lock",
        "crates/core/src/lib.rs",
        "crates/ffi/include/companion_ffi.h",
    )

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(os.path.realpath(scratch.name))
        self.checkout = self.tmp / "checkout"
        self.bin = self.tmp / "bin"
        made = self.tmp / "made"
        for directory in (self.checkout, self.bin, made):
            directory.mkdir()
        self.mktemp_log = self.tmp / "mktemp.log"
        write_mktemp_shim(self.bin, made, self.mktemp_log)
        for name in self.INPUTS:
            path = self.checkout / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{name}\n")

    def build_then_check(self, during=""):
        for name in self.INPUTS:
            os.utime(self.checkout / name, (1546300800, 1546300800))
        # Date the marker in 2020, so any later write is strictly newer on any clock.
        program = "\n".join(
            [
                "set -euo pipefail",
                "XCF=bindings/CompanionCore.xcframework",
                "STAMP=bindings/CompanionCore.features",
                "SHAPE=release",
                CORE_MARKER,
                'touch -t 202001010000 "$BUILD_START"',
                during,
                'rm -rf "$XCF"',
                'mkdir -p "$XCF"',
                'cp THIRD_PARTY_NOTICES.md "$XCF/THIRD_PARTY_NOTICES.md"',
                CORE_DATE,
                'printf \'%s\\n\' "$SHAPE" > "$STAMP"',
                f"if {CORE_CURRENT}; then echo current; else echo stale; fi",
            ]
        )
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
        }
        result = subprocess.run(
            ["bash", "-c", program],
            cwd=self.checkout,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in self.mktemp_log.read_text().split():
            self.assertFalse(Path(path).exists(), f"temp file left: {path}")
        return result.stdout.strip()

    def test_marker_is_made_before_cargo_and_dates_the_finished_xcframework(self):
        for marker in (CORE_MARKER_START, CORE_DATE):
            self.assertEqual(CORE_SCRIPT.count(marker), 1, marker)
        order = [
            "--if-stale) IF_STALE=1",
            CORE_MARKER_START,
            "  cargo build --locked",
            'cp THIRD_PARTY_NOTICES.md "$XCF/THIRD_PARTY_NOTICES.md"',
            CORE_DATE,
            'printf \'%s\\n\' "$SHAPE" > "$STAMP"',
        ]
        positions = [CORE_SCRIPT.index(marker) for marker in order]
        self.assertEqual(positions, sorted(positions))

    def test_input_saved_during_the_core_build_reads_as_stale(self):
        self.assertEqual(self.build_then_check(), "current")
        for name in ("crates/core/src/lib.rs", "crates/ffi/include/companion_ffi.h"):
            with self.subTest(name):
                self.assertEqual(
                    self.build_then_check(f"echo '// saved' >> {name}"), "stale"
                )


if __name__ == "__main__":
    unittest.main()
