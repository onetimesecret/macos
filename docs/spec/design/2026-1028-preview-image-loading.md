---
id: 2026-1028-preview-image-loading
title: Explicit image loading in Markdown previews
status: proposed
dated: 2026-10-28
surfaces: OnetimePad rendered Markdown previews
---

# Explicit image loading in Markdown previews

## Scope and authority

PR D of #332 proposes the request and interaction policy below. These details
are implementation choices for review, not an accepted privacy guarantee.
The earlier [Markdown preview design](2026-1016-markdown-dialects-and-preview.md)
records the agreed direction exactly: “remote images load only after an
explicit click.” Its technical image-policy decisions remain open.

The accepted [Law 0001, AppKit text routes](../../law/0001-sealed-object.md#appkits-text-routes)
states exactly: “the rendered text between the objects is the ink, never the
source markdown, and each object goes by reference, in rendered order”. It
also states exactly: “no drag starts from a preview, with an object in the
selection or not”. Those existing requirements constrain the preview's
copying and dragging routes; they do not establish a policy for image requests.

## Proposed interaction and lifetime

Controls shorten spoken alt labels to 240 Unicode scalars plus an ellipsis when
needed. The complete alt text remains in the rendered page and its copied ink.

Decorative images still reserve a control row and can produce a paragraph
break. AppKit's underlying value includes a nonprinting marker and attachment
positions; native Find and accessibility value routes can expose those
positions. The preview's copy and Services composition filters them out.

- Markdown images and supported HTML `img` elements retain their alt text.
  An empty alt adds no visible or copied text. A separate native button displays **Load
  image** and the destination hostname. The tooltip and accessibility help
  provide the full request URL and request-policy summary.
- Only a selected preview in its owning presentation can start a request.
  Clicking an unselected preview promotes its page; promotion itself does
  not load an image. Each image occurrence needs its own activation, even
  when two occurrences use the same address.
- Loading changes the button to **Cancel image**. A successful request shows
  the decoded image beside the alt text and offers **Unload image**. A failed
  request offers **Retry image**, with the error in its tooltip and
  accessibility help. Retry requires another activation.
- Opening, scrolling, selecting, resizing, or changing dialect does not start
  a request. There is no load-all action or persistent authorization setting.
- Source/rendering replacement, dialect changes, deselection, ownership
  transfer, preview removal and window detachment cancel requests and discard
  decoded images. Completion checks the page's existing read gate again;
  cancelled or obsolete completions are not installed.
- Copy and Services compose the rendered alt text and sealed references.
  Buttons and loaded image attachments contribute no image bytes or source
  URLs. Loaded images do not become sealed objects or new drag sources.
- The first 32 image occurrences have controls. Later occurrences keep their
  alt text. At most four images can be loading or loaded in the selected
  preview; cancel or unload one to make another available.

## Proposed request policy

| Concern | PR D choice |
| --- | --- |
| Destination | Absolute HTTPS URL, ASCII DNS hostname, standard HTTPS port; no URL username/password. The scheme and validated hostname is written back in lowercase. Fragments and explicit port 443 are removed. Internationalized names, including punycode input, are unavailable. |
| Unsupported destinations | Relative paths, file/data/HTTP URLs, IP literals, single-label hosts and local/reserved hostname suffixes have disabled controls. |
| Consent boundary | One activation authorizes one image occurrence at the displayed URL. The full URL, including its query, goes to that server. |
| Request | GET, image Accept header, no Referer; User-Agent `OnetimePad-ImagePreview` and Accept-Language `*`. Ephemeral URLSession with cookie handling, URL cache and credential storage disabled. No application API token or page content is added. |
| Redirects | Refused, including redirects within the same host. No second destination is requested. |
| Authentication | Credential challenges are refused; ordinary platform TLS server-trust evaluation remains enabled. |
| DNS and connected peer | The system resolves the approved hostname. Private, loopback, link-local and split-horizon answers are permitted when the platform accepts the hostname's TLS certificate. There is no DNS preflight or connected-peer filter. The control's help discloses local-network routing before activation. |
| Proxies and relays | System routing, including configured proxies, is retained. The app does not force a direct route or supply proxy credentials. A proxy credential challenge is refused. |
| Transfer bounds | 15 seconds; 5 MiB maximum advertised Content-Length and maximum data delivered to the application, including responses without a Content-Length. Encoded response length and delivered data are checked separately. |
| Response | HTTP 200 and PNG, JPEG or GIF MIME type; ImageIO must also recognize one of those formats. |
| Decode bounds | Maximum side 8192 pixels and area 16 million pixels before decoding; thumbnail output at most 1600 pixels per side. A shared serial actor decodes away from the main actor. An 8-bit RGBA frame of that area is about 64 MB; higher bit depths and decoder work buffers can use more. GIF uses its first frame without animation. |
| Display | Decoded pixel dimensions are divided by the window backing scale (240 by 120 pixels becomes 120 by 60 points on a 2x display), then scaled down to the available preview or table-cell width and at most 400 points tall. Backing-scale changes remeasure the image. |
| Cache | No application disk cache or cross-preview image cache; decoded pixels belong to the current preview interaction. |
| Failures | No automatic retry, redirects, authentication prompts or fallback browser opening. |

Hostname checks do not inspect DNS answers. An accepted hostname may resolve
to a local address; this policy does not promise public-network routing or
anonymity. An authorized server observes the request URL and ordinary network
and TLS metadata. Platform DNS/TLS behavior is outside the application cache
choice above. SVG, WebP, PDF, local files and repository-relative images are
outside this slice.


## Routing decision after PR D

This follow-up proposes explicit URL authorization with system routing, rather
than public-address-only authorization. A page may name a publicly shaped
hostname whose system DNS answer is private or link-local, including on a VPN
or a split-horizon network. Clicking its control authorizes that URL under the
same TLS, redirect, authentication and transfer restrictions above. A bare
private IP URL or local-name URL remains unavailable. The hostname restriction
is an address-syntax restriction, not a network boundary.

The full destination and the following summary are available in the button's
tooltip and accessibility help before activation:

> One HTTPS image request using system DNS and proxies. The hostname may reach a local network. No redirects, cookies, or saved credentials.

The alternative, a public-only connected-peer rule, is outside this proposal.
A DNS preflight could inspect a different answer from the connection's answer,
and an after-response metric cannot retract the request. Apple describes
[`remoteAddress`](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/remoteaddress)
exactly as “The IP address string of the remote interface for the connection.”
Its [task metrics documentation](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics)
states exactly: “the remoteAddress property contains the address of the proxy,
and not the origin server.” A proxy peer therefore cannot establish the origin's
address class. These API descriptions inform this implementation decision;
they do not establish an application privacy guarantee.

The production configuration leaves proxy selection to the platform. Apple's
[`connectionProxyDictionary` documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary)
states exactly: “The default value is NULL, which means that tasks use the
default system settings.” The app does not add a DNS query, log peer addresses,
or add a fallback direct request after a proxy failure. Future public-only
behavior would require a separately reviewed transport that binds validation
to the actual origin connection, including its proxy policy.

## Validation and remaining review

Deterministic loader tests intercept requests with URLProtocol. Mounted
preview tests use temporary state directories and the test-util in-memory
credential client through `PageModel.Seams`. They exercise consent, lifecycle
changes, response and resource refusals, rendered copying and sealed-reference
order without contacting external image servers.

Native bitmap checks assess layout only. Spoken VoiceOver announcements,
keyboard navigation with system accessibility settings and minimum-window
interaction still need a human pass. The opt-in socket suite described in
[the QA record](../../qa/markdown-image-loading.md#routing-policy-follow-up)
covers a successful public HTTPS image through a loopback proxy, proxy
credential refusal and local untrusted-certificate refusal. It does not certify
a trusted private-origin or split-horizon deployment. Automated checks do not
certify spoken output.
