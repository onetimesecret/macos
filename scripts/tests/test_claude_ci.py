import base64
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location("claude_ci", Path(__file__).resolve().parents[1] / "ci/claude.py")
ci = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ci
SPEC.loader.exec_module(ci)
HEAD = "a" * 40
NEXT = "b" * 40
BOT = 99
ENV = {"CI_PROJECT_ID": "17", "CI_PROJECT_PATH": ci.PROJECT_PATH, "CI_DEFAULT_BRANCH": "main", "CI_COMMIT_BRANCH": "main",
       "CI_PIPELINE_SOURCE": "trigger", "CI_PIPELINE_ID": "23", "GITLAB_USER_ID": "8"}


def archive(files=None):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w:gz") as output:
        for name, data in (files or {"repo/old.txt": b"before\n"}).items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            output.addfile(item, io.BytesIO(data))
    return result.getvalue()


def event(kind="note", **attrs):
    return {"object_kind": kind, "project": {"id": 17}, "user": {"id": 8, "username": "human"},
            "object_attributes": attrs, "merge_request": {"iid": 4}, "issue": {"iid": 5}}


class FakeAPI:
    project = 17

    def __init__(self):
        self.calls = []
        self.notes = []
        self.deny_fork_archive = False
        self.users = {8: {"id": 8, "state": "active", "bot": False}}
        self.roles = {8: 30}
        self.merge_request = {"iid": 4, "project_id": 17, "target_project_id": 17,
                              "source_project_id": 17, "source_branch": "topic", "target_branch": "main",
                              "sha": HEAD, "state": "opened", "title": "A change", "description": "Context"}
        self.issue = {"iid": 5, "project_id": 17, "state": "opened", "title": "A defect", "description": "Details"}
        self.heads = {"main": HEAD, "topic": HEAD}
        self.protected = {"main": True, "topic": False}

    def pages(self, path):
        self.calls.append(("GET", path, None))
        return list(self.notes)

    def request(self, method, path, data=None, **kwargs):
        self.calls.append((method, path, data))
        if path == "/user":
            return {"id": BOT, "username": "project_17_bot", "bot": True}
        if path == "/projects/17":
            return {"id": 17, "path_with_namespace": ci.PROJECT_PATH, "default_branch": "main"}
        if path.startswith("/users/"):
            return self.users[int(path.rsplit("/", 1)[1])]
        if "/members/all/" in path:
            return {"access_level": self.roles.get(int(path.rsplit("/", 1)[1]), 0)}
        if method == "GET" and path == "/projects/17/merge_requests/4":
            return dict(self.merge_request)
        if method == "GET" and path == "/projects/17/issues/5":
            return dict(self.issue)
        if method == "GET" and "/repository/branches/" in path:
            name = ci.urllib.parse.unquote(path.rsplit("/", 1)[1])
            if name not in self.heads:
                raise ci.ApiError(404)
            return {"name": name, "commit": {"id": self.heads[name]}, "protected": self.protected.get(name, False)}
        if method == "GET" and "/repository/archive.tar.gz?" in path:
            if self.deny_fork_archive and path.startswith("/projects/18/"):
                raise ci.ApiError(403)
            return archive()
        if method == "GET" and path.endswith("/raw_diffs"):
            return b"diff --git a/old.txt b/old.txt\n-old\n+new\n"
        if method == "GET" and "/repository/files/" in path:
            return {"last_commit_id": HEAD}
        if method == "POST" and path == "/projects/17/repository/commits":
            self.heads[data["branch"]] = NEXT
            if data["branch"] == "topic":
                self.merge_request["sha"] = NEXT
            return {"id": NEXT, "web_url": "https://gitlab.example/project/-/commit/" + NEXT}
        if method == "POST" and path == "/projects/17/merge_requests":
            return {"iid": 6, "web_url": "https://gitlab.example/project/-/merge_requests/6"}
        if method in {"PUT", "POST"} and "/notes" in path:
            self.notes.append({"id": len(self.notes) + 1, "body": data["body"], "author": {"id": BOT}})
            return self.notes[-1]
        raise AssertionError((method, path, data))


class RoutingTests(unittest.TestCase):
    def test_created_note_routes_both_targets(self):
        for kind, expected, iid in [("Issue", "issues", 5), ("MergeRequest", "merge_requests", 4)]:
            flow = ci.route(ENV, event(action="create", note="@claude fix this", id=50, noteable_type=kind), BOT)
            self.assertEqual((flow.mode, flow.kind, flow.iid, flow.actor), ("assist", expected, iid, 8))

    def test_edited_unmentioned_bot_and_self_notes_are_ignored(self):
        cases = [event(action="update", note="@claude", id=50, noteable_type="Issue"),
                 event(action="create", note="ordinary note", id=50, noteable_type="Issue")]
        for actor in [{"id": BOT}, {"id": 9, "bot": True}, {"id": 9, "username": "agent[bot]"}]:
            payload = event(action="create", note="@claude", id=50, noteable_type="Issue")
            payload["user"] = actor
            cases.append(payload)
        self.assertTrue(all(ci.route(ENV, payload, BOT) is None for payload in cases))

    def test_wrong_project_and_untrusted_branch_are_rejected(self):
        payload = event(action="create", note="@claude", id=50, noteable_type="Issue")
        payload["project"]["id"] = 18
        with self.assertRaises(ci.FlowError):
            ci.route(ENV, payload, BOT)
        with self.assertRaises(ci.FlowError):
            ci.route(dict(ENV, CI_COMMIT_BRANCH="topic"), event(), BOT)

    def test_mr_review_actions(self):
        for action in ["open", "reopen"]:
            self.assertEqual(ci.route(ENV, event("merge_request", action=action, iid=4), BOT).mode, "review")
        self.assertIsNotNone(ci.route(ENV, event("merge_request", action="update", iid=4, oldrev=HEAD), BOT))
        ready = event("merge_request", action="update", iid=4)
        ready["changes"] = {"draft": {"previous": True, "current": False}}
        self.assertIsNotNone(ci.route(ENV, ready, BOT))
        for attrs in [{"action": "update"}, {"action": "close"}, {"action": "open", "draft": True}]:
            self.assertIsNone(ci.route(ENV, event("merge_request", iid=4, **attrs), BOT))

    def test_issue_open_and_assignment_only(self):
        opened = event("issue", action="open", iid=5, id=100, title="@claude fix", description="", updated_at="now")
        self.assertEqual(ci.route(ENV, opened, BOT).kind, "issues")
        opened["object_attributes"]["action"] = "update"
        self.assertIsNone(ci.route(ENV, opened, BOT))
        opened["changes"] = {"assignees": {"previous": [], "current": [8]}}
        self.assertIsNotNone(ci.route(ENV, opened, BOT))

    def test_manual_modes_and_input_limits(self):
        manual = dict(ENV, CI_PIPELINE_SOURCE="api", CI_MODE="claude-review", CLAUDE_MR_IID="4")
        self.assertEqual(ci.route(manual, {}, BOT).mode, "review")
        manual.update(CI_MODE="claude", AI_FLOW_INPUT="fix this")
        self.assertEqual(ci.route(manual, {}, BOT).request, "fix this")
        self.assertIsNone(ci.route(dict(manual, CI_MODE="checks"), {}, BOT))
        with self.assertRaises(ci.FlowError):
            ci.route(dict(manual, AI_FLOW_INPUT="x" * (ci.MAX_INPUT + 1)), {}, BOT)


class ModelBoundaryTests(unittest.TestCase):
    def test_argv_restricts_tools_customization_and_filesystem(self):
        for mode, expected in [("review", "Read,Glob,Grep"), ("assist", "Read,Glob,Grep,Edit,Write")]:
            argv = ci.model_argv({}, mode)
            for flag in ["--restricted", "--bare", "--disable-slash-commands", "--no-session-persistence", "--strict-mcp-config"]:
                self.assertIn(flag, argv)
            self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
            self.assertEqual(json.loads(argv[argv.index("--settings") + 1]), {"disableAllHooks": True})
            self.assertEqual(json.loads(argv[argv.index("--mcp-config") + 1]), {"mcpServers": {}})
            self.assertEqual(argv[argv.index("--tools") + 1], expected)
            self.assertEqual(argv[argv.index("--allowedTools") + 1], expected)
            self.assertEqual(argv[argv.index("--permission-mode") + 1], "dontAsk")
            self.assertNotIn("--dangerously-skip-permissions", argv)

    def test_environment_and_checkout_credentials_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / ".git").mkdir()
            config = root / ".git/config"
            config.write_text('[core]\nrepositoryformatversion = 0\n[remote "origin"]\nurl = https://token:secret@gitlab.example/project.git\n[http]\nextraheader = Authorization: secret\n')
            fixture_path = "/builds/onetimesecret/macos/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
            env = dict(ENV, CI_PROJECT_DIR=directory, PATH=fixture_path, ANTHROPIC_API_KEY="anthropic-fixture", GITLAB_ACCESS_TOKEN="gitlab-secret", CI_JOB_TOKEN="job-secret", CI_REPOSITORY_URL="https://token:secret@gitlab.example/project.git", GIT_CONFIG_PARAMETERS="unsafe")
            child = ci.model_environment(env, root / "config")
            self.assertEqual(child["ANTHROPIC_API_KEY"], "anthropic-fixture")
            self.assertEqual(child["PATH"], fixture_path)
            self.assertFalse(any(k.startswith(("CI_", "GITLAB", "GIT_")) for k in child))
            self.assertNotIn("HOME", child)
            for key in ["GITLAB_ACCESS_TOKEN", "CI_JOB_TOKEN", "CI_REPOSITORY_URL"]:
                self.assertNotIn(env[key], json.dumps(child))
            ci.sanitize_checkout(env)
            self.assertNotIn("secret", config.read_text())
            self.assertNotIn("remote", config.read_text())

    def test_model_requires_success_and_bounded_result(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(ENV, CI_PROJECT_DIR=directory, PATH=os.environ["PATH"], CLAUDE_CODE_OAUTH_TOKEN="fixture")
            for body, code, good in [({"subtype": "success", "is_error": False, "result": "done"}, 0, True),
                                     ({"subtype": "error", "result": "no"}, 0, False),
                                     ({"subtype": "success", "result": "x" * (ci.MAX_OUTPUT + 1)}, 0, False),
                                     ({"subtype": "success", "result": "no"}, 1, False)]:
                def fake_run(argv, **kwargs):
                    kwargs["stdout"].write(json.dumps(body).encode())
                    self.assertNotIn("CI_JOB_TOKEN", kwargs["env"])
                    return types.SimpleNamespace(returncode=code)
                with mock.patch.object(ci.subprocess, "run", side_effect=fake_run):
                    if good:
                        self.assertEqual(ci.run_model(env, "review", "request", Path(directory)), "done")
                    else:
                        with self.assertRaises(ci.FlowError):
                            ci.run_model(env, "review", "request", Path(directory))

    def test_archive_rejects_paths_symlinks_and_duplicate_files(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ["repo/../escape", "/absolute", "repo/.git/config"]:
                with self.assertRaises(ci.FlowError):
                    ci.extract_archive(archive({name: b"bad"}), Path(directory))
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w:gz") as output:
                link = tarfile.TarInfo("repo/link"); link.type = tarfile.SYMTYPE; link.linkname = "/etc/passwd"; output.addfile(link)
            with self.assertRaises(ci.FlowError):
                ci.extract_archive(data.getvalue(), Path(directory))
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w:gz") as output:
                for _ in range(2):
                    item = tarfile.TarInfo("repo/same"); item.size = 1; output.addfile(item, io.BytesIO(b"x"))
            with self.assertRaises(ci.FlowError):
                ci.extract_archive(data.getvalue(), Path(directory))

    def test_api_refuses_another_host_and_redirects(self):
        env = dict(ENV, CI_PROJECT_ID=str(ci.PROJECT_ID), CI_API_V4_URL="https://evil.example/api/v4", CI_SERVER_URL="https://gitlab.com", GITLAB_ACCESS_TOKEN="fixture")
        with self.assertRaises(ci.FlowError):
            ci.GitLab(env)
        with self.assertRaises(ci.FlowError):
            ci.GitLab(dict(env, CI_SERVER_URL="https://evil.example"))
        env["CI_API_V4_URL"] = "https://gitlab.com/api/v4"
        for overrides in [{"CI_PROJECT_ID": "18"}, {"CI_PROJECT_PATH": "other/project"}]:
            with self.assertRaises(ci.FlowError):
                ci.GitLab(dict(env, **overrides))
        api = ci.GitLab(env)
        with self.assertRaises(ci.FlowError):
            api.request("GET", "https://evil.example")
        self.assertIsNone(ci.NoRedirect().redirect_request(None, None, None, None, None, None))


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.model_calls = []

    def model(self, env, mode, prompt, root):
        self.model_calls.append((mode, prompt, root))
        return "Result"

    def review(self):
        return ci.Flow("review", "merge_requests", 4, None, "", "review")

    def assist(self, kind="merge_requests"):
        return ci.Flow("assist", kind, 4 if kind == "merge_requests" else 5, 8, "fix", "note-10")

    def writes(self, endpoint):
        return [call for call in self.api.calls if call[0] == "POST" and endpoint in call[1]]

    def test_low_role_and_bot_actors_cannot_implement(self):
        for user, role in [({"id": 8, "state": "active", "bot": False}, 20), ({"id": 8, "state": "active", "bot": True}, 40)]:
            self.api.users[8] = user; self.api.roles[8] = role
            with self.assertRaises(ci.FlowError):
                ci.Adapter(self.api, ENV, self.model).run(self.assist())
            self.assertFalse(self.model_calls)
            self.assertFalse(self.writes("/notes"))

    def test_review_idempotency_and_sticky_update(self):
        self.api.notes = [{"id": 12, "author": {"id": BOT}, "body": ci.REVIEW_MARKER + f"\n<!-- head:{HEAD} -->"}]
        adapter = ci.Adapter(self.api, ENV, self.model)
        self.assertIn("Already reviewed", adapter.run(self.review()))
        self.assertFalse(self.model_calls)
        self.api.notes[0]["body"] = ci.REVIEW_MARKER + "\nold review"
        self.assertEqual(adapter.run(self.review()), "Review posted")
        self.assertTrue(any(call[0] == "PUT" and call[1].endswith("/notes/12") for call in self.api.calls))

    def test_forged_review_marker_and_closed_mr(self):
        self.api.notes = [{"id": 12, "author": {"id": 8}, "body": ci.REVIEW_MARKER + f"\n<!-- head:{HEAD} -->"}]
        self.assertEqual(ci.Adapter(self.api, ENV, self.model).run(self.review()), "Review posted")
        self.assertEqual(len(self.model_calls), 1)
        self.api.merge_request["state"] = "closed"
        self.assertIn("closed", ci.Adapter(self.api, ENV, self.model).run(self.review()))
        self.assertEqual(len(self.model_calls), 1)

    def test_review_reads_fork_exact_sha_and_cannot_write_fork(self):
        self.api.merge_request["source_project_id"] = 18
        self.assertEqual(ci.Adapter(self.api, ENV, self.model).run(self.review()), "Review posted")
        self.assertTrue(any(call[1] == f"/projects/18/repository/archive.tar.gz?sha={HEAD}" for call in self.api.calls))
        self.assertFalse(any(call[0] != "GET" and call[1].startswith("/projects/18/") for call in self.api.calls))
        self.model_calls.clear()
        self.assertEqual(ci.Adapter(self.api, ENV, self.model).run(self.assist()), "Fork implementation rejected")
        self.assertFalse(self.model_calls)
        self.assertFalse(self.writes("/repository/commits"))

    def test_changed_head_during_review_posts_nothing(self):
        def model(*args):
            self.api.merge_request["sha"] = NEXT
            return "outdated"
        with self.assertRaises(ci.FlowError):
            ci.Adapter(self.api, ENV, model).run(self.review())
        self.assertFalse(self.writes("/notes"))

    def test_fork_review_can_use_target_diff_when_source_is_inaccessible(self):
        self.api.merge_request["source_project_id"] = 18
        self.api.deny_fork_archive = True
        self.assertEqual(ci.Adapter(self.api, ENV, self.model).run(self.review()), "Review posted")
        self.assertIn("fork repository context is unavailable", self.model_calls[0][1])

    def test_trusted_instructions_are_included_and_spoofed_default_branch_fails(self):
        ci.Adapter(self.api, ENV, self.model).run(self.review())
        self.assertIn("Trusted default-branch AGENTS.md", self.model_calls[0][1])
        self.assertIn("PageModel.Seams(stateDirectory:client:)", self.model_calls[0][1])
        with self.assertRaises(ci.FlowError):
            ci.Adapter(self.api, dict(ENV, CI_COMMIT_BRANCH="topic", CI_DEFAULT_BRANCH="topic"), self.model)

    def test_mr_implementation_uses_optimistic_file_revision(self):
        def model(env, mode, prompt, root):
            (root / "old.txt").write_text("after\n")
            return "Changed old.txt"
        self.assertEqual(ci.Adapter(self.api, ENV, model).run(self.assist()), "Changes published for review")
        commit = self.writes("/repository/commits")[0][2]
        self.assertEqual(commit["branch"], "topic")
        self.assertFalse(commit["force"])
        self.assertNotIn("start_sha", commit)
        self.assertEqual(commit["actions"][0]["last_commit_id"], HEAD)
        self.assertEqual(base64.b64decode(commit["actions"][0]["content"]), b"after\n")
        self.assertTrue(any(f"/repository/files/old.txt?ref={HEAD}" in call[1] for call in self.api.calls))

    def test_issue_implementation_creates_branch_and_draft_mr_from_sha(self):
        def model(env, mode, prompt, root):
            (root / "new.txt").write_text("new\n")
            return "Added new.txt"
        self.assertEqual(ci.Adapter(self.api, ENV, model).run(self.assist("issues")), "Changes published for review")
        commit = self.writes("/repository/commits")[0][2]
        self.assertEqual(commit["branch"], "wip/claude-issue-5-23")
        self.assertEqual(commit["start_sha"], HEAD)
        request = self.writes("/merge_requests")[0][2]
        self.assertEqual(request["target_branch"], "main")
        self.assertEqual(request["source_branch"], commit["branch"])
        self.assertTrue(request["title"].startswith("Draft:"))

    def test_changed_head_and_protected_branch_prevent_commits(self):
        def model(env, mode, prompt, root):
            (root / "old.txt").write_text("after\n")
            self.api.heads["topic"] = NEXT
            return "Changed"
        with self.assertRaises(ci.FlowError):
            ci.Adapter(self.api, ENV, model).run(self.assist())
        self.assertFalse(self.writes("/repository/commits"))
        self.api.protected["topic"] = True
        with self.assertRaises(ci.FlowError):
            ci.Adapter(self.api, ENV, self.model).run(self.assist())
        self.assertFalse(self.model_calls)

    def test_noop_and_duplicate_mentions_do_not_commit(self):
        flow = self.assist()
        adapter = ci.Adapter(self.api, ENV, self.model)
        self.assertEqual(adapter.run(flow), "Response posted without a commit")
        self.assertIn("Already handled", adapter.run(flow))
        self.assertEqual(len(self.model_calls), 1)
        self.assertFalse(self.writes("/repository/commits"))

    def test_wrong_api_target_is_rejected(self):
        self.api.merge_request["target_project_id"] = 18
        with self.assertRaises(ci.FlowError):
            ci.Adapter(self.api, ENV, self.model).run(self.review())
        self.assertFalse(self.model_calls)


if __name__ == "__main__":
    unittest.main()
