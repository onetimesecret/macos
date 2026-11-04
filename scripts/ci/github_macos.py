#!/usr/bin/env python3
import argparse
import email.utils
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path


PROJECT_ID = 88480772
PROJECT_PATH = "onetimesecret/macos"
GITHUB_REPOSITORY = "onetimesecret/macos"
WORKFLOW = "gitlab-macos.yml"
WORKFLOW_PATH = ".github/workflows/" + WORKFLOW
GITLAB_PROJECT = f"/projects/{PROJECT_ID}"
GITHUB_REPO = "/repos/" + GITHUB_REPOSITORY
MAX_RESPONSE = 8_388_608
WAIT_SECONDS = 3_000
POLL_SECONDS = 90
SHA = re.compile(r"^[0-9a-f]{40}$")


class BridgeError(Exception):
    pass


class InvalidBinding(BridgeError):
    pass


def positive_id(value):
    if isinstance(value, bool) or not re.fullmatch(r"[1-9][0-9]*", str(value)):
        raise InvalidBinding("Expected a positive numeric identifier")
    return int(value)


def commit_sha(value):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise InvalidBinding("Expected a full lowercase commit SHA")
    return value


@dataclass(frozen=True)
class Binding:
    pipeline_id: int
    job_id: int
    sha: str

    @property
    def run_name(self):
        return f"GitLab macOS {self.pipeline_id}/{self.job_id}/{self.sha}"


def trusted_github(env):
    if env.get("GITHUB_REPOSITORY") != GITHUB_REPOSITORY or env.get("GITHUB_REF") != "refs/heads/main":
        raise InvalidBinding("The bridge requires the trusted GitHub main branch")


def github_binding(env):
    trusted_github(env)
    return Binding(positive_id(env.get("GITLAB_PIPELINE_ID")),
                   positive_id(env.get("GITLAB_BRIDGE_JOB_ID")), commit_sha(env.get("GITLAB_SHA")))


def waiter_binding(env):
    if positive_id(env.get("CI_PROJECT_ID")) != PROJECT_ID or env.get("CI_PROJECT_PATH") != PROJECT_PATH:
        raise InvalidBinding("Unexpected GitLab project identity")
    for key, expected in [("CI_API_V4_URL", "https://gitlab.com/api/v4"), ("CI_SERVER_URL", "https://gitlab.com")]:
        if key in env and env[key].rstrip("/") != expected:
            raise InvalidBinding("Unexpected GitLab API destination")
    return Binding(positive_id(env.get("CI_PIPELINE_ID")), positive_id(env.get("CI_JOB_ID")),
                   commit_sha(env.get("CI_COMMIT_SHA")))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class API:
    def __init__(self, service, token=None, deadline=None, clock=time.monotonic,
                 sleep=time.sleep, wall_clock=time.time, opener=None):
        self.service = service
        self.base = {"github": "https://api.github.com", "gitlab": "https://gitlab.com/api/v4"}[service]
        self.token = token
        self.clock = clock
        self.sleep = sleep
        self.wall_clock = wall_clock
        self.deadline = deadline if deadline is not None else clock() + 300
        self.opener = opener or urllib.request.build_opener(NoRedirect())

    def pause(self, delay):
        remaining = self.deadline - self.clock()
        if remaining <= 0 or delay >= remaining:
            raise BridgeError("Bridge API deadline exceeded")
        self.sleep(max(0, delay))

    def retry_delay(self, headers, attempt):
        retry_after = headers.get("Retry-After")
        if retry_after:
            try:
                return max(0, float(retry_after))
            except ValueError:
                try:
                    return max(0, email.utils.parsedate_to_datetime(retry_after).timestamp() - self.wall_clock())
                except (TypeError, ValueError, OverflowError):
                    pass
        reset = headers.get("X-RateLimit-Reset")
        if reset:
            try:
                return max(0, float(reset) - self.wall_clock() + 1)
            except ValueError:
                pass
        return min(2 ** attempt, 30)

    def request(self, method, path, data=None):
        expected = GITHUB_REPO + "/" if self.service == "github" else GITLAB_PROJECT
        if not isinstance(path, str) or not path.startswith(expected) or path.startswith("//") or "#" in path:
            raise BridgeError("Unexpected bridge API path")
        if self.service == "gitlab" and path != GITLAB_PROJECT and not path.startswith(GITLAB_PROJECT + "/"):
            raise BridgeError("Unexpected GitLab project API path")
        headers = {"Accept": "application/json", "User-Agent": "onetimesecret-macos-ci"}
        if self.service == "github":
            headers.update({"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"})
            if self.token:
                headers["Authorization"] = "Bearer " + self.token
        elif self.token:
            headers["PRIVATE-TOKEN"] = self.token
        body = None if data is None else json.dumps(data).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        for attempt in range(6):
            remaining = self.deadline - self.clock()
            if remaining <= 0:
                raise BridgeError("Bridge API deadline exceeded")
            request = urllib.request.Request(self.base + path, data=body, method=method, headers=headers)
            try:
                with self.opener.open(request, timeout=min(30, remaining)) as response:
                    raw = response.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    raise BridgeError("Bridge API response exceeds its size limit")
                return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                rate_limited = error.code == 403 and (error.headers.get("Retry-After") or error.headers.get("X-RateLimit-Remaining") == "0")
                retry = error.code in {409, 429, 500, 502, 503, 504} or rate_limited
                if not retry or attempt == 5:
                    raise BridgeError(f"{self.service} API request failed with status {error.code}") from None
                self.pause(self.retry_delay(error.headers, attempt))
            except (urllib.error.URLError, TimeoutError, OSError):
                if attempt == 5:
                    raise BridgeError(f"{self.service} API request failed") from None
                self.pause(min(2 ** attempt, 30))
            except (ValueError, UnicodeDecodeError):
                raise BridgeError(f"{self.service} API returned invalid JSON") from None
        raise BridgeError("Bridge API retry limit exceeded")


def bounded_list(value, limit, label):
    if not isinstance(value, list) or len(value) >= limit:
        raise BridgeError(f"Unexpected or truncated {label} response")
    if not all(isinstance(item, dict) for item in value):
        raise BridgeError(f"Invalid {label} response")
    return value


def validate_project(gitlab):
    project = gitlab.request("GET", GITLAB_PROJECT)
    if project.get("id") != PROJECT_ID or project.get("path_with_namespace") != PROJECT_PATH:
        raise InvalidBinding("Unexpected GitLab project identity")


def latest_jobs(gitlab, pipeline_id):
    return bounded_list(gitlab.request("GET", f"{GITLAB_PROJECT}/pipelines/{pipeline_id}/jobs?include_retried=false&per_page=100"),
                        100, "GitLab jobs")


def validate_binding(gitlab, binding):
    validate_project(gitlab)
    pipeline = gitlab.request("GET", f"{GITLAB_PROJECT}/pipelines/{binding.pipeline_id}")
    if (pipeline.get("id") != binding.pipeline_id or pipeline.get("project_id") != PROJECT_ID
            or pipeline.get("sha") != binding.sha or pipeline.get("status") not in {"running", "failed"}
            or not isinstance(pipeline.get("ref"), str) or not pipeline["ref"] or len(pipeline["ref"]) > 255):
        raise InvalidBinding("The GitLab pipeline binding is no longer current")
    candidates = [job for job in latest_jobs(gitlab, binding.pipeline_id) if job.get("name") == "macos-github"]
    if len(candidates) != 1:
        raise InvalidBinding("Expected exactly one current macOS bridge job")
    job = candidates[0]
    job_pipeline = job.get("pipeline") or {}
    if (job.get("id") != binding.job_id or job.get("status") != "running" or job.get("allow_failure") is not False
            or job_pipeline.get("id") != binding.pipeline_id or job_pipeline.get("project_id") != PROJECT_ID
            or job_pipeline.get("sha") != binding.sha or (job.get("commit") or {}).get("id") != binding.sha):
        raise InvalidBinding("The GitLab bridge job binding is no longer current")
    return pipeline


def worker_runs(github):
    response = github.request("GET", f"{GITHUB_REPO}/actions/workflows/{WORKFLOW}/runs?branch=main&event=workflow_dispatch&per_page=100")
    return bounded_list(response.get("workflow_runs"), 101, "GitHub workflow runs")


def matches_run(run, binding):
    return (run.get("display_title") == binding.run_name and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main" and run.get("path") == WORKFLOW_PATH
            and (run.get("repository") or {}).get("full_name") == GITHUB_REPOSITORY
            and (run.get("head_repository") or {}).get("full_name") == GITHUB_REPOSITORY
            and isinstance(run.get("id"), int) and not isinstance(run.get("id"), bool) and run["id"] > 0)


def controller(env, gitlab, github):
    trusted_github(env)
    validate_project(gitlab)
    pipelines = bounded_list(gitlab.request("GET", GITLAB_PROJECT + "/pipelines?status=running&per_page=20"), 21, "GitLab pipelines")
    runs = worker_runs(github)
    dispatched = 0
    for pipeline in pipelines:
        pipeline_id = positive_id(pipeline.get("id"))
        if pipeline.get("project_id") != PROJECT_ID or pipeline.get("status") != "running":
            raise InvalidBinding("Unexpected GitLab pipeline identity")
        sha = commit_sha(pipeline.get("sha"))
        for job in latest_jobs(gitlab, pipeline_id):
            if job.get("name") != "macos-github" or job.get("status") != "running":
                continue
            binding = Binding(pipeline_id, positive_id(job.get("id")), sha)
            validate_binding(gitlab, binding)
            if any(matches_run(run, binding) for run in runs):
                continue
            github.request("POST", f"{GITHUB_REPO}/actions/workflows/{WORKFLOW}/dispatches",
                           {"ref": "main", "inputs": {"pipeline_id": str(pipeline_id), "job_id": str(binding.job_id), "sha": sha}})
            dispatched += 1
    return {"pipelines": len(pipelines), "dispatched": dispatched}


def prepare(env, gitlab):
    binding = github_binding(env)
    validate_binding(gitlab, binding)
    output = env.get("GITHUB_OUTPUT")
    if not output:
        raise BridgeError("GITHUB_OUTPUT is required")
    with Path(output).open("a", encoding="utf-8") as destination:
        destination.write("sha=" + binding.sha + "\n")
    return binding


def report(env, gitlab):
    binding = github_binding(env)
    run_id = positive_id(env.get("GITHUB_RUN_ID"))
    target = f"https://github.com/{GITHUB_REPOSITORY}/actions/runs/{run_id}"
    succeeded = True
    for job in ["platform", "shell"]:
        pipeline = validate_binding(gitlab, binding)
        result = env.get(job.upper() + "_RESULT")
        succeeded = succeeded and result == "success"
        state = "success" if result == "success" else "canceled" if result == "cancelled" else "failed"
        gitlab.request("POST", f"{GITLAB_PROJECT}/statuses/{binding.sha}",
                       {"state": state, "name": f"GitHub/{job}", "pipeline_id": binding.pipeline_id,
                        "ref": pipeline["ref"], "target_url": target,
                        "description": f"Bridge job {binding.job_id}; GitHub {job}: {result if result in {'success', 'failure', 'cancelled', 'skipped'} else 'incomplete'}"})
    if not succeeded:
        raise BridgeError("The macOS jobs did not both succeed")
    return {"reported": 2}


def wait(env, github, clock=time.monotonic, sleep=time.sleep, deadline=None):
    binding = waiter_binding(env)
    deadline = deadline if deadline is not None else clock() + WAIT_SECONDS
    while clock() < deadline:
        runs = [run for run in worker_runs(github) if matches_run(run, binding)]
        if runs:
            current = max(runs, key=lambda item: item["id"])
            if current.get("status") == "completed":
                if current.get("conclusion") == "success":
                    return {"run_id": current["id"], "conclusion": "success"}
                raise BridgeError("GitHub macOS worker did not succeed")
        remaining = deadline - clock()
        if remaining <= 0:
            break
        sleep(min(POLL_SECONDS, remaining))
    raise BridgeError("Timed out waiting for GitHub macOS results")


def main(argv=None, env=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["controller", "prepare", "report", "wait"])
    args = parser.parse_args(argv)
    env = os.environ if env is None else env
    deadline = time.monotonic() + (WAIT_SECONDS if args.mode == "wait" else 300)
    try:
        if args.mode == "controller":
            trusted_github(env)
            if not env.get("GH_TOKEN"):
                raise BridgeError("GH_TOKEN is required by the controller")
            result = controller(env, API("gitlab", deadline=deadline), API("github", env["GH_TOKEN"], deadline=deadline))
        elif args.mode == "prepare":
            result = {"sha": prepare(env, API("gitlab", deadline=deadline)).sha}
        elif args.mode == "report":
            github_binding(env)
            if not env.get("GITLAB_STATUS_TOKEN"):
                raise BridgeError("GITLAB_STATUS_TOKEN is required by the reporter")
            result = report(env, API("gitlab", env["GITLAB_STATUS_TOKEN"], deadline=deadline))
        else:
            result = wait(env, API("github", deadline=deadline), deadline=deadline)
        print(json.dumps(result, sort_keys=True))
        return 0
    except BridgeError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
