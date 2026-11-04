import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location("github_macos", Path(__file__).resolve().parents[1] / "ci/github_macos.py")
ci = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ci
SPEC.loader.exec_module(ci)
HEAD = "a" * 40
BINDING = ci.Binding(23, 45, HEAD)
GH_ENV = {"GITHUB_REPOSITORY": ci.GITHUB_REPOSITORY, "GITHUB_REF": "refs/heads/main",
          "GITLAB_PIPELINE_ID": "23", "GITLAB_BRIDGE_JOB_ID": "45", "GITLAB_SHA": HEAD,
          "GITHUB_RUN_ID": "67", "PLATFORM_RESULT": "success", "SHELL_RESULT": "success"}
CI_ENV = {"CI_PROJECT_ID": str(ci.PROJECT_ID), "CI_PROJECT_PATH": ci.PROJECT_PATH,
          "CI_PIPELINE_ID": "23", "CI_JOB_ID": "45", "CI_COMMIT_SHA": HEAD}


def worker(**changes):
    value = {"id": 67, "display_title": BINDING.run_name, "event": "workflow_dispatch", "head_branch": "main",
             "path": ci.WORKFLOW_PATH, "repository": {"full_name": ci.GITHUB_REPOSITORY},
             "head_repository": {"full_name": ci.GITHUB_REPOSITORY}, "status": "completed",
             "conclusion": "success", "run_attempt": 1}
    value.update(changes)
    return value


class FakeGitLab:
    def __init__(self):
        self.project = {"id": ci.PROJECT_ID, "path_with_namespace": ci.PROJECT_PATH}
        self.pipeline = {"id": 23, "project_id": ci.PROJECT_ID, "sha": HEAD, "status": "running", "ref": "refs/merge-requests/345/head"}
        self.job = {"id": 45, "name": "macos-github", "status": "running", "allow_failure": False,
                    "pipeline": copy.deepcopy(self.pipeline), "commit": {"id": HEAD}}
        self.calls = []

    def request(self, method, path, data=None):
        self.calls.append((method, path, data))
        if path == ci.GITLAB_PROJECT:
            return copy.deepcopy(self.project)
        if path == ci.GITLAB_PROJECT + "/pipelines?status=running&per_page=20":
            return [copy.deepcopy(self.pipeline)]
        if path == ci.GITLAB_PROJECT + "/pipelines/23":
            return copy.deepcopy(self.pipeline)
        if path == ci.GITLAB_PROJECT + "/pipelines/23/jobs?include_retried=false&per_page=100":
            return [copy.deepcopy(self.job)]
        if method == "POST" and path == ci.GITLAB_PROJECT + "/statuses/" + HEAD:
            return {"id": 80, **data}
        raise AssertionError((method, path, data))


class FakeGitHub:
    def __init__(self, runs=None):
        self.runs = [worker()] if runs is None else runs
        self.detail = None
        self.calls = []

    def request(self, method, path, data=None):
        self.calls.append((method, path, data))
        if "/actions/workflows/" in path and "/runs?" in path:
            return {"workflow_runs": copy.deepcopy(self.runs)}
        if method == "GET" and "/actions/runs/" in path:
            return copy.deepcopy(self.detail or next(run for run in self.runs if path.endswith("/" + str(run["id"]))))
        if method == "POST" and path.endswith("/dispatches"):
            return {"workflow_run_id": 68}
        raise AssertionError((method, path, data))


class Clock:
    def __init__(self):
        self.value = 0
        self.sleeps = []

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.value += seconds


class Response(io.BytesIO):
    pass


class Opener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return Response(json.dumps(response).encode())


def http_error(status, headers=None):
    return urllib.error.HTTPError("https://example.invalid", status, "fixture", headers or {}, None)


class BindingTests(unittest.TestCase):
    def test_prepare_validates_exact_binding_and_outputs_only_sha(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "output"
            result = ci.prepare({**GH_ENV, "GITHUB_OUTPUT": str(output)}, FakeGitLab())
            self.assertEqual(result, BINDING)
            self.assertEqual(output.read_text(), "sha=" + HEAD + "\n")

    def test_wrong_github_project_ref_and_sha_are_rejected(self):
        for changes in [{"GITHUB_REPOSITORY": "elsewhere/macos"}, {"GITHUB_REF": "refs/heads/topic"},
                        {"GITLAB_SHA": "a" * 39}, {"GITLAB_SHA": HEAD.upper()},
                        {"GITLAB_PIPELINE_ID": "23/other"}, {"GITLAB_BRIDGE_JOB_ID": "0"}]:
            with self.subTest(changes=changes), self.assertRaises(ci.InvalidBinding):
                ci.github_binding({**GH_ENV, **changes})

    def test_wrong_gitlab_project_and_api_origins_are_rejected(self):
        for changes in [{"CI_PROJECT_ID": "17"}, {"CI_PROJECT_PATH": "other/macos"},
                        {"CI_API_V4_URL": "https://attacker.invalid/api/v4", "CI_SERVER_URL": "https://attacker.invalid"}]:
            with self.subTest(changes=changes), self.assertRaises(ci.InvalidBinding):
                ci.waiter_binding({**CI_ENV, **changes})

    def test_superseded_canceled_failed_and_other_project_jobs_are_rejected(self):
        for target, changes in [("project", {"id": 17}), ("project", {"path_with_namespace": "other/macos"}),
                                ("pipeline", {"project_id": 17}), ("pipeline", {"sha": "b" * 40}),
                                ("pipeline", {"status": "canceled"}), ("job", {"id": 46}),
                                ("job", {"status": "canceled"}), ("job", {"status": "failed"}),
                                ("job", {"allow_failure": True}), ("job", {"commit": {"id": "b" * 40}}),
                                ("job", {"pipeline": {"id": 24, "project_id": ci.PROJECT_ID, "sha": HEAD}})]:
            api = FakeGitLab()
            getattr(api, target).update(changes)
            with self.subTest(target=target, changes=changes), self.assertRaises(ci.InvalidBinding):
                ci.validate_binding(api, BINDING)

    def test_missing_job_fails_prepare_and_report_without_callback(self):
        for function in [ci.prepare, ci.report]:
            api = FakeGitLab()
            api.job["name"] = "logic"
            with self.assertRaises(ci.InvalidBinding):
                function(GH_ENV, api)
            self.assertFalse(any(method == "POST" for method, _, _ in api.calls))

    def test_other_failed_job_does_not_hide_current_mac_results(self):
        api = FakeGitLab()
        api.pipeline["status"] = "failed"
        self.assertEqual(ci.validate_binding(api, BINDING)["id"], 23)


class ControllerTests(unittest.TestCase):
    def test_dispatches_main_with_exact_inputs(self):
        github = FakeGitHub([])
        result = ci.controller(GH_ENV, FakeGitLab(), github)
        self.assertEqual(result, {"pipelines": 1, "dispatched": 1})
        self.assertEqual(github.calls[-1], ("POST", ci.GITHUB_REPO + "/actions/workflows/" + ci.WORKFLOW + "/dispatches",
                         {"ref": "main", "inputs": {"pipeline_id": "23", "job_id": "45", "sha": HEAD}}))

    def test_deduplicates_completed_failed_or_running_exact_worker(self):
        for changes in [{}, {"conclusion": "failure"}, {"status": "in_progress", "conclusion": None}]:
            github = FakeGitHub([worker(**changes)])
            self.assertEqual(ci.controller(GH_ENV, FakeGitLab(), github)["dispatched"], 0)
            self.assertFalse(any(method == "POST" for method, _, _ in github.calls))

    def test_unrelated_workflow_event_branch_repository_or_attempt_does_not_dedupe(self):
        for changes in [{"display_title": BINDING.run_name.replace("/45/", "/44/")}, {"head_branch": "topic"},
                        {"event": "pull_request"}, {"path": ".github/workflows/other.yml"},
                        {"head_repository": {"full_name": "attacker/macos"}}]:
            with self.subTest(changes=changes):
                self.assertEqual(ci.controller(GH_ENV, FakeGitLab(), FakeGitHub([worker(**changes)]))["dispatched"], 1)


class ReportTests(unittest.TestCase):
    def test_statuses_target_exact_sha_pipeline_ref_and_stable_contexts(self):
        api = FakeGitLab()
        self.assertEqual(ci.report(GH_ENV, api), {"reported": 2})
        callbacks = [call for call in api.calls if call[0] == "POST"]
        self.assertEqual([call[2]["name"] for call in callbacks], ["GitHub/platform", "GitHub/shell"])
        for method, path, data in callbacks:
            self.assertEqual(path, ci.GITLAB_PROJECT + "/statuses/" + HEAD)
            self.assertEqual((data["pipeline_id"], data["ref"], data["state"]), (23, api.pipeline["ref"], "success"))
            self.assertIn("45", data["description"])
            self.assertEqual(data["target_url"], "https://github.com/onetimesecret/macos/actions/runs/67")

    def test_retry_uses_stable_context_but_prior_job_cannot_report(self):
        api = FakeGitLab()
        api.job["id"] = 46
        with self.assertRaises(ci.InvalidBinding):
            ci.report(GH_ENV, api)
        self.assertFalse(any(method == "POST" for method, _, _ in api.calls))
        ci.report({**GH_ENV, "GITLAB_BRIDGE_JOB_ID": "46"}, api)
        callbacks = [call[2] for call in api.calls if call[0] == "POST"]
        self.assertEqual([data["name"] for data in callbacks], ["GitHub/platform", "GitHub/shell"])
        self.assertTrue(all("46" in data["description"] for data in callbacks))

    def test_binding_is_rechecked_before_each_callback(self):
        api = FakeGitLab()
        original = api.request
        def request(method, path, data=None):
            response = original(method, path, data)
            if method == "POST":
                api.job["id"] = 46
            return response
        api.request = request
        with self.assertRaises(ci.InvalidBinding):
            ci.report(GH_ENV, api)
        self.assertEqual(len([call for call in api.calls if call[0] == "POST"]), 1)

    def test_non_success_results_post_failure_and_fail_reporter(self):
        for result, expected in [("failure", "failed"), ("cancelled", "canceled"), ("skipped", "failed"),
                                 ("timed_out", "failed"), (None, "failed")]:
            api = FakeGitLab()
            with self.subTest(result=result), self.assertRaises(ci.BridgeError):
                ci.report({**GH_ENV, "PLATFORM_RESULT": result}, api)
            callbacks = [call[2] for call in api.calls if call[0] == "POST"]
            self.assertEqual(len(callbacks), 2)
            self.assertEqual(callbacks[0]["state"], expected)


class WaitTests(unittest.TestCase):
    def test_requires_full_completed_workflow_success(self):
        self.assertEqual(ci.wait(CI_ENV, FakeGitHub()), {"run_id": 67, "conclusion": "success"})
        for conclusion in ["failure", "cancelled", "timed_out", "skipped", "neutral", None]:
            with self.subTest(conclusion=conclusion), self.assertRaises(ci.BridgeError):
                ci.wait(CI_ENV, FakeGitHub([worker(conclusion=conclusion)]))

    def test_nonterminal_and_missing_worker_timeout_at_deadline(self):
        for runs in [[], [worker(status="in_progress", conclusion=None)], [worker(display_title="unrelated")]]:
            clock = Clock()
            with self.assertRaisesRegex(ci.BridgeError, "Timed out"):
                ci.wait(CI_ENV, FakeGitHub(runs), clock=clock.now, sleep=clock.sleep, deadline=200)
            self.assertEqual(clock.sleeps, [90, 90, 20])

    def test_polling_uses_one_request_per_interval_with_full_identity(self):
        github = FakeGitHub([worker(head_branch="untrusted")])
        clock = Clock()
        with self.assertRaises(ci.BridgeError):
            ci.wait(CI_ENV, github, clock=clock.now, sleep=clock.sleep, deadline=180)
        self.assertEqual(len(github.calls), 2)
        self.assertTrue(all("/actions/workflows/" in path for _, path, _ in github.calls))

    def test_newer_matching_failure_prevents_stale_green(self):
        github = FakeGitHub([worker(), worker(id=68, conclusion="failure")])
        with self.assertRaises(ci.BridgeError):
            ci.wait(CI_ENV, github)
        self.assertEqual(len(github.calls), 1)


class APITests(unittest.TestCase):
    def test_auth_headers_stay_on_their_fixed_origins(self):
        requests = []
        for service, token, path in [("github", "github-fixture-token", ci.GITHUB_REPO + "/actions/runs"),
                                     ("gitlab", "gitlab-fixture-token", ci.GITLAB_PROJECT),
                                     ("github", None, ci.GITHUB_REPO + "/actions/runs"),
                                     ("gitlab", None, ci.GITLAB_PROJECT)]:
            opener = Opener({})
            ci.API(service, token, opener=opener).request("GET", path)
            requests.append(opener.requests[0])
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer github-fixture-token")
        self.assertIsNone(requests[0].get_header("Private-token"))
        self.assertEqual(requests[1].get_header("Private-token"), "gitlab-fixture-token")
        self.assertIsNone(requests[1].get_header("Authorization"))
        for request in requests[2:]:
            self.assertIsNone(request.get_header("Authorization"))
            self.assertIsNone(request.get_header("Private-token"))
        self.assertTrue(requests[0].full_url.startswith("https://api.github.com/repos/onetimesecret/macos/"))
        self.assertEqual(requests[1].full_url, "https://gitlab.com/api/v4/projects/88480772")

    def test_wrong_paths_and_redirects_are_rejected_without_secret_errors(self):
        for path in ["https://attacker.invalid", "//attacker.invalid", "/projects/884807720", "/projects/17"]:
            opener = Opener({})
            with self.assertRaises(ci.BridgeError):
                ci.API("gitlab", "fixture-token", opener=opener).request("GET", path)
            self.assertEqual(opener.requests, [])
        opener = Opener(http_error(302, {"Location": "https://attacker.invalid"}))
        with self.assertRaisesRegex(ci.BridgeError, "status 302") as error:
            ci.API("gitlab", "fixture-token", opener=opener).request("GET", ci.GITLAB_PROJECT)
        self.assertNotIn("fixture-token", str(error.exception))
        self.assertIsNone(ci.NoRedirect().redirect_request(None, None, None, None, None, None))

    def test_callback_conflict_and_transient_errors_retry(self):
        for status in [409, 429, 500, 502, 503, 504]:
            clock = Clock()
            opener = Opener(http_error(status), {"id": 80})
            api = ci.API("gitlab", "fixture-token", opener=opener, clock=clock.now, sleep=clock.sleep)
            self.assertEqual(api.request("POST", ci.GITLAB_PROJECT + "/statuses/" + HEAD, {"pipeline_id": 23}), {"id": 80})
            self.assertEqual(len(opener.requests), 2)
            self.assertEqual(clock.sleeps, [1])

    def test_rate_limit_honors_retry_after_and_reset_without_exceeding_deadline(self):
        for headers, seconds in [({"Retry-After": "12"}, 12),
                                 ({"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1020"}, 21)]:
            clock = Clock()
            api = ci.API("github", opener=Opener(http_error(403, headers), {}), clock=clock.now,
                         sleep=clock.sleep, wall_clock=lambda: 1000, deadline=100)
            self.assertEqual(api.request("GET", ci.GITHUB_REPO + "/actions/runs"), {})
            self.assertEqual(clock.sleeps, [seconds])
        clock = Clock()
        api = ci.API("github", opener=Opener(http_error(429, {"Retry-After": "101"})), clock=clock.now,
                     sleep=clock.sleep, deadline=100)
        with self.assertRaisesRegex(ci.BridgeError, "deadline"):
            api.request("GET", ci.GITHUB_REPO + "/actions/runs")
        self.assertEqual(clock.sleeps, [])

    def test_failed_callbacks_are_bounded_and_error_messages_exclude_credentials(self):
        clock = Clock()
        opener = Opener(*(http_error(503) for _ in range(6)))
        api = ci.API("gitlab", "private-fixture-token", opener=opener, clock=clock.now, sleep=clock.sleep)
        with self.assertRaisesRegex(ci.BridgeError, "status 503") as error:
            api.request("POST", ci.GITLAB_PROJECT + "/statuses/" + HEAD, {"pipeline_id": 23})
        self.assertEqual(len(opener.requests), 6)
        self.assertNotIn("private-fixture-token", str(error.exception))
        opener = Opener(http_error(403))
        with self.assertRaises(ci.BridgeError):
            ci.API("github", opener=opener).request("GET", ci.GITHUB_REPO + "/actions/runs")
        self.assertEqual(len(opener.requests), 1)

    def test_main_never_sends_reporter_token_to_controller_or_prepare(self):
        created = []
        def factory(service, token=None, **kwargs):
            created.append((service, token))
            return FakeGitLab() if service == "gitlab" else FakeGitHub()
        env = {**GH_ENV, "GH_TOKEN": "dispatch-fixture-token", "GITLAB_STATUS_TOKEN": "report-fixture-token"}
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(ci, "API", side_effect=factory), mock.patch("sys.stdout", new_callable=io.StringIO):
            env["GITHUB_OUTPUT"] = str(Path(folder) / "output")
            self.assertEqual(ci.main(["controller"], env), 0)
            self.assertEqual(created, [("gitlab", None), ("github", "dispatch-fixture-token")])
            created.clear()
            self.assertEqual(ci.main(["prepare"], env), 0)
            self.assertEqual(created, [("gitlab", None)])
            created.clear()
            self.assertEqual(ci.main(["report"], env), 0)
            self.assertEqual(created, [("gitlab", "report-fixture-token")])
            created.clear()
            self.assertEqual(ci.main(["wait"], {**env, **CI_ENV}), 0)
            self.assertEqual(created, [("github", None)])


if __name__ == "__main__":
    unittest.main()
