---
id: 2026-1016-markdown-dialects-and-preview
title: Markdown dialects and restricted preview
status: draft
dated: 2026-10-16
surfaces: OnetimePad Markdown preview and Settings
---

# Markdown dialects and restricted preview

## Status and scope authority

This is an operator-initiated improvement. The maintainer approved the
following direction in the design conversation on 2026-10-16: CommonMark
and GitHub Flavored Markdown are selectable in Settings; GFM is the default;
supported HTML formatting renders without scripts or embedded browser
content; remote images load only after an explicit click. The approval was:
“Yes agreed. Please capture the plan at docs/spec/design”. The maintainer
reconfirmed on 2026-10-16 that the work is operator-initiated.

The maintainer reconfirmed that the concept is wholly approved and its
implementation details are not finalized. The draft status applies to the
technical details, research gates and open decisions, not to whether the
feature is wanted. Target requirements below are not a description of shipped
behavior or evidence of validated guarantees. The maintainer subsequently
instructed enactment of the recommended document amendments. The accepted
[UI/UX successor](2026-1016-ui-ux-decisions.md),
[ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md)
and [Law 0001 amendment](../../law/0001-sealed-object.md#amendments) enact R0's
policy reconciliation. This plan remains draft for R1–R6 technical work; it
does not independently amend those accepted records or report runtime validation.

The enacted reconciliation updates the older decisions for the approved scope;
it does not reopen dialect selection, restricted HTML or explicitly activated
remote images. Removing images would require a new maintainer scope decision,
not merely an unresolved reconciliation gate.

## Summary

The target Markdown preview supports CommonMark and GitHub Flavored Markdown
(GFM), selected through a Markdown dialect setting. The selection changes
parsing semantics, not merely visual styling. Both dialects use a restricted
preview with supported HTML formatting and click-to-load remote images.

## Implementation-readiness assessment

**Ready for bounded experiments, not full implementation.** A settings picker
is straightforward; parser semantics, HTML composition, and image state are
architectural prerequisites. An allowlist and a click handler alone do not
resolve them. R0's policy reconciliation is accepted; complete gates R1–R5
below before selecting the full design, and R6 before delivery. No experiment
results are recorded here.

The principal corrections are to separate parser conformance from restricted
native output, specify how sealed-object placeholders participate in parsing,
design HTML composition before rendering individual HTML leaves, and separate
image authorization/request state from render caches. The accepted successor
replaces D-09's former app-wide network-action count, and ADR-0059 supplies the
separate resource-route authority. This closes the policy contradiction, not
the parser, request-policy or interaction work.

## Goals and non-goals

Goals:

- The reader chooses the interpretation appropriate to the document.
- CommonMark syntax and GFM extensions produce distinguishable, testable results.
- Open previews reflect a dialect change without a relaunch.
- HTML formatting and images have explicit rendering and loading boundaries.

Non-goals:

- Unrestricted HTML or an embedded browser surface.
- Scripts, executable content, or automatic remote-image loading.
- GitHub product features beyond the GFM specification, such as issue
  references, mentions, or repository-relative URL resolution.
- A universal Markdown mode encompassing unrelated extensions. Math,
  diagrams, footnotes, and code syntax highlighting are not added by this
  agreement; any additional support needs its own scope decision.

## Agreed target behavior

### Dialect setting

The user-facing location is **Settings → Code → Markdown dialect**,
beside the existing preview controls. The current tab is named **Code**, not
Editor; this plan does not authorize renaming or reorganizing Settings.
The options are **CommonMark** and **GitHub Flavored Markdown**, with GFM as
the default.

| Syntax | CommonMark | GitHub Flavored Markdown |
| --- | --- | --- |
| Headings, paragraphs, emphasis, strong emphasis, quotes, lists, code, thematic breaks, links and images | CommonMark interpretation | CommonMark base, with GFM-defined differences |
| Pipe tables | Ordinary Markdown text, not a table extension | Rendered tables |
| Task-list markers | Literal markers within list items | Checkbox presentation |
| Strikethrough | Literal delimiters | Strikethrough presentation |
| Extended autolinks | No GFM extended-autolink recognition | GFM extended-autolink recognition |
| Raw HTML | Restricted formatting policy below | Restricted formatting policy below, including GFM disallowed-HTML handling |

CommonMark's angle-bracket autolinks remain distinct from GFM's extended
autolinks. The exact specification versions and conformance corpus are open
items; a label alone does not establish conformance.

A setting change reparses and refreshes open rendered page previews. The
page-header preview toggle remains separate from the dialect choice, as
does the existing **Preview rendering** scope control. R2 must specify their
interaction; the markup-preserving editor styling and the syntax-removing
rendered preview are different paths, not one shared renderer.

### Restricted HTML

Both dialects render supported HTML formatting without scripts or embedded
browser content. This is an intentional restriction, not unrestricted HTML
rendering or a promise of browser-equivalent output. The supported element
and attribute set, and the treatment of unsupported markup, require a
reviewed allowlist before implementation is complete.

The proposed resource policy applies to Markdown images and HTML images
through the same loader. HTML conversion, CSS, `srcset`, SVG, and other
resource-bearing constructs also need explicit treatment; restricting only
`img.src` is insufficient. The proposed native pipeline below has no
resource-loading operation during parsing or formatting.

### Images

Remote images load only after an explicit click. Opening a preview,
changing dialect, or scrolling to an image does not authorize its fetch.
The pre-load presentation includes the image's alt text and an explicit
load action.

Request policy, consent scope, caching, supported formats, size limits,
local-image behavior, and failure presentation remain open decisions.
Click-to-load does not by itself settle those details or establish a
privacy guarantee about an authorized request.

## Existing authoritative constraints

The accepted [Law 0001, The rule](../../law/0001-sealed-object.md#the-rule)
states:

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

Its accepted [AppKit text routes table](../../law/0001-sealed-object.md#appkits-text-routes)
states of preview copying:

> the rendered text between the objects is the ink, never the source markdown, and each object goes by reference, in rendered order

The same table states:

> no drag starts from a preview, with an object in the selection or not

The same accepted table states of readers:

> every reader the rows above sort as asking first asks the preview's page

And of a nonselected preview:

> not selectable and never the first responder

> a click promotes its page

These existing requirements apply to both dialects. Their copy, link,
expiry, selection, and reader routes need regression coverage when the
renderer changes. Interpretation: a new image action needs an explicit
route review, including its originating page and nonselected-page behavior;
the accepted rows do not themselves specify an image-request policy.

The accepted [ADR-0030, Decision](../../adr/0030-visible-pages-share-preview-rendering.md#decision)
states:

> Every rendering input must invalidate affected quiet renderings: page content,
> typeface, preview scope, syntax-highlighting state, and page-owned manual or
> inferred language state.

The same accepted decision also states:

> A visible refresh must remeasure the roll and publish
> updated geometry so the rail minimap retains truthful proportions.

Its [Consequences](../../adr/0030-visible-pages-share-preview-rendering.md#consequences)
state:

> no new content crosses a process or network
> boundary.

The same accepted [Decision](../../adr/0030-visible-pages-share-preview-rendering.md#decision)
states:

> Preview rendering remains markup-preserving.

Interpretation for this plan: dialect is an additional rendering input, and
asynchronous image-size changes need geometry publication too. ADR-0030's
markup-preserving presentation and Law 0001's rendered-copy preview are distinct
surfaces despite the shared word preview. ADR-0030 establishes display-only
restyling, not authorization for image requests. ADR-0059's accepted
surface-scope clarification preserves those pure display-refresh semantics
while separately authorizing the resource action. This is not evidence that
dialect invalidation or image loading is already implemented.

The previously accepted, now superseded
[2026-0915 UI/UX record](2026-0915-ui-ux-decisions.md) stated at D-09:

> Concealing is the app's one network outbound action

> The confirming click is the network boundary and the destination is always named.

Its review correction states:

> D-09's one outbound action means one network action and does not contradict D-32's three egresses

The accepted [ADR-0021, Consequences](../../adr/0021-multi-device-sync-over-a-blind-relay.md#consequences)
state:

> The relay is a second allowed TLS destination.

Interpretation: D-09 counts actions and ADR-0021 counts destinations, but the
accepted relay route already requires reconciliation with an app-wide reading
of D-09. A remote-image request adds another action and potentially a
document-selected destination. The shell also contains a `FeedbackClient.swift`
request path; its existence is not evidence of an accepted exception. The
October 16 successor resolves D-09's scope explicitly; ADR-0059 records the
remaining feedback/release authority gaps without approving those routes.

The [design index](README.md#foundational-design-reading-order) identifies the
design principles as binding within their scope and recorded amendments.
[Design principles §6](2026-0707-design-principles.md#6-escalate-deliberately)
states:

> Every destination is one the user enrolled and can see.

The accepted [principles amendment E](2026-0707-design-principles.md#amendment-e--restricted-page-preview-and-explicit-resources-2026-10-16)
adds the narrow preview-resource exception: load authorization is separate from
sync enrollment, not implicit device enrollment. The technical survey's
destination count is not an alternative source of route authority: the
[design index](README.md) explicitly states:

> It is not a verified inventory of current network traffic.

The accepted [ADR-0023, Consequences](../../adr/0023-hybrid-link-affordance-cmd-click-opens.md#consequences)
state:

> Opening is deliberate and therefore auditable as a gesture: nothing leaves the app because a click landed a pixel too far left.

ADR-0023 decides link clicks on the page's editable ink. The accepted
[Law 0001 preview-link row](../../law/0001-sealed-object.md#appkits-text-routes)
also states:

> a plain click opens nothing

The preview's link rule remains an accepted requirement, not only an
observation of `PreviewLinks`. ADR-0059 accepts a distinct **Load Image** control;
ordinary link/text/image-body clicks do not load images. R5 defines and tests
the exact pointer, keyboard and VoiceOver mechanics within that boundary.

## Enacted reconciliation (R0 closed)

The maintainer's instruction to enact the amendments adopts the policy below.
The accepted records change required behavior, not the evidence of implemented
behavior. They do not select a parser, request session, redirect policy, decoder
or complete native interaction design.

### Network and ledger authority

The [October 16 UI/UX successor, D-09](2026-1016-ui-ux-decisions.md#d-09--concealment-and-separately-authorized-resources)
replaces the app-wide action count with exclusivity for sealed-payload promotion
to a one-time link, preserving its confirming action and named destination.
[ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md#decision)
authorizes the separate image-resource action and the narrow exception to the
principles' preview/enrollment wording. A document-provided destination can be
authorized for a resource load without becoming an enrolled sync destination.

ADR-0059's bounded inventory distinguishes conceal, sync/authentication,
feedback, release-feed evidence and images. Missing feedback/release authority
remains explicit rather than approved by association. The inventory is not a
complete runtime traffic trace, and those unrelated gaps do not reopen the
accepted image-resource route.

[ADR-0012 Amendment 1](../../adr/0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval),
which is accepted, states:

> The ledger's `sent` record keeps its shape.

That amendment enumerates copy decrypted, decrypted drag and promotion to a
one-time link. ADR-0012's [Decision history](../../adr/0012-framing-threat-boundary-and-persistence-model.md#decision-history)
states of the base:

> This remains the proposed base record.

ADR-0059 expressly excludes image fetches from lifecycle-ledger `sent` events
and their URL/alt/response metadata. Any request audit requires its own accepted
event, field and retention decision. Operational transport logging and caching
remain R4 questions. The accepted amendment does not make ADR-0012's whole
proposed base accepted.

### Gesture and surface contracts

ADR-0059 accepts a distinct **Load Image** control that identifies its resource
recipient and discloses URL/request-metadata exposure before activation.
Ordinary clicks on text, links and image bodies do not load images; linked
images have separate load/open targets. A first activation on a nonselected
page only promotes that page. Pointer, keyboard and VoiceOver use the same
originating-page, deadline and key-ownership gates. Exact interaction mechanics
and consent lifetime remain R4/R5 work; the separate control does not inherit
an obligatory ⌘ modifier from link opening.

**Markup-preserving editor styling** names ADR-0030's mounted/quiet source
presentation. **Rendered page preview** names the separate syntax-removing
surface in Law 0001. R2 still specifies the header-toggle/scope/dialect matrix.
Rendering, restyling and cache refresh do not authorize a request. Image-size
changes still require geometry publication after any separately authorized load.

### Accepted record changes

- The [October 16 UI/UX successor](2026-1016-ui-ux-decisions.md) supersedes the
  September 15 record in full, with revision-pinned incorporation of surviving
  provisions and their intervening accepted amendments. The predecessor changes
  only its status and successor reference.
- ADR-0059 partially supersedes named clauses of ADR-0023 and ADR-0030, with
  reciprocal references and dated histories. Their existing link gestures and
  pure display-refresh semantics remain unchanged.
- [Design principles amendment E](2026-0707-design-principles.md#amendment-e--restricted-page-preview-and-explicit-resources-2026-10-16)
  records the restricted-preview/resource exception without rewriting the
  historical principles.
- [Law 0001](../../law/0001-sealed-object.md#appkits-text-routes) has a dated
  resource-request amendment, updated decision references and an image-action
  row with explicit test debt. Its governing sealed-object rule is unchanged.

These jointly close R0. R1–R6 remain open in this plan; no runtime request,
parser or AppKit result is supplied by enactment.

## Implementation baseline

These are code observations, not additional product requirements:

- [`MarkdownPreviewView.swift`](../../../shell/Sources/CompanionKit/MarkdownPreviewView.swift)
  parses with `Document(parsing:options:)` and converts the resulting tree
  into native AppKit attributed text. Images emit alt text and HTML emits
  literal markup.
- [`Package.swift`](../../../shell/Package.swift) selects `swift-markdown`
  from the 0.9 patch-release range. In the inspected dependency checkout,
  `CommonMarkConverter.parseString` unconditionally attaches `table`,
  `strikethrough`, and `tasklist`; `ParseOptions` exposes no dialect switch.
  That path also does not attach the GFM extended-autolink extension.
  [`Package.resolved`](../../../shell/Package.resolved) pins `swift-markdown`
  0.9.0 at `25cb61d3482054b09ae76ca4f281b1bfe7fe5a43` and `swift-cmark`
  0.9.0 at `08ddb528923cc1a6527e02b7a1aee9e516ca749a`.
- At those revisions, `swift-cmark/src/inlines.c` recognizes Apple's
  `^[…](…)` inline-attribute syntax without a dialect option. The converter
  also enables `CMARK_OPT_TABLE_SPANS`. Disabling the three attached GFM
  extensions therefore does not establish a CommonMark parser.
- [`MarkdownPreviewRenderingTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewRenderingTests.swift)
  currently expects `||` column spans and `^` row spans. Those expectations
  differ from the published GFM table grammar; they are not a conformance
  oracle. Resolve them explicitly when choosing the dialect contract.
- `InlineHTML` and `HTMLBlock` contain opaque HTML strings. The current
  visitor has no HTML element stack. `swift-cmark/extensions/tagfilter.c`
  registers an HTML-output filter callback, not an AST transformation;
  attaching it would not implement filtering in the native visitor.
- `MarkdownPreviewRenderer.init` replaces each sealed object's `U+FFFC`
  with an ASCII token (`OTSAttachment`, a per-render hex suffix, an index,
  and `Z`) before parsing; `literal(_:attributes:)` restores objects from
  tokens in emitted text. `safeURL` refuses a link destination containing
  the token, and objects with no visible leaf are flushed as separate
  paragraphs. The parser therefore sees each object as letters and digits.
- `Markdown.Image` renders its child inlines in secondary color, so an
  object inside alt text is emitted inside the image's text. No image
  destination is read.
- The preview builds an explicit `NSLayoutManager` (TextKit 1) and uses
  `NSTextTable`/`NSTextBlock`; sealed objects draw through
  `SealedBlockCell`, an `NSTextAttachmentCell`.
- [`OnetimePad-Info.plist`](../../../shell/OnetimePad-Info.plist) sets
  `LSMinimumSystemVersion` 13.0 and has no `NSAppTransportSecurity` key.
  [`Companion.entitlements`](../../../scripts/Companion.entitlements)
  enables the app sandbox and `com.apple.security.network.client`.
  `FeedbackClient.makeSession()` builds an ephemeral `URLSession` with
  cookie, credential and URL caches disabled; R4 may evaluate it as a
  pattern, not as evidence of sufficient request isolation.
- `MarkdownPreviewView.shownSelection()` emits text without attachments and
  references for `ChipAttachment`; other attachments are skipped. Ordinary
  image attachments would therefore need explicit composed-copy handling.
  `reseed(with:)` reparses only when `QuietRendering` identity changes;
  request state cannot depend only on a rendered attachment surviving.
- [`PageModel.swift`](../../../shell/Sources/CompanionKit/PageModel.swift)
  owns presentation preferences, the per-page preview toggle, and rendering
  cache invalidation.
- [`SettingsSections.swift`](../../../shell/Sources/CompanionKit/SettingsSections.swift)
  places the existing preview and syntax-highlighting controls in
  `CodeSettingsView`.

## Proposed architecture corrections

### Separate syntax, HTML composition, and native output

Evaluate this pipeline before choosing dependencies:

1. Dialect-configured Markdown parsing, with sealed objects represented by
   opaque identities and source positions.
2. A composition layer combining Markdown structure and raw HTML tokens.
   Apply GFM disallowed-tag escaping to raw tokens before HTML tree recovery
   can consume them, or prove an equivalent token-preserving algorithm.
   Then apply the reviewed element/attribute/URL policy. Ordinary decoded
   text remains text.
3. Native text, styles, sealed-object references, and inert image descriptors.
   Image actions dispatch separately from ordinary link opening.
4. A separately authorized loader supplies bounded decoded image data to
   current image occurrences; the UI then updates layout and roll geometry.

This is a proposal, not a settled intermediate representation. A configurable
fork/upstream parser change and an alternate parser with a native adapter
are candidates. Direct access to the current C parser still needs evaluation
of its Apple-specific grammar. Neither regex replacement of parsed output
nor hiding GFM styling restores CommonMark syntax.

HTML leaves cannot be rendered independently: `A <em>one **two**</em>` spans
HTML and Markdown nodes, while `<del>\n*x*\n</del>` and
`<del>\n\n*x*\n\n</del>` have different block parsing. Define element scope
across blocks, malformed-nesting recovery, whitespace, and whether unsupported
elements are escaped, unwrapped, or removed with their contents. Never feed
ordinary entity-decoded text such as `&lt;em&gt;literal&lt;/em&gt;` back into
HTML recognition. Prototype a bounded tokenizer/composer or a non-fetching
HTML parser; do not assume an allowlist supplies parsing or tree recovery.

The published [GFM §6.11](https://github.github.com/gfm/#disallowed-raw-html-extension-)
states:

> Filtering is done by replacing the leading `<` with the entity `&lt;`.

> All other HTML tags are left untouched.

Interpretation: `tagfilter` is not the proposed restrictive allowlist.
Specify and test its native equivalent separately; dropping a tag/subtree
is not the same output as escaping it. Record any intentional deviation.

**HTML importer trap:** the installed macOS 27.0 SDK's AppKit
`NSAttributedString.h`, beside `NSWebResourceLoadDelegateDocumentOption`,
documents the default delegate as one that:

> will permit the loading of subsidiary resources but will not respond to authentication challenges

The same header states:

> In Mac OS X 10.4 and later, WebKit is always used for HTML documents

These are platform documentation statements, not runtime probe results.
Proposal: use explicit HTML-to-native mapping instead of AppKit HTML import.
An `NSTextView` destination does not establish that its importer avoids
WebKit or resource requests; deleting attachments after import is too late
to prevent import-time requests. If import remains a candidate, R3 must
first investigate it in an isolated instrumented harness.

### Sealed-object placeholders are grammar input

Pipeline step 1 assumes a parser that accepts opaque object identities.
Neither candidate grammar defines one; the current renderer substitutes
text, and the substitute's character class changes parsing.

The pinned swift-cmark `test/spec.txt` (GFM 0.29) states:

> A [punctuation character](@) is an [ASCII punctuation character] or anything in the general Unicode categories `Pc`, `Pd`, `Pe`, `Pf`, `Pi`, `Po`, or `Ps`.

[CommonMark 0.31.2 §2.1](https://spec.commonmark.org/0.31.2/#characters-and-lines)
states:

> A Unicode punctuation character is a character in the Unicode `P` (puncuation) or `S` (symbol) general categories.

The pinned `cmark_utf8proc_is_punctuation` follows the P-only definition.
`U+FFFC` is category `So`: punctuation under 0.31.2, not under GFM 0.29.
The ASCII token is alphanumeric under both. Interpretations, not executed:

- `_note_` immediately followed by an object: with the token, the closing
  `_` is both left- and right-flanking and followed by an alphanumeric, so
  it cannot close emphasis. A `So` placeholder under 0.31.2 would let it
  close; under GFM 0.29 it would not.
- `www.example.com` immediately followed by an object: a GFM valid domain
  admits alphanumerics, so an extended autolink would absorb the token;
  `safeURL` would then refuse the destination and drop the link.
- Tokens inside raw HTML tags, attribute values and comments reach the
  composer as attribute text, not objects (see R3).

Proposal: define sealed-object syntax as an explicit application extension to
each pinned dialect. Law 0001's one-position rule does not prescribe a Markdown
punctuation class. Specify the placeholder's grammar class per dialect, or
evaluate a parser-level atom in R1, and fixture-test both dialects. Report
ordinary-text conformance separately from object-containing fixtures and
native-output restrictions. A replacement token alone does not establish
correct delimiter or autolink boundaries.

Under ADR-0059's accepted resource policy, a destination containing an object
or its placeholder (Markdown image, HTML `src`/`srcset`, CSS `url()`) is refused,
mirroring `safeURL`'s link refusal. R1/R3 also specify object treatment inside
attributes, comments and unsupported HTML. An object inside alt text remains
part of rendered order; R5 specifies its visible and copied position in every
image state, including after loading.

### Separate image state from rendering state

The accepted route boundary is recorded above. Remaining design constraints
for R4/R5 review include:

- Identify an image occurrence by its originating page, source revision and
  occurrence, plus destination. A URL alone or rendered character index is
  not an authorization identity. Repeated URLs do not imply shared consent.
- Separate consent, in-flight request identity, and decoded data from the
  disposable attributed-string cache. Define whether consent/results survive
  dialect, font, scope, source, page-selection, and preview-toggle changes.
- Define explicit unloaded, loading, loaded, failed, and invalidated states,
  including retry. Revalidate the originating page, current occurrence and
  consent before initial dispatch, retries, and redirects, and before
  publishing completion. Specify which transitions revoke authorization.
  Cancellation alone is not a substitute for preventing stale dispatch or
  rejecting obsolete results.
- Use a distinct image representation, retaining alt text and defining empty
  alt fallback, textual copy, and accessibility in every loading state. Do
  not inherit sealed-object handling or ordinary attachment pasteboard types.
- Implement the accepted promotion-only first activation on a nonselected
  page, followed by a separate load activation. Keyboard and VoiceOver use the
  same action and page checks; linked images have distinct load/open targets.
  R5 validates their TextKit 1 presentation and accessibility mechanics.
- Publish geometry when image dimensions change, including images in tables
  and above the viewport. Define fitting, scroll anchoring, and decoded-pixel
  bounds; downloaded-byte bounds alone do not bound decoded memory.
- The preview is TextKit 1, so the image representation is an attachment
  cell, not a TextKit 2 view provider. Validate VoiceOver exposure of a
  cell's load action rather than assuming it.

Detailed request, consent, cache and copy-state choices still need review;
the accepted route requirements do not establish runtime privacy or persistence
results. Unsupported local, relative and non-network destinations still need
deterministic fallback;
their syntax can parse even when the application declines to load them.

## Research gates

R0 is closed by the maintainer-directed accepted amendments above. It is an
authority-reconciliation result, not a transport experiment or production-readiness
result. R1–R6 remain open in this plan. R1–R5 close with reviewed contracts and
relevant executable evidence; R6 records integrated release validation. A
library label or screenshot is not a substitute for evidence. R1–R5 may be
investigated in parallel, but the parser/composer/attachment prototype must be
integrated before its architecture is selected. R4 uses the accepted R0 route
boundary rather than reopen whether the feature is wanted.

| Gate | Unvalidated assumption and research | Required output |
| --- | --- | --- |
| **R0 — Authority reconciliation (closed 2026-10-16)** | Enacted at the maintainer's instruction: D-09 scope, separate resource-destination authorization, bounded route inventory, ledger exclusion and source/preview clarification. | Accepted [UI/UX successor](2026-1016-ui-ux-decisions.md), [ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md) and [Law 0001 amendment](../../law/0001-sealed-object.md#amendments), plus principles amendment E and reciprocal ADR histories. Detailed request policy and transport experiments remain R4 work; no runtime result follows from R0. |
| **R1 — Parser contract (blocking)** | Evaluate a configurable fork/upstream change and an alternate parser. Candidate targets are CommonMark 0.31.2 and published GFM 0.29-gfm, not an assumed common base version. Compare official examples independently of the dependency's edited corpus. Exercise single/double/triple tildes, extended autolink punctuation/email/protocol cases, Apple inline attributes, table spans, HTML comments, `textarea` block boundaries, and the P-versus-P/S punctuation definition (CommonMark 0.31.2 example 354). Fixture sealed objects adjacent to emphasis delimiters, extended autolinks, table pipes and link/image brackets in both dialects. | Pinned versions, source revisions and official corpus provenance/checksums; AST or test-only canonical HTML comparison with enumerated mismatches; reviewed decision on existing span tests; specified sealed-object extension and placeholder grammar class per dialect; dependency/license/notice review. Ordinary-text conformance, object-containing fixtures and native restrictions are reported separately. |
| **R2 — Surface and preference contract (blocking)** | Trace rendered page previews versus markup-preserving mounted/quiet editor styling, notes, and files. Test the interaction of the header toggle with All pages / Focused page only / Never. Confirm whether dialect is intentionally preview-only. | Surface/precedence matrix and picker wording, chosen storage scope, unset/unknown-value and restart behavior, and invalidation tests for selected and nonselected previews. No unapproved editor/file scope expansion. |
| **R3 — HTML composition (blocking)** | Prototype mixed HTML/Markdown, cross-block scope, escaped text, malformed nesting, quoted `>`, comments, and unsupported-element fallback. Exercise sealed tokens in attributes, removed elements, destinations, and comments. Investigate importer resource behavior if still considered. | Reviewed composition algorithm, element/attribute/native-style mapping and URL policy, explicit GFM-filter behavior, depth/work limits and fixtures proving object identity/order and text provenance. Instrument parsing/conversion itself for requests. |
| **R4 — Request policy (blocking)** | Investigate request-session defaults rather than assuming ephemeral configuration removes all metadata. Observe App Transport Security's effect on `http` images with the current Info.plist, and do not add a global ATS exception without review. Refuse destinations containing sealed placeholders. Verify decoder format support and decoded-size bounding on the macOS 13.0 deployment target, not only the build SDK; untrusted image data is decoded in-process. Decide schemes, URL credentials, cookies/authentication, referrer and other headers, proxies, redirects including cross-origin/downgrade, loopback/private-network destinations, relative/base URLs, cache/storage/logging, timeout/concurrency, streamed byte bounds, MIME validation, raster/vector/animated formats and decoded size. | Reviewed request and consent policy with numeric limits, format list and lifecycle table, consistent with R0's accepted route authority. Instrumented transport tests for pre-activation inactivity and each allowed/denied redirect and destination; document residual exposure from authorized requests. |
| **R5 — Native interactions and lifecycle (blocking)** | Prototype TextKit 1 image attachment cells beside sealed objects, in links/tables and multiselections, including objects inside alt text. Implement and validate ADR-0059's distinct destination-labelled Load Image control with the unchanged link and promotion rules; ordinary text/link/image-body clicks do not load. Exact gestures/accessibility mechanics remain open. Exercise expiry between click/dispatch/redirect/completion, page close/switch, source replacement, and preference changes during loading. | Exact text and pasteboard expectations for all image states and Services overloads; rendered order of alt-text objects in each state; keyboard/VoiceOver and nonselected-page activation behavior; stale-result rejection, request identity, and layout/scroll/minimap observations. Review against the accepted law and ADR-0023. |
| **R6 — Integrated release validation** | Run pinned syntax fixtures, native policy tests, and AppKit interaction checks together; benchmark representative large/nested pages and large decoded images. Verify request counts across opening, scrolling, reparsing, resizing and retries. | Recorded commands/results, mismatch/restriction matrix, geometry and performance results, and manual interaction evidence. No inferred conformance or request-isolation result from screenshots alone. |

Primary standards consulted on 2026-10-16:
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and
[GFM 0.29-gfm](https://github.github.com/gfm/). They define different base
syntax in some cases; selecting current CommonMark plus GFM extensions does
not automatically implement the older published GFM grammar. Their examples
use HTML as a structural oracle; a test-only serializer/comparator is needed
for native parsing tests, not browser-equivalent AppKit screenshots.

## Proposed implementation sequence

1. **Close R1–R5 under the accepted R0 boundary.** Record the parser and
   placeholder grammar, surface matrix, HTML composition and allowlist,
   detailed request policy, and native image-state contract. Complete the
   integrated prototype and technical review before production wiring.
2. **Integrate dialect parsing and native output.** Pass dialect explicitly,
   implement the selected grammar, and distinguish conformance tests from
   intentional presentation restrictions. Integrate sealed-object restoration
   with HTML filtering rather than bolting a sanitizer onto emitted text.
3. **Wire preference and invalidation.** Add the typed picker under Code
   using existing defaults patterns after R2 resolves storage. Proposed fallback
   is GFM for unset/unknown values. Invalidate both model caches and preview
   reseeding; remeasure selected/nonselected previews without relaunch.
4. **Integrate reviewed HTML and image actions.** Emit inert descriptors,
   implement the reviewed state machine and loader, preserve composed-copy
   semantics, and publish geometry after asynchronous image updates.
5. **Complete R6.** Extend
   [`MarkdownPreviewRenderingTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewRenderingTests.swift)
   and
   [`CheckpointMarkdownPreviewTests.swift`](../../../shell/Tests/CompanionKitTests/CheckpointMarkdownPreviewTests.swift),
   add syntax-corpus, settings, transport and lifecycle tests, and perform
   the AppKit interaction pass.

## Acceptance criteria

These delivery checks follow the accepted policy boundary and remaining
technical reviews above; they are not evidence of implemented behavior.

- R0's accepted records identify the replaced and unchanged earlier decisions,
  distinguish image-load authorization from destination enrollment, and state
  the image-request ledger disposition. No gate treats approved feature scope
  as an unanswered product question.
- Both named dialects are selectable; an unset selection uses GFM. R2's
  unknown-value and restart behavior is tested.
- CommonMark does not interpret GFM-only tables, task markers,
  strikethrough, or extended autolinks as extensions.
- GFM parses those extensions according to the selected GFM version. Both
  parsers are checked against the pinned official corpora, with reviewed
  mismatches enumerated separately from native-output restrictions. Apple
  inline attributes and nonstandard table spans have explicit outcomes.
- Sealed objects adjacent to emphasis delimiters, extended autolinks and
  table cells parse as R1 specifies in each dialect, and no resource
  destination containing an object is loadable.
- A dialect change refreshes every open preview without a relaunch.
- Supported HTML formatting renders under the reviewed allowlist; mixed
  Markdown/HTML, malformed markup, escaped ordinary text and GFM-disallowed
  tags have exact text/style fixtures. Scripts and embedded browser content
  do not execute or appear as active content.
- A remote image produces no fetch before its explicit load action,
  whether its source syntax is Markdown or HTML. Instrumented transport
  checks include parsing/conversion, opening, scrolling, dialect changes,
  resizing, and resource-bearing markup beyond `img.src`.
- Ordinary text/link/image-body clicks do not load images. The accepted
  separate Load Image control preserves ADR-0023's links and the law's preview
  rows; R5's exact pointer/keyboard/VoiceOver mechanics are tested.
- Initial dispatch, retry, redirects and completion obey R4/R5's reviewed
  authorization and lifecycle table. Tests replace/remove an image while
  its page remains live and expire/close/switch pages during queued work.
  Request limits and decoded-image limits are exercised independently.
- Unloaded, loading, loaded and failed images have exact textual copy and
  Services expectations beside sealed objects, without unintended pasteboard
  types. Native controls preserve first-click promotion and no-drag behavior;
  keyboard and VoiceOver activation are checked.
- Image completion and dialect changes remeasure the roll and publish
  geometry; table fitting, resize and above-viewport updates are tested.
- Constructs shared by the two selected specification versions retain their
  expected structure; version-specific base-grammar differences are tested.
- Sealed-object order and the accepted preview copy, link, reader, expiry,
  and no-drag behavior remain covered in both modes.
- The user-facing description distinguishes dialect support from the
  intentional HTML and resource-loading restrictions.

These criteria describe delivery requirements; no implementation or test
result is recorded by this document.

## Open decisions

R0's authority reconciliation is accepted and closed; the following technical
and release decisions remain open.

1. **Conformance target (R1):** exact versions, parser choice and unsupported
   extensions; resolve existing table-span expectations and the placeholder
   grammar class. An extension switch alone is not sufficient evidence.
2. **Preference scope (R2):** app-wide versus page-owned state, restart
   behavior, surface coverage, and precedence with preview scope. The agreed
   baseline is the rendered page preview; editor/file changes are not assumed.
3. **HTML policy and composition (R3):** parsing/recovery model, supported
   native mappings, GFM filtering order, URL treatment and unsupported-markup
   fallback. An allowlist alone does not close this decision.
4. **Image authorization and requests (R4):** consent scope/revocation,
   session behavior, redirects/destinations, caching, formats and numeric
   resource limits within ADR-0059's accepted route. Route acceptance alone
   does not close this technical decision.
5. **Image representation and lifecycle (R5):** copy/Services, identity,
   selection/activation, accessible actions, stale work, and geometry.
6. **Release evidence (R6):** conformance results, native policy and interaction
   coverage, request instrumentation, and performance measurements.

## Review evidence and limits

The 2026-10-16 readiness review inspected the native renderer, model, Settings,
preview tests, the resolved dependency checkouts, the accepted law/ADR cited
above, the published standards, and installed SDK documentation. A follow-up
pass inspected the renderer's placeholder masking, the pinned punctuation
function and `test/spec.txt`, the Info.plist, entitlements and
`FeedbackClient` session, the 2026-0915 D-09 wording, and ADR-0023.
Neither pass ran parser conformance fixtures, image-loading experiments,
application tests, or an AppKit interaction session; the placeholder
examples above are derived from the specification text, not executed.

The initial reconciliation pass compared the then-accepted UI/UX record,
Law 0001's preview rows, ADR-0021, ADR-0023, ADR-0030, ADR-0012's separately
accepted amendment, the design index/principles and amendment conventions.
The maintainer then instructed enactment of the recommended document amendments.
The successor record, ADR-0059, law amendment and principles amendment now enact
that policy and close R0. They do not supply runtime evidence. R1–R6 remain open
in this plan; no parser, allowlist, detailed transport policy or implementation
readiness is established by these documentation changes.
