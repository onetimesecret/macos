# Markdown image loading: review and validation scope

PR D is [#336](https://github.com/onetimesecret/macos/pull/336), based on
`b5240e27`. The [request policy](../spec/design/2026-1028-preview-image-loading.md)
is proposed for review. This record describes implementation observations
and validation scope; it does not establish new project requirements.

## First Claude review dispositions

The review on `56398375` identified the following work:

| Item | Disposition |
| --- | --- |
| 1: Main-thread decoding and transient pixels | ImageIO decoding uses a shared serial actor. NSImage installation returns to the main actor. The policy records the retained 16-million-pixel ceiling and approximate RGBA frame size. |
| 2: Replacing the whole storage during resize | Each image has two stable attachment positions. Load, unload and resize update attachment attributes at those positions; full storage replacement is restricted to seeding. |
| 3: Selection and reading-place drift | Image state changes preserve the text's UTF-16 positions. Regression tests track selection, a sentinel outside image ranges and a restored reading line through loading, unloading and resizing. |
| 4: Special-use hostnames and port spelling | The policy refuses the ARPA suffix and normalizes explicit port 443. Foundation's decoded hostname behavior is tested: Unicode and punycode internationalized names are currently unavailable. |
| 5: Default request headers | Requests explicitly set User-Agent to OnetimePad-ImagePreview and Accept-Language to a wildcard. Tests inspect both values. |
| 6: English localization entries | Image strings have English resource entries and semantic format keys for action/destination and accessibility labels. |
| 7: Mutable shipping loader seam | A defaulted PageModel.Seams initializer argument resolves once to an immutable model loader, then to the controls' immutable initializer dependency. The mutable recorder exists only in the test target. |
| 8: Consent based only on plain text | Consent preservation compares descriptor destinations, occurrences and ranges. Tests change the destination or image range while keeping rendered text identical. |
| 9: Decorative alt text entering copies | Empty alt text uses a nonprinting position marker solely for locating its control; that marker is excluded from copied ink. It adds no visible synthetic alt text. |
| 10: Keyboard and VoiceOver navigation | Human validation remains outstanding, including Tab/Space with the person's keyboard-navigation settings, the image buttons' reading order, and announcement of loading/failure states. Automated metadata checks do not certify those interactions. |
| 11: Remeasurement during a layout pass | Image state changes schedule roll remeasurement on the next main-actor turn instead of dropping it when a layout is already active. |

The lock is released before resuming the URLSession task; descriptor enumeration
stops at the control budget; configuration copies have a fallback rather than
forced casts. The pixel comparison retains division after positive dimensions
are established. Fixed-width, middle-truncated buttons retain the complete
destination in their tooltip and accessibility help.

## Updated Claude review dispositions

The two reviews of `f7f57df1` raised the same follow-ups. The request URL now
uses the exact validated, lowercased ASCII hostname; intercepted transport
tests include percent-encoded host spelling. Discarding pixels requests a
deferred remeasurement and accessibility layout notification. Ownership and
window state determine whether controls are enabled, without running the
page's settling read gate during layout; an attempted expired-page load
uses the existing refusal line and then disables the control.

The loader dependency is captured at preview initialization. Accessibility
hit tests outside the main thread fall back to AppKit. A reentrant image
presentation requests another pass, and a generation-matched task completion
releases any remaining capacity reservation. Tests cover direct discard
height, expiry feedback, self-cancellation and reentrant discard.

The decorative-image paragraph and underlying AppKit marker positions are
documented in the proposed policy. Source image pixels are treated as points
before fitting to display bounds. The transfer policy distinguishes the
advertised length from data delivered to the application. TextProv marks
are intentional and retained. Mounted previews seed their controls before
teardown; the teardown accessor does not add a new load route.

## Final Claude review dispositions

The review of `66597eb8` found no blocking defect. Resize presentation is
coalesced onto a later main-actor turn, and closing a retained window cancels
its image work. Entry destruction also cancels its task. Idle discard updates
button eligibility without an unnecessary roll pass or accessibility layout
announcement. Approved addresses and spoken labels are cached at seeding;
spoken alt labels are capped while the complete rendered alt remains available.

Invalid storage ranges hide the associated buttons. The conservative hostname
policy also refuses onion, i2p, alt and localdomain suffixes. The synchronous
decode fixture lives in the test target, and the side-effecting action check
is named authorizeImageLoad. TextProv marks remain intentional. Decorative
control rows still require the planned human UX pass.

Platform TLS-version, connectivity and network-cost defaults remain unchanged.
The production loader uses an ephemeral configuration; URLProtocol injection
supports deterministic tests. No broader guarantee about arbitrary in-process
configuration is proposed.

## Small final review follow-ups

The review of `3b2d8d01` found no individual merge blocker. ACE-prefixed
hostname labels are now explicitly refused, empty-image previews skip resize
work, and hidden controls are excluded from accessibility children and hit
testing. Head truncation preserves the destination suffix in narrow controls.
The no-coordinator loader refuses requests, and identical image sources avoid
copying their rendered string before a template reuse.

Window notifications keep a weak-window match to avoid coupling the window's
lifetime to its publisher filter. The no-image early return removes image
layout and accessibility announcements for ordinary previews. Fixed control
metrics and button traversal order remain part of the human validation scope.

<a id="routing-policy-follow-up"></a>

### Routing policy follow-up

The [proposed routing decision](../spec/design/2026-1028-preview-image-loading.md#routing-decision-after-pr-d)
uses the system's DNS and proxy routing after explicit URL activation. Private,
loopback, link-local and split-horizon DNS answers are permitted when platform
TLS evaluation succeeds. Local-name URLs and IP-literal URLs remain refused.
The control's pre-activation tooltip and accessibility help now explicitly say
that the hostname may reach a local network. Refusal copy distinguishes URL
syntax from DNS routing. Scheme spelling is canonicalized to lowercase.

There is no DNS preflight, post-response address filter, origin-IP assertion
from proxy metrics, or automatic direct fallback. Public-only routing is not
implemented or promised. The design links the primary Apple API descriptions
that informed this proposal, without treating this QA record as authority for
an application guarantee.

`PREVIEW_NETWORK_TESTS=1 scripts/test-shell.sh --filter PreviewImageNetworkTests`
runs opt-in real-socket coverage. A temporary loopback CONNECT proxy tests proxy
authentication refusal without a credential, refusal of an untrusted local TLS
certificate, and successful PNG loading through a proxy tunnel to a public
HTTPS origin with unchanged platform trust. It neither changes system proxy
settings nor installs certificates. The fixtures use temporary files and a
single loopback listener, and remove their temporary key and certificate.

A successful private-origin load requires an endpoint with a certificate the
platform already trusts. The local self-signed fixture exercises refusal,
not acceptance of such a certificate; no shipping TLS bypass is introduced
to manufacture that positive result. Split-horizon or trusted-private-origin
acceptance still needs that controlled endpoint. The public proxy tunnel test
requires internet access and is opt-in, so ordinary unit runs stay deterministic.

## Automated scope

The opt-in socket suite passed all three cases locally on 2026-10-29, using
the unchanged platform TLS handling in `PreviewImageLoader`. The private-origin
acceptance limitation above remains; a positive public-origin proxy test does
not certify a trusted private-origin deployment.

Run `scripts/test-shell.sh` for the full Swift suite. The image suites and
existing preview suites cover intercepted HTTP responses, serial decoding,
explicit per-occurrence loading, cancellation and stale completions,
ownership/expiry refusals, resource limits, style/width refreshes, rendered
copying and sealed-reference order. Test models inject temporary state
directories and test-util in-memory credential clients.

`PREVIEW_QA_ARTIFACTS` optionally saves native light/dark bitmaps at 320 and
640 points, using synthetic images. These are layout checks, not evidence of
real network/TLS behavior or spoken accessibility output. Exact-head test and
CI results are recorded in the PR description.

## Human validation still required before merge

- Load, cancel, retry and unload an authorized test image; confirm the complete
  destination can be inspected before activation.
- Exercise keyboard navigation and VoiceOver reading order and announcements,
  including decorative images, disabled controls, failures and narrow table
  cells.
- Check resize, selection, copy and reading-position behavior in an isolated
  test host. Do not use or replace a person's running app for a probe.
- Exercise real TLS success, redirect refusal and authentication refusal with
  controlled endpoints; the automated network tests use URLProtocol.
