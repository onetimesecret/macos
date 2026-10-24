# Current-plist Foundation transport lab

Isolated research only. Nothing here is linked into the shipping app or defines a new fetch-authorization policy.

## Recorded run

The recorded run is [runs/verified/report.md](runs/verified/report.md), with [machine evidence](runs/verified/results.json). It exercised 13 transport cases plus a separate abort-before-activation process on macOS 27.2 / SDK 27.0 / arm64. The binary's Mach-O minimum OS is 13.0; **macOS 13 runtime behavior was not tested**.

Observed in that run:

| Input | Result |
| --- | --- |
| Public DNS HTTP | `NSURLErrorDomain -1022`; metrics show zero request-header bytes sent |
| Trusted public HTTPS | HTTP 200 |
| Loopback IPv4, `localhost`, IPv6 loopback | HTTP 200 |
| Machine's own RFC1918 interface address | HTTP 200; not a remote LAN-host test |
| Self-signed local HTTPS | Certificate error `-1202`; no trust bypass |
| Local redirect, reject / follow | 302 with no target request / 200 with target request |
| Public HTTPS → public HTTP, reject / follow | 302 / ATS error `-1022` |
| Public HTTPS → loopback attempt | 403 without a redirect callback; inconclusive for that redirect path |

Both two-second pre-activation windows recorded zero local TCP accepts and HTTP requests. The ABORT process never resumed its tasks. This measures the harness and its instrumented listeners, not production UI behavior, all outbound traffic, or DNS.

The current source plist, signed bundle plist, and runtime `Bundle.main` plist had identical SHA-256:

```text
fefd4afa763b562ec82da8a68efe725f72dd2c4c9ae09dc89ac341c72f5370c1
```

The executable is `TransportResearch.app/Contents/MacOS/OnetimePad`, matching `CFBundleExecutable`. The plist remains byte-for-byte intact, including its bundle identifier. The bundle is ad-hoc signed with a separate code-signing identifier and invoked directly, not installed or launched through LaunchServices. **No app-sandbox entitlements were applied. This is a bundle/ATS experiment, not app-sandbox-equivalent execution.**

## Reproduce

Requirements: macOS, an Xcode-selected Swift 6 toolchain, Python 3.11+, and `openssl` supporting `req -addext`. No Python packages or shipping build are needed.

Before rerunning, obtain operator approval for this transport experiment. It
builds/signs a temporary app bundle, invokes its Foundation executable directly,
and starts bounded local HTTP/TLS servers. The full run sends synthetic GETs
to third-party `httpbingo.org`, exposing ordinary network metadata. It does not
open a GUI, request accessibility access, or change system trust/settings. The
active-process deadline is 120 seconds; the driver cleans up fixture processes.

From the repository root, use a fresh output directory:

```sh
python3 tools/markdown-preview-lab/transport/run.py --output runs/repro
```

For local fixtures only:

```sh
python3 tools/markdown-preview-lab/transport/run.py --local-only --output runs/local-repro
```

The local-only mode does not test public DNS HTTP or trusted public HTTPS. The full run uses synthetic GETs against `httpbingo.org`, a third-party diagnostic service with parameter-selected redirects. We control our local servers and request inputs, not that service's infrastructure or logs. Public requests send no document content or credentials, but expose ordinary network metadata to that service.

`run.py` copies the current source plist, compiles `TransportProbe.swift`, signs/verifies the disposable bundle, starts fixture threads, runs ABORT and ACTIVATE processes, and stops the fixture servers. Session settings model `FeedbackClient.makeSession()`; GET requests intentionally bypass that client's HTTPS-only endpoint validation. Redirect rejection models its delegate; following is a separate research variant.

Requests use 20-second request / 30-second resource timeouts, a 35-second per-case wait, and a 120-second active-process deadline. There are five-hop redirect and 64 KiB response-cancellation thresholds. Build subprocesses have 90-second deadlines. No separate persistent server is required. The generated local TLS private key is removed during cleanup; no system trust store is changed.

## Artifacts

- `report.md`: scope, results, limitations, and reproduction instructions.
- `results.json`: assertions, input/source hashes, runtime/SDK details, signature and Mach-O metadata, activation observations, and cleanup results.
- `cases.json`: exact requested URLs and redirect modes.
- `active.jsonl`, `abort.jsonl`: runtime bundle verification, task lifecycle, transport errors, redirects, and URLSession transaction metrics.
- `server-events.json`: local TCP accepts, HTTP paths, TLS failures, and monotonic timestamps.
- `build-log.json`: exact compile/sign/verification commands and outputs.
- `system-proxy.txt`, `*.stderr.log`: proxy configuration and process diagnostics.
- `TransportResearch.app/`: actual executable bundle, retained locally but ignored by git, along with compiler caches and temporary directories.

Artifacts include local interface addresses and public server addresses. Response bodies are not stored. `runs/current/` is the initial exploratory run; `runs/verified/` records the tested Swift/driver source hashes, independently checked after execution. Afterward, report wording and the driver's report template were corrected to describe the byte-cancellation threshold accurately and add advance execution notices. The transport logic and machine observations were not changed or rerun. Thus the recorded driver hash identifies the tested version, not the later report-template edit. Existing output directories are never overwritten by the driver.

Exit zero means the bundle, activation, local fixture, completion, and cleanup checks passed. Public transport errors are recorded outcomes, not automatically failed harness assertions. Protected-input hashes were equal before and after both runs. Unrelated working-tree edits are not reverted.
