#!/usr/bin/env python3
"""Bounded, isolated Foundation transport experiment. No third-party Python packages."""

import argparse
import hashlib
import http.server
import ipaddress
import json
import os
import platform
import plistlib
import queue
import re
import shutil
import socket
import ssl
import subprocess
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

LAB = Path(__file__).resolve().parent
REPO = LAB.parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args, *, timeout=45, env=None):
    result = subprocess.run(
        args, cwd=LAB, env=env, capture_output=True, text=True, timeout=timeout
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {args!r}\n{result.stdout}\n{result.stderr}"
        )
    return result.stdout.strip()


class Recorder:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = []
        self.epoch = time.monotonic()

    def record(self, kind, listener, **fields):
        with self.lock:
            self.events.append(
                dict(
                    kind=kind,
                    listener=listener,
                    seconds=time.monotonic() - self.epoch,
                    **fields,
                )
            )

    def snapshot(self):
        with self.lock:
            return list(self.events)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, host, recorder, label, tls=None):
        self.recorder, self.label, self.tls = recorder, label, tls
        if ":" in host:
            self.address_family = socket.AF_INET6
        super().__init__((host, 0), Handler)

    def get_request(self):
        connection, peer = self.socket.accept()
        connection.settimeout(3)
        self.recorder.record("tcp_accept", self.label)
        if self.tls:
            try:
                connection = self.tls.wrap_socket(connection, server_side=True)
            except ssl.SSLError as error:
                self.recorder.record(
                    "tls_failure", self.label, reason=str(error)
                )
                connection.close()
                raise OSError(str(error)) from error
        return connection, peer

    def handle_error(self, request, client_address):
        self.recorder.record("handler_error", self.label)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.server.recorder.record(
            "http_request", self.server.label, method="GET", path=self.path
        )
        parsed = urlsplit(self.path)
        if parsed.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", parse_qs(parsed.query)["to"][0])
            body = b"lab redirect\n"
        else:
            self.send_response(200)
            body = b"transport-lab-ok\n"
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def start_server(host, recorder, label, servers, tls=None):
    server = Server(host, recorder, label, tls)
    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
    )
    thread.start()
    servers.append((server, thread))
    return server.server_port


def private_ipv4():
    output = command(["/sbin/ifconfig"], timeout=5)
    for address in re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)\b", output):
        ip = ipaddress.ip_address(address)
        if any(
            ip in ipaddress.ip_network(net)
            for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
        ):
            return address
    return None


def prepare_reader(process, destination):
    lines = queue.Queue()

    def read():
        with destination.open("w") as log:
            for line in process.stdout:
                log.write(line)
                log.flush()
                lines.put(line)
        lines.put(None)

    thread = threading.Thread(target=read, daemon=True)
    thread.start()
    return lines, thread


def run_probe(executable, cases_path, out, recorder, *, activate):
    label = "active" if activate else "abort"
    with (out / f"{label}.stderr.log").open("w") as stderr:
        process = subprocess.Popen(
            [str(executable), str(cases_path)],
            cwd=out,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
        )
        lines, reader = prepare_reader(process, out / f"{label}.jsonl")
        try:
            first = lines.get(timeout=15)
            prepared = json.loads(first or "{}")
            if prepared.get("event") != "prepared":
                raise RuntimeError(f"Probe did not prepare: {first!r}")
            before = recorder.snapshot()
            time.sleep(2)
            after = recorder.snapshot()
            idle = {
                "seconds": 2,
                "eventsAtPrepared": before,
                "eventsBeforeCommand": after,
                "zeroLocalEvents": not before and not after,
                "allTasksSuspended": prepared.get("allTasksSuspended"),
                "command": "ACTIVATE" if activate else "ABORT",
            }
            if not idle["zeroLocalEvents"] or not idle["allTasksSuspended"]:
                raise RuntimeError(
                    "Local traffic or a resumed task before activation"
                )
            process.stdin.write(idle["command"] + "\n")
            process.stdin.flush()
            process.stdin.close()
            process.wait(timeout=120 if activate else 10)
            reader.join(timeout=5)
            if process.returncode:
                raise RuntimeError(
                    f"Probe exited {process.returncode}; inspect {label}.stderr.log"
                )
            events = [
                json.loads(line)
                for line in (out / f"{label}.jsonl").read_text().splitlines()
            ]
            if not activate and (
                recorder.snapshot()
                or any(e["event"] == "resume" for e in events)
            ):
                raise RuntimeError("Traffic or task resume in the abort run")
            return {
                "idle": idle,
                "events": events,
                "exitCode": process.returncode,
            }
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()


def report(out, results):
    meta = results["metadata"]
    verification = results["verification"]
    observations = [
        event
        for event in results["active"]["events"]
        if event["event"] == "result"
    ]
    rows = []
    for event in observations:
        status = str(event.get("status", "—"))
        error = event.get("error", {})
        error_text = (
            f"{error.get('domain')} {error.get('code')}" if error else "none"
        )
        redirects = (
            "; ".join(
                f"{r['status']} / {'follow' if r['followed'] else 'reject'}"
                for r in event.get("redirects", [])
            )
            or "none"
        )
        rows.append(
            f"| `{event['id']}` | {status} | {error_text} | {redirects} | {event.get('bytesReceived', 0)} |"
        )
    local = results["serverEvents"]
    hits = [e for e in local if e["kind"] == "http_request"]
    text = f"""# Current-plist transport experiment

Generated from this run's machine evidence, not a project specification or authorization policy.

## Run and scope

- UTC: `{meta["utc"]}`; repository base revision: `{meta["revision"]}`. Lab files are uncommitted; their exact run-time SHA-256 values are in `metadata.labSourceSHA256` in `results.json`.
- Runtime: `{meta["os"].replace(chr(10), "; ")}`; architecture: `{meta["architecture"]}`.
- Compiler: `{meta["swift"].replace(chr(10), "; ")}`.
- SDK: `{meta["sdkVersion"]}` (`{meta["sdkPath"]}`).
- Compile target: `{meta["compileTarget"]}`; Mach-O build-version output is recorded in `metadata.binaryBuildVersion`. Compilation against this SDK with a 13.0 deployment target does **not** test macOS 13 runtime behavior. No macOS 13 run was performed.
- The existing package declares `platforms: [.macOS(.v13)]` in `shell/Package.swift:10`; the source plist specifies `<key>LSMinimumSystemVersion</key>` followed by `<string>13.0</string>` in `shell/OnetimePad-Info.plist:62–63`.
- This is a standalone Swift/Foundation executable in a disposable `.app`, not the shipping executable, preview implementation, or a WebKit test.

## Bundle verification

- Source: `shell/OnetimePad-Info.plist`.
- Source SHA-256: `{verification["sourcePlistSHA256"]}`.
- Bundle SHA-256 after signing: `{verification["bundlePlistSHA256"]}`.
- Runtime `Bundle.main` SHA-256: `{verification["runtimePlistSHA256"]}`.
- Exact byte equality: `{verification["plistBytesEqual"]}`; `codesign --verify --strict`: passed.
- Runtime executable name: `OnetimePad`; runtime bundle id: `com.onetimesecret.pad`.
- No `NSAppTransportSecurity` dictionary in source or runtime bundle; no ATS exceptions added.
- Ad-hoc signature, separate code-signing identifier `transport-research`; no real signing identity, `open`, `lsregister`, install, or application launch through LaunchServices.
- Signed entitlements output: `{meta["signedEntitlements"] or "(empty)"}`. No app-sandbox entitlements were supplied. **This run is not app-sandbox-equivalent.**
- Existing `scripts/Companion.entitlements` includes `com.apple.security.app-sandbox`, `com.apple.security.network.client`, and `com.apple.security.network.server` set to true. That source file was read, not applied or edited. Its substitution-based keychain group was not synthesized.
- Protected inputs unchanged: `{results["protectedInputsUnchanged"]}`. Hashes are in `results.json`.

## Session and activation experiment

The settings model the implementation of `FeedbackClient.makeSession()` at `shell/Sources/CompanionKit/FeedbackClient.swift:121–134`: `.ephemeral`, nil cookie/credential/cache storage, cookies disabled, `.reloadIgnoringLocalCacheData`, 20-second request and 30-second resource timeouts. The production redirect delegate returns `completionHandler(nil)` at lines 138–146. Each case uses a fresh session. The probe uses GET rather than the feedback POST and deliberately omits that client's HTTPS-only URL admission check to measure Foundation transport.

Two directly launched processes created sessions and suspended data tasks, emitted `prepared`, and waited for stdin. The driver observed each for two seconds before sending a command. Both windows recorded zero local TCP accepts and zero local HTTP requests; all tasks reported suspended. The ABORT process exited without resuming tasks or producing local traffic. The ACTIVATE process then resumed the requests. This evidence covers only the instrumented listeners and this harness's activation path: it is not a packet capture, DNS audit, or proof about any production preview UI. Public endpoint traffic before activation was not observed at its server.

## Observed URLSession results

HTTP status is independent of transport error. A rejected redirect can return 302 with no transport error. For failed followed requests, inspect the per-transaction metrics and error rather than interpreting an earlier redirect status as final success.

| Case | HTTP status | Transport error | Redirect callback | Body bytes |
| --- | --- | --- | --- | --- |
{chr(10).join(rows)}

Local listeners recorded {len(hits)} HTTP requests after activation. Exact paths, listener labels, TCP accepts, and timestamps are in `server-events.json`; URLSession transaction metrics and redirect destinations are in `active.jsonl`. The local TLS certificate was self-signed for localhost/loopback; no trust exception, custom challenge handler, or system trust change was used. A trust failure is a negative TLS control, not evidence of an ATS HTTP rule.

## Findings and remaining coverage

- **TR-01 — transport distinction (reproduced):** compare `http_public_dns` with `https_public_control` and the separately named local/private cases above. These observations describe this bundle/runtime; they do not establish a universal host classifier or shipping authorization rule.
- **TR-02 — activation (reproduced):** both idle windows and the ABORT run recorded zero local events. The local positive control and followed local redirect subsequently reached the instrumented server. Production UI activation, pre-activation public traffic, DNS, and other sockets remain untested.
- **TR-03 — redirect behavior (reproduced where a callback occurred):** `local_redirect_reject` did not reach its target; `local_redirect_follow` did. Compare the public reject/follow results separately. The HTTPS-to-loopback attempts are inconclusive if they return 403 without a redirect callback; that is an HTTP response, not evidence about URLSession's handling of that redirect destination. Next step for that combination: an operator-controlled public TLS fixture that emits the required Location.
- **TR-04 — deployment coverage (unresolved):** no macOS 13 runtime, shipping app sandbox, WebKit, production preview, alternate proxy, or remote LAN-host execution. Tenant authorization, CSRF/origin, admin isolation, and SAML are outside this transport experiment and were not exercised. No deployment approval follows from these results.

## Interpretation limits

- Loopback names/literals, IPv6 loopback, and an available RFC1918 interface literal are separate cases from public DNS HTTP. The private-address request routes to this same machine, not another LAN host. No `.local` DNS, remote LAN host, public-IP-literal, or comprehensive address-class survey was performed. Optional cases absent from the table were skipped; see metadata.
- Public cases use `httpbingo.org`, a third-party diagnostic service, with a GET path and parameter-selected redirect destination. We control the local servers and chosen request/redirect inputs, **not** that public service, its DNS, or its server logs. HTTPS success is a reachable trusted-TLS control on this runtime. An HTTP failure must be interpreted using the actual error; reachability failure is not an ATS rejection.
- Public HTTPS-to-HTTP redirects target both the public service and the local instrumented listener. Deny/follow are research variants, not a new shipping network authorization decision. URLSession transport permission is not application-level approval to fetch a URL.
- Error `NSURLErrorDomain -1022`, when present, is the observed ATS failure. Loopback/private success cannot be generalized to public DNS HTTP. A final HTTP 200 in the redirect-follow experiment demonstrates only the measured destination/runtime combination.
- Response bodies, request credentials, cookies, and environment values were not saved. Requests contain synthetic lab paths only. The service can see ordinary network metadata such as source IP. The fixture and transaction artifacts include local interface/server addresses. No secret or document content is submitted.
- System proxy configuration is saved in `system-proxy.txt`; environment proxy variable **names only** are in metadata. Per-transaction proxy flags are in machine evidence. These observations do not establish behavior on a different OS, network, proxy, SDK build, or app sandbox.
- The driver did not write shipping sources, the source plist, entitlements, or the design specification. Recorded protected-input hashes were equal before and after execution; this is not a statement about unrelated working-tree edits. No production policy or project security/privacy guarantee is established by this report.

## Reproduce

Before rerunning, obtain operator approval. This builds/signs a temporary
bundle and invokes a Foundation executable directly, starts bounded local
HTTP/TLS servers, and sends synthetic diagnostic requests to third-party
`httpbingo.org`. It exposes ordinary network metadata but does not open a GUI
or request accessibility permission. The active-process deadline is 120 seconds;
the driver stops its servers and processes. No system trust/settings change is
part of the experiment.

From the repository root:

```sh
python3 tools/markdown-preview-lab/transport/run.py --output runs/repro
```

Use a fresh output directory. The driver copies the **current** source plist without serialization, compiles with an explicit 13.0 deployment target, verifies and signs the isolated bundle, starts bounded local fixture threads, invokes `Contents/MacOS/OnetimePad` directly, records both activation paths, and stops all servers/processes in `finally`. Each subprocess has a timeout; the network phase has a 120-second process deadline and each session has 20/30-second limits. The delegate requests cancellation after received bytes exceed 64 KiB; a delivered chunk can overshoot that threshold, which was not exercised by the saved responses. Redirect following is limited to five hops. No long-running server command is needed. Use `--local-only` to omit third-party requests (that mode cannot answer public-DNS HTTP behavior).

Build/sign/verification invocations and compiler logs are in `build-log.json`; configuration is in `cases.json`. Exit zero means the bundle, fixture, activation, and evidence checks passed, not that every network request succeeded. `assertions` in `results.json` is the exact validation scope.
"""
    (out / "report.md").write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="runs/current")
    parser.add_argument("--local-only", action="store_true")
    args = parser.parse_args()
    out = (LAB / args.output).resolve()
    if not out.is_relative_to(LAB) or out == LAB:
        parser.error("Output must be a new directory inside this transport lab")
    out.mkdir(parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    servers = []
    recorder = Recorder()
    protected = [
        REPO / path
        for path in (
            "shell/OnetimePad-Info.plist",
            "scripts/Companion.entitlements",
            "shell/Sources/CompanionKit/FeedbackClient.swift",
            "docs/spec/design/2026-1016-markdown-dialects-and-preview.md",
        )
    ]
    initial_hashes = {
        str(path.relative_to(REPO)): sha(path) for path in protected
    }
    results = {"protectedInputsBefore": initial_hashes}
    try:
        (out / "tmp").mkdir()
        (out / "module-cache").mkdir()
        env = dict(
            os.environ,
            TMPDIR=str(out / "tmp"),
            CLANG_MODULE_CACHE_PATH=str(out / "module-cache"),
        )
        sdk = command(["xcrun", "--show-sdk-path"])
        arch = platform.machine()
        target = f"{arch}-apple-macosx13.0"
        metadata = dict(
            utc=datetime.now(UTC).isoformat(),
            revision=command(["git", "--no-pager", "rev-parse", "HEAD"]),
            os=command(["sw_vers"]),
            architecture=arch,
            swift=command(["xcrun", "swift", "--version"]),
            sdkPath=sdk,
            sdkVersion=command(["xcrun", "--show-sdk-version"]),
            compileTarget=target,
            proxyEnvironmentVariableNames=sorted(
                key
                for key in os.environ
                if key.lower()
                in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")
            ),
            localOnly=args.local_only,
            labSourceSHA256={
                name: sha(LAB / name)
                for name in ("run.py", "TransportProbe.swift")
            },
            optionalSkips=[],
        )
        results["metadata"] = metadata
        (out / "system-proxy.txt").write_text(
            command(["scutil", "--proxy"]) + "\n"
        )
        contents = out / "TransportResearch.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        source_plist = REPO / "shell/OnetimePad-Info.plist"
        bundle_plist = contents / "Info.plist"
        shutil.copyfile(source_plist, bundle_plist)
        info = plistlib.loads(bundle_plist.read_bytes())
        assert info["CFBundleExecutable"] == "OnetimePad"
        assert "NSAppTransportSecurity" not in info
        executable = contents / "MacOS" / info["CFBundleExecutable"]
        invocations = [
            [
                "xcrun",
                "swiftc",
                "-swift-version",
                "6",
                "-parse-as-library",
                "-target",
                target,
                "-sdk",
                sdk,
                "-module-cache-path",
                str(out / "module-cache"),
                str(LAB / "TransportProbe.swift"),
                "-o",
                str(executable),
            ],
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "transport-research",
                str(contents.parent),
            ],
            [
                "codesign",
                "--verify",
                "--strict",
                "--verbose=2",
                str(contents.parent),
            ],
        ]
        build_log = []
        for invocation in invocations:
            completed = subprocess.run(
                invocation,
                cwd=LAB,
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            build_log.append(
                dict(
                    argv=invocation,
                    returncode=completed.returncode,
                    stdout=completed.stdout,
                    stderr=completed.stderr,
                )
            )
            save(out / "build-log.json", build_log)
            if completed.returncode:
                raise RuntimeError(
                    f"Build/verification failed; inspect {out / 'build-log.json'}"
                )
        signature_result = subprocess.run(
            ["codesign", "--display", "--verbose=4", str(contents.parent)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert signature_result.returncode == 0
        metadata["signature"] = (
            signature_result.stdout + signature_result.stderr
        )
        assert "Signature=adhoc" in metadata["signature"]
        assert "Identifier=transport-research" in metadata["signature"]
        metadata["binaryBuildVersion"] = command(
            ["xcrun", "vtool", "-show-build", str(executable)]
        )
        entitlement_result = subprocess.run(
            [
                "codesign",
                "--display",
                "--entitlements",
                ":-",
                str(contents.parent),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        metadata["signedEntitlements"] = entitlement_result.stdout.strip()
        metadata["signedEntitlementsDiagnostic"] = (
            entitlement_result.stderr.strip()
        )
        metadata["signedEntitlementsExitCode"] = entitlement_result.returncode
        assert entitlement_result.returncode == 0
        assert not metadata["signedEntitlements"]
        verification = dict(
            sourcePlistSHA256=sha(source_plist),
            bundlePlistSHA256=sha(bundle_plist),
            plistBytesEqual=source_plist.read_bytes()
            == bundle_plist.read_bytes(),
        )
        assert verification["plistBytesEqual"]
        results["verification"] = verification
        port = start_server("127.0.0.1", recorder, "ipv4-loopback", servers)
        local = f"http://127.0.0.1:{port}"
        tests = []

        def add(name, url, follow=False):
            tests.append(dict(id=name, url=url, followRedirects=follow))

        add("http_loopback_ipv4", local + "/ok?case=ipv4")
        add("http_localhost", f"http://localhost:{port}/ok?case=localhost")
        try:
            v6port = start_server("::1", recorder, "ipv6-loopback", servers)
            add("http_loopback_ipv6", f"http://[::1]:{v6port}/ok?case=ipv6")
        except OSError as error:
            metadata["optionalSkips"].append(f"IPv6 listener: {error}")
        address = private_ipv4()
        if address:
            try:
                private_port = start_server(
                    address, recorder, "private-interface-self", servers
                )
                add(
                    "http_private_interface_self",
                    f"http://{address}:{private_port}/ok?case=private",
                )
            except OSError as error:
                metadata["optionalSkips"].append(
                    f"Private interface listener: {error}"
                )
        else:
            metadata["optionalSkips"].append(
                "No RFC1918 IPv4 interface available"
            )
        cert, key = out / "fixture-cert.pem", out / "fixture-key.pem"
        command(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost,IP:127.0.0.1",
                "-keyout",
                str(key),
                "-out",
                str(cert),
            ],
            env=env,
        )
        os.chmod(key, 0o600)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls_port = start_server(
            "127.0.0.1", recorder, "self-signed-tls", servers, context
        )
        add(
            "https_local_untrusted_control",
            f"https://127.0.0.1:{tls_port}/ok?case=untrusted",
        )
        for follow in (False, True):
            mode = "follow" if follow else "reject"
            destination = local + f"/redirect-target?case=local-{mode}"
            add(
                f"local_redirect_{mode}",
                local + "/redirect?to=" + quote(destination, safe=""),
                follow,
            )
        if not args.local_only:
            public = "https://httpbingo.org"
            add(
                "http_public_dns",
                "http://httpbingo.org/get?transport_lab=public-http",
            )
            add(
                "https_public_control",
                public + "/get?transport_lab=https-control",
            )
            for category, base in (
                ("public", "http://httpbingo.org/get"),
                ("loopback", local + "/redirect-target"),
            ):
                for follow in (False, True):
                    mode = "follow" if follow else "reject"
                    destination = base + f"?case=https-to-{category}-{mode}"
                    add(
                        f"https_to_http_{category}_{mode}",
                        public
                        + "/redirect-to?url="
                        + quote(destination, safe=""),
                        follow,
                    )
        save(out / "cases.json", tests)
        metadata["listeners"] = [
            dict(
                label=server.label,
                address=server.server_address[0],
                port=server.server_port,
            )
            for server, _ in servers
        ]
        results["abort"] = run_probe(
            executable, out / "cases.json", out, recorder, activate=False
        )
        assert not recorder.snapshot()
        results["active"] = run_probe(
            executable, out / "cases.json", out, recorder, activate=True
        )
        runtime = results["active"]["events"][0]
        verification["runtimePlistSHA256"] = runtime["plistSHA256"]
        assert verification["sourcePlistSHA256"] == runtime["plistSHA256"]
        assert (
            results["abort"]["events"][0]["plistSHA256"]
            == runtime["plistSHA256"]
        )
        events = results["active"]["events"]
        outcomes = {
            event["id"]: event for event in events if event["event"] == "result"
        }
        assert len(outcomes) == len(tests)
        assert events[-1] == {"event": "complete", "caseCount": len(tests)}
        assert not any(
            event.get("driverWaitTimedOut") for event in outcomes.values()
        )
        hits = [
            event["path"]
            for event in recorder.snapshot()
            if event["kind"] == "http_request"
        ]
        checks = {
            "exact_current_plist_after_signing_and_at_runtime": True,
            "no_ats_dictionary": not runtime["atsDictionaryPresent"],
            "both_idle_windows_zero_local_events": results["active"]["idle"][
                "zeroLocalEvents"
            ]
            and results["abort"]["idle"]["zeroLocalEvents"],
            "abort_without_resume_or_local_traffic": True,
            "all_cases_completed_within_deadlines": True,
            "local_ipv4_control_status_200": outcomes["http_loopback_ipv4"].get(
                "status"
            )
            == 200,
            "local_reject_returns_302": outcomes["local_redirect_reject"].get(
                "status"
            )
            == 302,
            "local_reject_target_not_requested": "/redirect-target?case=local-reject"
            not in hits,
            "local_follow_target_requested": "/redirect-target?case=local-follow"
            in hits,
            "local_follow_returns_200": outcomes["local_redirect_follow"].get(
                "status"
            )
            == 200,
        }
        results["assertions"] = checks
        if not all(checks.values()):
            raise RuntimeError(
                "A fixture/evidence check failed; inspect results.json"
            )
    except Exception as error:
        results["driverError"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        for server, thread in servers:
            server.shutdown()
            server.server_close()
            thread.join(timeout=4)
        results["serverEvents"] = recorder.snapshot()
        (out / "fixture-key.pem").unlink(missing_ok=True)
        results["cleanup"] = {
            "fixturePrivateKeyRemoved": not (out / "fixture-key.pem").exists(),
            "serverThreadsStopped": all(
                not thread.is_alive() for _, thread in servers
            ),
        }
        results["protectedInputsAfter"] = {
            str(path.relative_to(REPO)): sha(path) for path in protected
        }
        results["protectedInputsUnchanged"] = (
            results["protectedInputsAfter"] == initial_hashes
        )
        save(out / "server-events.json", results["serverEvents"])
        save(out / "results.json", results)
        if "driverError" not in results:
            assert results["metadata"]["labSourceSHA256"] == {
                name: sha(LAB / name)
                for name in ("run.py", "TransportProbe.swift")
            }
            assert results["protectedInputsUnchanged"]
            assert results["cleanup"]["serverThreadsStopped"]
            report(out, results)
            print(f"Evidence and report: {out}")


if __name__ == "__main__":
    main()
