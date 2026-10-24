---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0059: Preview images use an explicit resource-request route

- **Status:** accepted
- **Date:** 2026-10-16
- **Supersedes in part:** [ADR-0023](0023-hybrid-link-affordance-cmd-click-opens.md), the Consequences bullet beginning “Opening is deliberate”; [ADR-0030](0030-visible-pages-share-preview-rendering.md), the Decision paragraph beginning “Preview rendering remains markup-preserving” and the Consequences bullet beginning “The setting changes presentation only”. ADR-0030's partial supersession clarifies surface scope only; it does not expand that record's runtime network scope. The source text, existing link behavior and pure display-refresh semantics remain unchanged.
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md) and [ADR-0027](0027-account-auth-gates-the-sync-channel.md) for the unchanged sync/auth routes; [ADR-0055](0055-menus-and-buttons-use-the-platforms-wording.md) for button wording.

## Context

The maintainer's 2026-10-16 instruction, “Please enact the recommended document amendments”, accepts this narrow reconciliation. The approved feature scope is a CommonMark/GFM picker, GFM by default, restricted native HTML without scripts or embedded browser content, and explicitly loaded remote images. The [technical plan](../spec/design/2026-1016-markdown-dialects-and-preview.md) remains draft for parser, transport and interaction details. Neither that plan nor experiments establish acceptance of those details or tested runtime behavior.

### Prior authority and the conflict

These quotations identify the prior rules being preserved or narrowed, not evidence that the new route is implemented:

- The previously accepted [2026-0915 UI/UX record](../spec/design/2026-0915-ui-ux-decisions.md#3--sealed-content-and-the-conceal-flow), now superseded in full by the [companion successor](../spec/design/2026-1016-ui-ux-decisions.md), stated at D-09:

  > Concealing is the app's one network outbound action:

  > The confirming click is the network boundary and
  > the destination is always named.

  Its review correction in section 10 states:

  > D-09's one outbound action means one network action and does not
  > contradict D-32's three egresses

- The [design index](../spec/design/README.md#foundational-design-reading-order) identifies the design principles as binding, as amended. Before the newly enacted Amendment E, the original wording of [principle 3](../spec/design/2026-0707-design-principles.md#3-content-plays-second-fiddle) stated:

  > No rich previews, no syntax highlighting, no image
  > zoom. Recognition, not consumption.

  [Principle 6](../spec/design/2026-0707-design-principles.md#6-escalate-deliberately) stated:

  > Every
  > destination is one the user enrolled and can see.

  [Principle 5](../spec/design/2026-0707-design-principles.md#5-trust-through-legibility) limited departure from the machine to:

  > only on an explicit conceal, or to a device the user enrolled, and the
  > UI makes that boundary visible

  Interpretation of the prior wording: restricted rendered previews need an explicit exception to §3, and document-provided image destinations do not fit an app-wide enrollment requirement. Activating a resource is not device enrollment. The newly adopted exceptions are recorded below, not inferred from runtime behavior.

- Accepted [ADR-0021, Consequences](0021-multi-device-sync-over-a-blind-relay.md#consequences), states:

  > The relay is a second allowed TLS destination.

  > A compromised relay sees account identity, device identifiers and attachment
  > times, traffic timing and sizes, ceremony times, and encrypted frame size.

  Its Decision states:

  > Account authentication permits attachment to a channel; it does not establish
  > device trust.

  Accepted [ADR-0027, Decision](0027-account-auth-gates-the-sync-channel.md#decision), states:

  > Use OAuth 2.0 authorization code with PKCE in the system browser.

  These already accepted routes cannot be reconciled by treating D-09 as a complete app-wide request inventory.

- Accepted [ADR-0023, Consequences](0023-hybrid-link-affordance-cmd-click-opens.md#consequences), states:

  > Opening is deliberate and therefore auditable as a gesture: nothing
  > leaves the app because a click landed a pixel too far left.

  Accepted [Law 0001's preview-link row](../law/0001-sealed-object.md#appkits-text-routes) states:

  > a plain click opens nothing

- Accepted [ADR-0030, Decision](0030-visible-pages-share-preview-rendering.md#decision), states:

  > Preview rendering remains markup-preserving.

  > Every rendering input must invalidate affected quiet renderings: page content,
  > typeface, preview scope, syntax-highlighting state, and page-owned manual or
  > inferred language state.

  > A visible refresh must remeasure the roll and publish
  > updated geometry so the rail minimap retains truthful proportions.

  Its Consequences state:

  > no new content crosses a process or network
  > boundary.

  Interpretation: display refresh is not request authorization. The same word, preview, has been used for two different surfaces.

- Accepted [Law 0001, The rule](../law/0001-sealed-object.md#the-rule), states:

  > A sealed item occupies one position in the document, but its plaintext is
  > not part of the document's ambient text.

  Its existing [AppKit text routes](../law/0001-sealed-object.md#appkits-text-routes) require:

  > every reader the rows above sort as asking first asks the preview's page

  > a click promotes its page

  The preview-copy row states:

  > the rendered text between the objects is the ink, never the source markdown, and each object goes by reference, in rendered order

- [ADR-0012, Amendment 1](0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval), is accepted and enumerates copy decrypted, decrypted drag and promotion to a one-time link as three complete-payload egresses. It states:

  > The ledger's `sent` record keeps its shape.

  Its [Decision history](0012-framing-threat-boundary-and-persistence-model.md#decision-history) explicitly says:

  > This remains the proposed base record.

  Acceptance of that amendment is not acceptance of the entire base record.

- Accepted [ADR-0055, Decision](0055-menus-and-buttons-use-the-platforms-wording.md#decision), states:

  > Menu items and buttons are title case: every word capitalised but
  > articles, coordinating conjunctions and prepositions of four letters
  > or fewer, unless first or last.

  The image-load button is therefore titled **Load Image**.

### Bounded route inventory

This inventory covers the five routes relevant to reconciliation, not every endpoint or all current network traffic. Information below distinguishes accepted policy from static code observations and historical draft wording; no request trace was run for this ADR. Ordinary link opening remains a separate existing action, not an image fetch.

| Route and evidence status | Action and destination | Information sent or exposed | Activation / authority and remaining gap |
| --- | --- | --- | --- |
| Conceal: D-09, preserved by the companion UI/UX successor, and accepted Law 0001's promote-the-whole-page row; request construction observed in [`Api.conceal_request` and `guest_conceal_request`](../../crates/ots-client/src/api.rs) | Promote sealed content or a page to a one-time link at the configured OTS server; code builds `/api/v3/secret/conceal` or `/api/v3/guest/secret/conceal`. | Complete payload and conceal options; authenticated request construction applies its auth strategy. | Explicit confirmation names the destination; D-09 and [Law 0001](../law/0001-sealed-object.md#the-contract) govern this route. This ADR narrows its exclusivity, not its confirmation or payload rules. Code is not evidence of runtime enforcement. |
| Sync/auth: accepted ADR-0021 and ADR-0027; [account-auth specification](../spec/feature/sync/account-auth.md) supplies flow detail subordinate to ADR-0027 | Opt-in page sync to the configured relay; account sign-in through the OTS authorization server/system browser, token exchange and refresh, with a local loopback callback. | ADR-0021 specifies encrypted frames/deltas and relay-visible account identity, device identifiers, timing and sizes; ADR-0027 specifies PKCE account admission and access/refresh tokens, separate from device trust. | Existing sync opt-in, pairing and account-auth authority remains unchanged. Background sync and refresh do not require a conceal click. This row is not an exhaustive endpoint/header inventory or new approval for other traffic. |
| Feedback: code observation only, [`FeedbackClient.swift`](../../shell/Sources/CompanionKit/FeedbackClient.swift) and [`FeedbackDraft`](../../shell/Sources/OnetimePad/FeedbackWindowController.swift) | `send` posts to the configured server's `/api/v3/feedback`; the draft exposes that destination. | URL-encoded `msg` and `tz`; the draft can include diagnostic details, and a supplied contact address is appended to the report text. | Code exposes Send and a diagnostics choice, initially enabled. No accepted route exception was identified in this bounded review; authority remains unresolved. This decision does not retroactively approve the request or its defaults. |
| Release feed: historical draft evidence only, [Technical Direction, Security posture](../spec/design/2026-0707-technical-direction.md#security-posture) | The draft mentions a launch-time release-feed check. Destination and executable route were not established by this bounded review. | Request URL, headers and other metadata are not established; neither are server-side observations. | No accepted authority, exact activation policy or current runtime evidence was identified. The [design index](../spec/design/README.md#reading-historical-security-claims) says: “It is not a verified inventory of current network traffic.” This ADR does not approve the check. |
| Preview images: newly accepted policy in this Decision; current [`MarkdownPreviewRenderer.inline`](../../shell/Sources/CompanionKit/MarkdownPreviewView.swift) emits image children as text, not a loader | Separate **Load Image** action requests the image from the resource provider identified by the document address. | The resource URL and request metadata are exposed to the recipient; exact session/header, intermediary and redirect exposure remains R4 work. | Separate visible authorization, originating-page gates and nonselected-page promotion apply below. No shipped image loader or validated isolation result is asserted; R4/R5 block production wiring. |

## Decision

Authorize remote preview images through a separate, explicit resource-request route, never through parsing, rendering or display refresh. This is an accepted policy boundary, not a selected parser, transport implementation or completed interaction design.

### Authorization and destination

1. Markdown and supported HTML images use the same resource-request policy. Parsing, HTML conversion, rendering, styling, opening, scrolling, resizing, reparsing and cache refresh must not dispatch image requests. Resource-bearing HTML/CSS constructs must not bypass this boundary; their supported subset remains R3/R4 work.
2. Provide a distinct **Load Image** control with its destination visible before activation. The recipient is the image resource provider identified by the document address, not necessarily the OTS server or an enrolled device. Before authorization, explain that the request exposes the resource URL and request metadata. The URL itself may contain sensitive visible text; an authorized request is not anonymous. Any intermediary requires explicit policy and destination disclosure. This decision selects neither direct fetching nor a proxy.
3. Authorization is separate from displaying a page or following a link. Ordinary clicks on plain text, links and image bodies do not load images. On a nonselected page, the first activation only promotes that page; loading needs a separate activation after promotion. A linked image has separate load and open targets. Preserve ⌘-click link opening and existing aimed-link routes; do not repurpose a link click as consent to fetch its image.
4. Pointer, keyboard and VoiceOver activation use the same resource route and originating-page, deadline and key-ownership gates as preview readers under Law 0001. A name field or the note owning the keys blocks the page action as it blocks those readers. Ask the originating page, not whichever page is selected later; a page past its deadline cannot authorize dispatch or publication of an image result. R4/R5 must specify and test the gates across dispatch, retry, any permitted redirect and completion. Exact gestures, focus presentation and accessibility mechanics remain R5 work; this decision does not require ⌘ on the separate load control.
5. Reject every resource address containing a sealed object or its parser placeholder, including addresses derived from HTML attributes or CSS. Do not resolve a sealed payload to construct a request. Sealed objects inside alt text remain objects by reference in rendered order under Law 0001's existing copy contract, before loading and in every later image state. R1/R3/R5 must define parsing, visible placement, copy text and accessibility without dropping or reordering those objects. A loaded image does not replace an alt-text object with payload or erase its document position.

### Reconciliation and unchanged scope

- **D-09:** exclusivity now concerns promotion of sealed payloads to one-time links, not all app network actions. Its confirming action and named destination remain required. This ADR, the companion [2026-1016 UI/UX successor](../spec/design/2026-1016-ui-ux-decisions.md), [Law 0001's resource-request amendment](../law/0001-sealed-object.md#appkits-text-routes) and [design principles Amendment E](../spec/design/2026-0707-design-principles.md#amendment-e--restricted-page-preview-and-explicit-resources-2026-10-16) jointly enact R0's authority reconciliation. The successor supersedes the 2026-0915 UI/UX record in full, preserving unchanged decisions and intervening amendments; the law supplies the companion route contract. These records express adopted decisions, not runtime evidence.
- **Design principles §§3, 5 and 6:** this decision and Amendment E add only the approved restricted-preview/resource exceptions. §3 permits the approved dialects, restricted native HTML formatting and explicitly loaded remote images on the separate rendered page preview. This exception does not extend to source styling, sealed-payload representation, chips, the ledger, the minimap or other recognition surfaces; their existing rules remain unchanged. §§5–6 add only the preview-resource exception to their conceal/enrollment wording: a visible document-provided destination separately authorized for an image request need not be an enrolled sync destination. Resource authorization does not enroll a device, grant sync trust, permit page replication or grant a general destination exception. The accepted sync/auth routes retain ADR-0021/ADR-0027's authority. Feedback and release-feed gaps above remain unresolved rather than approved by association.
- **ADR-0023:** partially supersede only the Consequences bullet beginning “Opening is deliberate”, narrowing its app-wide reading: a distinct resource control may authorize the disclosed request. Its editable-ink link detection, plain-click editing and ⌘-click opening remain unchanged; the law's preview-link behavior remains unchanged too. Plain image-body clicks are not an exception.
- **ADR-0030:** partially supersede only the Decision paragraph beginning “Preview rendering remains markup-preserving” and the Consequences bullet beginning “The setting changes presentation only”, solely to clarify surface scope. Name its surface **markup-preserving editor styling**, covering mounted and quiet pages, distinct from the syntax-removing **rendered page preview** governed by Law 0001. Preserve the original text; this clarification does not expand ADR-0030's runtime network scope. Existing byte preservation, preference scopes, pure display refresh, cache invalidation, geometry publication and nonselected-page promotion remain unchanged; none authorizes a resource request. R2 must settle the dialect/header-toggle/scope matrix without assuming these are one renderer. Image-size changes must publish updated layout/roll geometry, separately from request authorization.
- **Ledger:** image requests are not complete sealed-payload egresses and must not create or reuse the existing lifecycle ledger's `sent` event. Do not store image URLs, alt text or response details as existing `sent` metadata. Any request audit requires a separate accepted decision defining event meaning, attempt/success timing, identity, fields and retention. This exclusion does not settle operational transport logging or caching; those remain R4 questions.

### Required technical decisions before production

The [plan's R4/R5 gates](../spec/design/2026-1016-markdown-dialects-and-preview.md#delivery-workstreams-and-verification) must complete before production image wiring. R4 must settle session/credential/cookie/referrer/header behavior, schemes and ATS, redirects and destination reauthorization, private-network/loopback and relative-address rules, intermediary policy, cache/storage/logging, timeout/concurrency and streamed-byte limits, MIME validation, format support, decoding and decoded-size limits. R5 must settle exact pointer/keyboard/VoiceOver gestures, consent scope and lifetime, request identity, retries and invalidation, stale-result rejection, all image states, alt-text/object copy behavior, layout and scroll anchoring. Numeric limits and cache/decoding lifetime are not selected here. An existing ephemeral session or transport allowlist is not evidence that these obligations are met.

R1–R3 still require reviewed parser, surface and HTML-composition contracts; R6 still requires integrated release evidence. Joint R0 enactment supplies route authority only. It does not select the technical architecture, finalize R4/R5 or establish production readiness.

## Consequences

- The approved image feature has a specific authority boundary without converting rendering or link navigation into consent.
- Document-selected resource providers differ from enrolled sync recipients. Pre-activation disclosure must make the recipient and authorized exposure understandable; no anonymity guarantee follows from an explicit action.
- Authorization/request state cannot be inferred from a disposable render cache. Its detailed identity and lifetime remain to be designed and tested in R4/R5.
- The existing `sent` lifecycle event keeps its complete-payload meaning; a request-audit feature would be separate work.
- This inventory exposes feedback/release authority gaps without treating draft survey wording or code as acceptance. It is deliberately not a complete traffic inventory.
- This ADR, the companion UI/UX successor, law amendment and principles Amendment E jointly enact R0. No runtime implementation or new request-isolation evidence accompanies that authority decision.

## Eject triggers

- R5 pointer, keyboard or VoiceOver tests show that users cannot distinguish image loading from link opening or page promotion. Revisit control presentation or exact gestures before release, not the separate authorization boundary.
- R4 transport experiments identify an unavoidable recipient or metadata exposure absent from the pre-activation disclosure. Revisit the route/destination policy before production use.
- A requested transport, automatic-loading mode or request-audit feature needs authority beyond this bounded route. Record a successor decision rather than infer permission from the existence of image loading.

## Decision history

- 2026-10-16: Accepted by explicit maintainer instruction to enact the recommended documentation amendments. Partially supersedes ADR-0023 and ADR-0030 only as named above; jointly enacts R0 with the UI/UX successor, Law 0001 amendment and principles Amendment E's narrow §§3, 5 and 6 exceptions. Integrated documentation review checked source quotations, unchanged historical bodies, reciprocal relationships and local links. Parser, transport and exact interaction details remain open; no runtime validation is recorded.
