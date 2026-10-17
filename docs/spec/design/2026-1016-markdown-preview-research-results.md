---
id: 2026-1016-markdown-preview-research-results
title: Markdown preview research results
status: research
dated: 2026-10-16
surfaces: OnetimePad Markdown preview
---

# Markdown preview research results

Companion to [Markdown dialects and restricted preview](2026-1016-markdown-dialects-and-preview.md).
This report records the placeholder-parser, current-plist transport, and
attachment-accessibility experiments requested on 2026-10-16. Recorded run
timestamps are 2026-10-17 UTC, corresponding to 2026-10-16 locally.

## Status and evidence boundaries

This is an experimental report, not an accepted specification, parser decision,
network authorization, or amendment to a law or ADR. The lab reports are
navigation aids; the linked machine output records the observations. Neither
those reports nor this document establish product guarantees.

All prototypes are isolated under
[`tools/markdown-preview-lab/`](../../../tools/markdown-preview-lab/).
They are not integrated into the shipping preview. The dialects document is
unchanged by this documentation update.

| Experiment | Recorded result | What remains open |
| --- | --- | --- |
| Placeholder abstract syntax trees (ASTs) | 270/270 assertions; three pinned C parser candidates | Opaque-object representation, exact GFM contract, composer/native integration |
| Offline parser-contract supplement | 560/560 fixture rows across 14 configurations; 34/34 harness regressions | Swift/native conversion, exact GFM contract, reviewed span disposition |
| Current-plist Foundation transport | 13 cases completed; 10/10 harness assertions | Shipping sandbox, macOS 13 runtime, full request policy |
| TextKit 1 attachment accessibility | 127/127 local automated checks | External accessibility blocked; manual VoiceOver not performed |

The parser fixtures test spellings and syntax trees, not sealed-object identity.
The transport assertions test the harness and instrumentation, not universal
request isolation. The attachment checks are in-process and synthetic, not
VoiceOver verification. No research gate is closed by this report.

## Operator notice before further execution

The attachment work launched a temporary macOS app, **Attachment AX Lab**, and
an external accessibility helper, **AXClient**, before sufficient explanation
and warning. The operator reported a permission request and declined to grant
access without context. That warning should have preceded execution.

The recorded helper calls returned accessibility-disabled errors. This does
not establish that macOS displayed no prompt. No permission grant was recorded.
Accessibility permission is distinct from administrator/root access and can
permit broad UI inspection and control; it is not needed to retain or read
these results.

Before another app launch or permission-sensitive test, explain the executable,
visible behavior, data accessed, requested permission, external traffic,
duration, and cleanup; then wait for operator approval. Do not enable VoiceOver,
request an accessibility grant, or change system settings implicitly. The
commands below are records and optional reproduction instructions, not approval
to execute them. No apps were relaunched to write this report.

## 1. Placeholder parsing in both dialect families

### Inputs and pinned candidates

The standalone C harness compares each parser's XML AST. Both GFM candidates
enable `table`, `strikethrough`, `autolink`, `tagfilter`, and `tasklist`.
The Swift Markdown wrapper is not used. Test-only HTML serialization enables
raw HTML for comparison; that is not a native preview policy.

| Candidate | Runtime version | Source revision |
| --- | --- | --- |
| Official `commonmark/cmark` | `0.31.2` | `eec0eeba6d31189fd828314576494566d539b1e3` |
| Pinned `swiftlang/swift-cmark` | `0.29.0.gfm.13` | `08ddb528923cc1a6527e02b7a1aee9e516ca749a` |
| Historical official `github/cmark-gfm` | `0.29.0.gfm.0` | `b8eb2e00de094999f978e9cb02b1a78d810812d3` |

There are 45 fixture templates, each run with the alphanumeric token
`OTSAttachment0123456789ABCDEF0123456789ABCDEF0Z` and U+FFFC against all three
candidates: **270/270 assertions passed**. Another **8/8 lab unit tests passed**.
These assertions encode the expected experimental trees, not a declaration
that every tree is suitable for the app.

### Observed differences

In this table, `{P}` is the substituted token or U+FFFC.

| ID | Fixture | Observation |
| --- | --- | --- |
| P01 | `_note_{P}` and before/both-side variants | ASCII prevents underscore emphasis in all candidates. U+FFFC permits emphasis in CommonMark 0.31.2, but not in either GFM candidate. |
| P02 | `a*{P}*b` | ASCII creates emphasis in all candidates. U+FFFC leaves literal text in CommonMark but creates emphasis in both GFM candidates. |
| P03 | Bare `www.example.com{P}` and `https://example.com{P}` | Both GFM candidates include either spelling in the link label and destination. CommonMark leaves bare URLs as text. |
| P04 | `person@example.com{P}` | GFM includes ASCII in the email link, but leaves U+FFFC after the link. |
| P05 | Pipe-adjacent cells and an excess third cell in a two-column table | GFM parses the table but omits the excess cell and its token from the AST. CommonMark retains the table-like source as paragraph text. |
| P06 | Link/image brackets, labels, alt text, titles and destinations | Spellings appear as text or resource metadata, not object nodes. Insertion between `]` and `(` breaks inline-resource syntax; GFM can then autolink the exposed URL. |
| P07 | HTML tag/attribute names, attribute values, comments, image/CSS destinations | ASCII and U+FFFC differ in tag/name recognition. Tokens inside valid attributes and comments are part of opaque HTML literals, not child objects. |

Internal punctuation probes classify U+FFFC as punctuation in cmark 0.31.2
and not punctuation in either GFM candidate. The independent Unicode category
is `So`. Nevertheless, both GFM URL scanners include U+FFFC in the tested bare
URLs: switching from ASCII to U+FFFC alone does not create an opaque atom.

**Interpretation:** restoration from emitted text alone needs further design.
Metadata-only and discarded-syntax occurrences require explicit identity/order
handling. This experiment did not exercise the shipping renderer's recovery
path or establish actual loss of a sealed object in the app.

### Independent official-example comparison

| Candidate | Exact HTML matches | Matches after narrow HTML-event normalization |
| --- | --- | --- |
| CommonMark 0.31.2 | 652/652 | 652/652 |
| Pinned Swift GFM fork | 651/677 | 653/677 |
| Historical official GFM | 661/677 | 663/677 |

Normalization only reconciles attribute ordering and void-element syntax.
The GFM differences are separated as follows:

- Serializer-only: examples **279, 280**.
- Extension-context differences: **140, 141, 142, 145, 147** match with tag
  filtering disabled; **611, 615, 617, 620, 621** match with extended autolinking
  disabled. Headline totals retain the full-extension mismatches.
- Unresolved historical-GFM differences: **324, 633, 634, 635**.
- Unresolved pinned-fork differences: **324, 398, 426, 434, 435, 436, 473, 474,
  475, 477, 634, 635, 649, 650**.

Neither GFM configuration matches the complete published corpus exactly.
The passing CommonMark corpus is evidence for this C build, not for the
shipping Swift wrapper or restricted native rendering.

Official oracle provenance:

- [CommonMark 0.31.2 JSON](https://spec.commonmark.org/0.31.2/spec.json), SHA-256
  `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`.
- [Published GFM page](https://github.github.com/gfm/), version heading
  `Version 0.29-gfm (2019-04-06)`, SHA-256
  `b153d814fdfc8624bb6da7449162c1cd707a637f7d1c1b636eb44b9cf63fa220`.
  The extractor recovered all 677 numbered examples.

Evidence: [AST observations](../../../tools/markdown-preview-lab/parser/results/ast-results.jsonl),
[corpus totals and enumerated mismatches](../../../tools/markdown-preview-lab/parser/results/summary.json),
[build/source provenance](../../../tools/markdown-preview-lab/parser/results/provenance.json),
and [parser report](../../../tools/markdown-preview-lab/parser/README.md).

The offline supplement below adds the dedicated attribute, span, tilde, and
`textarea` probes. Remaining R1 work includes the atom contract, reviewed
table-span disposition, exact GFM configuration/structural differences,
dependency/license review, and integration. The HTML composer was not prototyped
here; P07 supplies inputs for R3, not an R3 result.

### Offline continuation: parser contract and wrapper configuration

After commit `41266668`, a separate C-only supplement tested **40 templates ×
14 configurations** using the same pinned source revisions. It rebuilt local
C executables and used already saved official examples. No network, GUI,
accessibility, permission, or settings operation was performed. Original lab
observations remain separate and unchanged.

The current preview calls `Document(parsing:options:)` with
`[.disableSmartOpts]`. Source inspection maps that to the C mask **1048578**
(`TABLE_SPANS | SOURCEPOS`) and exactly `table`, `strikethrough`, `tasklist`.
It does not attach `autolink` or `tagfilter`. The supplement compares this full
configuration with one-option changes, extension-free cores, and five-extension
GFM modes. Extension-free fork core is not labelled CommonMark 0.31.2.

| ID | Executed observation | Consequence for further research |
| --- | --- | --- |
| C01 | GFM modes and the current-wrapper configuration accept single/double strikethrough tildes; triple inline runs remain literal. `DOUBLE_TILDE` rejects single runs; triple-tilde fences remain code blocks. | Review exact published GFM behavior rather than assuming double-only syntax. |
| C02 | The pinned fork parses `^[note](key)` as an attribute node even with zero extensions; the other candidates parse a literal caret and ordinary link. Attribute payloads are absent from the fork's diagnostic HTML/XML. | Disabling GFM extensions does not remove Apple core syntax; inspect the API tree. |
| C03 | Current-wrapper options enable numeric column/row spans and filler cells; spans-off modes retain separate cells and literal carets. | A span decision needs explicit parser configuration and updated native expectations. |
| C04 | Thirty fixture rows produce malformed upstream span XML. Header-span XML can be valid while omitting metadata. | Separate serializer defects from grammar results; use API span values rather than XML alone. |
| C05 | Modern CommonMark and pinned-fork core keep blank lines inside a `textarea` HTML block through its closing tag. Historical GFM boundaries differ; tagfilter changes output separately. | Block recovery and tag filtering need separate fixtures. |
| C06 | CommonMark example 354 leaves currency-symbol emphasis literal; both GFM source versions emphasize the Unicode currency symbols. | The base punctuation difference persists without extensions. |
| C07 | SMART changes paragraph text differently from a full wrapper configuration in which the table extension consumes divider syntax. | An isolated flag is not a substitute for the complete wrapper invocation. |

Reviewed results: **560/560 API-AST checks, 560/560 HTML checks, and 560/560
XML projections**; **14/14** mode checks, **120/120** toggle comparisons, and
**240/240** byte-identical comparisons with the original baseline executables.
Expected ASTs are authored separately from actual output; expected HTML is
generated from those ASTs, not an independent structural oracle.

Of **70 selected official-example comparisons**, **45 match exactly** and
**25 differ as explicitly expected**: 12 currency-punctuation comparisons,
six `textarea` comparisons, and seven single-tilde comparisons across modes.
These are cross-mode/cross-dialect controls, not additional failures in the
earlier full-corpus totals.

Review tightened two harness checks. All **441 saved source-manifest entries**
are validated before parser execution, with compiler-emitted dependencies for
90 translation units. Known malformed span attributes are removed only from a
diagnostic XML copy, which must parse and match the expected projection; the
raw XML is retained. **34/34 isolated regressions** reject changed inputs and
unrelated XML corruption, including eight formerly omitted-input mutations
that execute no parser subprocess.

Evidence: [supplement report and complete mode table](../../../tools/markdown-preview-lab/parser/contract/README.md),
[reviewed counts](../../../tools/markdown-preview-lab/parser/contract/results/review/summary.json),
[raw and diagnostic fixture output](../../../tools/markdown-preview-lab/parser/contract/results/review/fixtures.jsonl),
[review regression evidence](../../../tools/markdown-preview-lab/parser/contract/results/review/regression-tests.json),
and [source/build provenance](../../../tools/markdown-preview-lab/parser/contract/results/review/provenance.json).

Executed offline from the repository root, with the existing source checkouts
and generated headers; these commands compile/run bounded C CLIs, not apps:

```sh
python3 -B tools/markdown-preview-lab/parser/contract/build.py
python3 -B tools/markdown-preview-lab/parser/contract/test_review.py
python3 -B tools/markdown-preview-lab/parser/contract/run.py
```

Builds target macOS 13.0; execution was on macOS 27.2, not macOS 13.
Swift conversion, native object identity, resource loading, and exhaustive
malformed span/attribute forms remain untested. No parser architecture is
selected by this supplement.

## 2. Transport using the current Info.plist

### Execution scope

The probe is a standalone Foundation executable in a disposable, ad-hoc-signed
bundle, invoked directly without installation or LaunchServices registration.
Its executable is named `OnetimePad` to match the copied plist. The source,
signed-bundle, and runtime `Bundle.main` plist bytes had identical SHA-256:

```text
fefd4afa763b562ec82da8a68efe725f72dd2c4c9ae09dc89ac341c72f5370c1
```

The copied [`OnetimePad-Info.plist`](../../../shell/OnetimePad-Info.plist) had
no `NSAppTransportSecurity` dictionary. No ATS exception was added. No
app-sandbox entitlements were applied, so this was **not shipping-sandbox
equivalent**.

Runtime was arm64 macOS **27.2 (26B5101f)** with Swift **6.4**, SDK **27.0**.
The binary targets macOS **13.0**, but no macOS 13 runtime was tested.

Each case uses a fresh ephemeral session with nil cookie/credential/cache
storage, cookies disabled, local-cache bypass, and 20/30-second request/resource
timeouts. These settings model `FeedbackClient.makeSession()`. GET requests
intentionally bypass that client's HTTPS-only admission check to measure
Foundation transport; redirect following is a research variant.

### Measured outcomes

| Input | Observed result |
| --- | --- |
| Public DNS HTTP | `NSURLErrorDomain -1022` (ATS); metrics report zero request-header bytes sent |
| Trusted public HTTPS | HTTP 200 |
| IPv4 loopback, `localhost`, IPv6 loopback | HTTP 200 for each |
| Machine's own private-interface address | HTTP 200; not a remote LAN test |
| Self-signed local HTTPS | Certificate error `-1202`; no trust bypass |
| Local redirect rejected | HTTP 302; target not requested |
| Local redirect followed | HTTP 200; target requested |
| Public HTTPS → public HTTP, rejected | HTTP 302 |
| Public HTTPS → public HTTP, followed | ATS error `-1022` |
| Public HTTPS → loopback attempts, reject/follow | HTTP 403 without redirect callback; inconclusive for that redirect path |

Both two-second pre-activation windows recorded zero local TCP accepts and HTTP
requests. The abort process never resumed its tasks. After activation the local
listeners recorded seven HTTP requests. This measures the instrumented local
listeners and harness, not all sockets, DNS, remote-server pre-activation traffic,
or production UI activation.

The full run sent synthetic diagnostic requests to third-party `httpbingo.org`.
That service was not operator-controlled. Its server can observe ordinary
network metadata; the requests did not submit page content. Saved artifacts
include local interface and server addresses. Response bodies were not saved.

**Interpretation:** local/private HTTP success cannot be generalized to public
DNS HTTP. A missing ATS exception does not replace an application destination
policy. These observations do not approve a new network route or establish
request isolation. R0 was not resolved, and R4 remains open.

Evidence: [10 harness assertions and transport events](../../../tools/markdown-preview-lab/transport/runs/verified/results.json),
[local server events](../../../tools/markdown-preview-lab/transport/runs/verified/server-events.json),
[full transport report](../../../tools/markdown-preview-lab/transport/runs/verified/report.md).

Remaining coverage includes macOS 13, the actual sandbox, operator-controlled
public-TLS redirects to local destinations, other networks/proxies, destination
admission, consent lifecycle, bounded image decoding, and production activation.

## 3. Attachment cell and accessibility prototype

### What ran

The isolated AppKit app constructs `NSTextStorage`, `NSLayoutManager`, and
`NSTextContainer` explicitly: TextKit 1, not a TextKit 2 view provider. It uses
synthetic attributed text and local counters/drawing for image-load actions.
There is no real image request or browser-open implementation. Table images,
linked images, and sealed stand-ins, including a stand-in in alt content, are
hand-built fixtures, not parser/native round trips.

The automated run completed **127/127 local checks**. A separate bounded
15-second GUI run opened and exited normally. Neither run was a manual
VoiceOver session. Runtime was macOS 27.2 on Apple Silicon; macOS 13 was not
exercised.

| ID | Observation | Evidence level / disposition |
| --- | --- | --- |
| AX-01 | Stock image and label-only attachment proxies advertised no default press action; direct press returned false. | In-process AppKit; label alone did not supply an action. |
| AX-02 | A cell-level `accessibilityPerformPress()` override made the native proxy advertise `AXPress`; proxy invocation dispatched to the cell counter. | In-process; candidate for external verification, not an adopted design. |
| AX-03 | Supplementary `NSAccessibilityElement` handlers, custom actions, hit testing and geometry worked locally, but added duplicate nodes: 19 children versus 10. | In-process; duplicate navigation needs resolution before adoption. |
| INPUT-01 | Synthetic click selection, keyboard selection/activation, and quiet-page promotion before a separate action followed the prototype's expected routes. | Synthetic input; physical input and VoiceOver untested. |
| FIXTURE-01 | Table attachments had nonempty geometry; sealed alt stand-ins remained separate before the image; simulated loading left the attributed string's text unchanged. | Hand-built text only; no copy/export, expiry, authorization or parser integration. |
| AX-05 | External helper reported trust false and `-25211` / `kAXErrorAPIDisabled`; zero target actions were externally performed. | Blocked by macOS accessibility permission. |
| VO-01 | Ready/final snapshots reported VoiceOver disabled. No speech, navigation, rotor or Actions-menu behavior was observed. | Manual VoiceOver verification remains open. |

An external attempt to press the already-denied application element also
returned `-25211`; it was not a successful attachment action. In-process proxy
results must not be reported as external accessibility or VoiceOver success.
The operator's permission concern is recorded above; further execution requires
advance context and approval, not an automatic grant/retry.

Evidence: [checks and app-side snapshots](../../../tools/markdown-preview-lab/attachment/runs/20261017T032134Z/app-report.json),
[external errors](../../../tools/markdown-preview-lab/attachment/runs/20261017T032134Z/external-ax.json),
[separate outcome statuses](../../../tools/markdown-preview-lab/attachment/runs/20261017T032134Z/outcome.json),
[GUI-run metadata](../../../tools/markdown-preview-lab/attachment/runs/20261017T032150Z/run.json),
and [attachment findings](../../../tools/markdown-preview-lab/attachment/RESULTS.md).

The [manual protocol](../../../tools/markdown-preview-lab/attachment/README.md#manual-voiceover-protocol--open--not-performed)
separates expected behavior from observations. Pending operator approval, it can
record actual spoken labels, action-menu exposure, reading order, focus,
nonselected-page promotion, and linked/table-image behavior. R5 also needs real
lifecycle, multiselection/copy, geometry/scroll and stale-result tests.

## Reproduction and follow-up

Commands below were executed during the original experiments, from the
repository root. Bootstrap, original fixture execution, transport, and attachment
runs were **not repeated** for the continuation. The eight original parser lab
unit tests passed again before commit `41266668`; the separate offline supplement
commands and results are recorded above.

Parser bootstrap downloads pinned upstream sources and official examples;
subsequent fixture/unit runs are offline. Build output stays in the lab:

```sh
python3 tools/markdown-preview-lab/parser/bootstrap.py
python3 tools/markdown-preview-lab/parser/run.py
python3 -B -m unittest discover -s tools/markdown-preview-lab/parser -p test_lab.py -v
```

The transport driver builds/signs a temporary bundle, starts bounded local
servers, and makes external diagnostic requests. A fresh output directory is
required. Obtain operator approval before running it:

```sh
python3 tools/markdown-preview-lab/transport/run.py --output runs/repro
```

The attachment driver launches a macOS app and an external accessibility client;
it is **not a headless unit-test command**. Obtain operator approval before
running it; no administrator or accessibility grant is needed to read the
existing evidence:

```sh
python3 tools/markdown-preview-lab/attachment/repro.py
```

### Research disposition

| Area | Disposition | Next evidence needed |
| --- | --- | --- |
| P01–P07 | Recorded; design deferred | Per-dialect object representation and integrated identity/order fixtures |
| C01–C07 | Recorded in offline supplement; adoption deferred | Swift/native integration and reviewed attribute/span/dialect choices |
| Official corpus deviations | Recorded; unresolved | Review each structural/configuration difference before selecting GFM contract |
| Transport distinction and activation | Recorded for harness only | Actual sandbox/runtime and approved destination/consent policy tests |
| AX-01–AX-03 | Recorded; adoption deferred | Approved external AX and operator-observed VoiceOver session; duplicate-node resolution |
| INPUT-01 / FIXTURE-01 | Recorded for synthetic fixtures only | Physical input, actual renderer, copy/lifecycle/scroll tests |
| AX-05 / VO-01 | Blocked / not performed | Explicit operator decision before any further UI or permission-sensitive test |
| R0, R2, full R3, R6 | Outside these experiments | Separate policy/surface/composition/integrated investigations |

The three prototypes have not been integrated. No full parser, image-loader,
or attachment architecture is selected by these results.
