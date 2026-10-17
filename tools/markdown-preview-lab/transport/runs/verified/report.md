# Current-plist transport experiment

Generated from this run's machine evidence, not a project specification or authorization policy.

## Run and scope

- UTC: `2026-10-17T03:12:55.160381+00:00`; repository base revision: `54d38a549b597f9fd5a664e48db05a293bccbb5d`. Lab files are uncommitted; their exact run-time SHA-256 values are in `metadata.labSourceSHA256` in `results.json`.
- Runtime: `ProductName:		macOS; ProductVersion:		27.2; BuildVersion:		26B5101f`; architecture: `arm64`.
- Compiler: `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1); Target: arm64-apple-macosx27.2.0`.
- SDK: `27.0` (`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`).
- Compile target: `arm64-apple-macosx13.0`; Mach-O build-version output is recorded in `metadata.binaryBuildVersion`. Compilation against this SDK with a 13.0 deployment target does **not** test macOS 13 runtime behavior. No macOS 13 run was performed.
- The existing package declares `platforms: [.macOS(.v13)]` in `shell/Package.swift:10`; the source plist specifies `<key>LSMinimumSystemVersion</key>` followed by `<string>13.0</string>` in `shell/OnetimePad-Info.plist:62–63`.
- This is a standalone Swift/Foundation executable in a disposable `.app`, not the shipping executable, preview implementation, or a WebKit test.

## Bundle verification

- Source: `shell/OnetimePad-Info.plist`.
- Source SHA-256: `fefd4afa763b562ec82da8a68efe725f72dd2c4c9ae09dc89ac341c72f5370c1`.
- Bundle SHA-256 after signing: `fefd4afa763b562ec82da8a68efe725f72dd2c4c9ae09dc89ac341c72f5370c1`.
- Runtime `Bundle.main` SHA-256: `fefd4afa763b562ec82da8a68efe725f72dd2c4c9ae09dc89ac341c72f5370c1`.
- Exact byte equality: `True`; `codesign --verify --strict`: passed.
- Runtime executable name: `OnetimePad`; runtime bundle id: `com.onetimesecret.pad`.
- No `NSAppTransportSecurity` dictionary in source or runtime bundle; no ATS exceptions added.
- Ad-hoc signature, separate code-signing identifier `transport-research`; no real signing identity, `open`, `lsregister`, install, or application launch through LaunchServices.
- Signed entitlements output: `(empty)`. No app-sandbox entitlements were supplied. **This run is not app-sandbox-equivalent.**
- Existing `scripts/Companion.entitlements` includes `com.apple.security.app-sandbox`, `com.apple.security.network.client`, and `com.apple.security.network.server` set to true. That source file was read, not applied or edited. Its substitution-based keychain group was not synthesized.
- Protected inputs unchanged: `True`. Hashes are in `results.json`.

## Session and activation experiment

The settings model the implementation of `FeedbackClient.makeSession()` at `shell/Sources/CompanionKit/FeedbackClient.swift:121–134`: `.ephemeral`, nil cookie/credential/cache storage, cookies disabled, `.reloadIgnoringLocalCacheData`, 20-second request and 30-second resource timeouts. The production redirect delegate returns `completionHandler(nil)` at lines 138–146. Each case uses a fresh session. The probe uses GET rather than the feedback POST and deliberately omits that client's HTTPS-only URL admission check to measure Foundation transport.

Two directly launched processes created sessions and suspended data tasks, emitted `prepared`, and waited for stdin. The driver observed each for two seconds before sending a command. Both windows recorded zero local TCP accepts and zero local HTTP requests; all tasks reported suspended. The ABORT process exited without resuming tasks or producing local traffic. The ACTIVATE process then resumed the requests. This evidence covers only the instrumented listeners and this harness's activation path: it is not a packet capture, DNS audit, or proof about any production preview UI. Public endpoint traffic before activation was not observed at its server.

## Observed URLSession results

HTTP status is independent of transport error. A rejected redirect can return 302 with no transport error. For failed followed requests, inspect the per-transaction metrics and error rather than interpreting an earlier redirect status as final success.

| Case | HTTP status | Transport error | Redirect callback | Body bytes |
| --- | --- | --- | --- | --- |
| `http_loopback_ipv4` | 200 | none | none | 17 |
| `http_localhost` | 200 | none | none | 17 |
| `http_loopback_ipv6` | 200 | none | none | 17 |
| `http_private_interface_self` | 200 | none | none | 17 |
| `https_local_untrusted_control` | — | NSURLErrorDomain -1202 | none | 0 |
| `local_redirect_reject` | 302 | none | 302 / reject | 13 |
| `local_redirect_follow` | 200 | none | 302 / follow | 17 |
| `http_public_dns` | — | NSURLErrorDomain -1022 | none | 0 |
| `https_public_control` | 200 | none | none | 835 |
| `https_to_http_public_reject` | 302 | none | 302 / reject | 0 |
| `https_to_http_public_follow` | — | NSURLErrorDomain -1022 | 302 / follow | 0 |
| `https_to_http_loopback_reject` | 403 | none | none | 147 |
| `https_to_http_loopback_follow` | 403 | none | none | 147 |

Local listeners recorded 7 HTTP requests after activation. Exact paths, listener labels, TCP accepts, and timestamps are in `server-events.json`; URLSession transaction metrics and redirect destinations are in `active.jsonl`. The local TLS certificate was self-signed for localhost/loopback; no trust exception, custom challenge handler, or system trust change was used. A trust failure is a negative TLS control, not evidence of an ATS HTTP rule.

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
