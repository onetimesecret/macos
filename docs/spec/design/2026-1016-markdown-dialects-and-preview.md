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

The draft status applies to the technical details, research gates and open
decisions, not to whether the feature is wanted. Target requirements below are not a description of shipped behavior or
evidence of validated guarantees. Technical recommendations and research
gates remain proposals. This document does not amend an accepted behavior
law or ADR; acceptance of a new network route requires its own review.

## Summary

The target Markdown preview supports CommonMark and GitHub Flavored Markdown
(GFM), selected through a Markdown dialect setting. The selection changes
parsing semantics, not merely visual styling. Both dialects use a restricted
preview with supported HTML formatting and click-to-load remote images.

## Implementation-readiness assessment

**Ready for bounded experiments, not full implementation.** A settings picker
is straightforward; parser semantics, HTML composition, and image state are
architectural prerequisites. An allowlist and a click handler alone do not
resolve them. Complete gates R0–R5 below before selecting the full design;
complete R6 before delivery. No experiment results are recorded here.

The principal corrections are to separate parser conformance from restricted
native output, specify how sealed-object placeholders participate in parsing,
design HTML composition before rendering individual HTML leaves, and separate
image authorization/request state from render caches. An accepted decision
describes concealing as the app's one network outbound action (D-09, below);
remote images need an authority decision before their technical design can
close.

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

Interpretation for this plan: dialect is an additional rendering input, and
asynchronous image-size changes need geometry publication too. ADR-0030
establishes display-only restyling, not authorization for image requests.
Review and record the new network route in an accepted decision before
shipping it. This is not evidence that dialect invalidation or image
loading is already implemented.

The accepted [2026-0915 UI/UX record](2026-0915-ui-ux-decisions.md), whose
D-09 is listed in Law 0001's `decisions` front matter, states at D-09:

> Concealing is the app's one network outbound action

> The confirming click is the network boundary and the destination is always named.

Its review correction states:

> D-09's one outbound action means one network action and does not contradict D-32's three egresses

Interpretation: on its face, a remote-image request is a second network
outbound action. The shell already contains another request path
(`FeedbackClient.swift`), and accepted ADR-0021 decides sync over a relay;
this review does not settle how D-09's count applies to either. R0 must resolve it by
amendment or explicit scoping before an image route is accepted; this
document does not reinterpret D-09.

The accepted [ADR-0023, Consequences](../../adr/0023-hybrid-link-affordance-cmd-click-opens.md#consequences)
state:

> Opening is deliberate and therefore auditable as a gesture: nothing leaves the app because a click landed a pixel too far left.

ADR-0023 decides link clicks on the page's editable ink. Code observation:
the preview's `PreviewLinks` delegate applies the same ⌘-click rule.
Interpretation: a plain click that dispatches an image request departs from
that gesture model; R5 must define the load gesture against it.

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

Proposal: specify the placeholder's grammar class per dialect, or evaluate a
parser-level atom in R1, and fixture-test both dialects. A resource
destination containing a placeholder (Markdown image, HTML `src`/`srcset`,
CSS `url()`) is never loadable, mirroring `safeURL`'s link refusal. An
object inside alt text remains part of rendered order; R5 specifies where it
appears once the image replaces the alt text.

### Separate image state from rendering state

Proposed design constraints for R4/R5 review:

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
- Propose first-click promotion only on a nonselected page, followed by a
  separate load activation. Keyboard and VoiceOver use the same action and
  page checks; an image inside a link needs distinct load/open targets.
- Publish geometry when image dimensions change, including images in tables
  and above the viewport. Define fitting, scroll anchoring, and decoded-pixel
  bounds; downloaded-byte bounds alone do not bound decoded memory.
- The preview is TextKit 1, so the image representation is an attachment
  cell, not a TextKit 2 view provider. Validate VoiceOver exposure of a
  cell's load action rather than assuming it.

The image-request, consent, cache, and copy policies above are recommendations
for review, not accepted privacy or persistence guarantees. Unsupported local,
relative, and non-network destinations still need deterministic fallback;
their syntax can parse even when the application declines to load them.

## Research gates

All gates are open. Each closes with a reviewed artifact and executable
observations, not a library label or screenshot. R0–R5 may be investigated
in parallel, but the parser/composer/attachment prototype must be integrated
before its architecture is selected. R4 cannot close before R0.

| Gate | Unvalidated assumption and research | Required output |
| --- | --- | --- |
| **R0 — Network authority (blocking)** | Determine how D-09's one-network-action wording applies to existing request paths and to an image request, and whether ADR-0012's ledger records image requests. Do not infer the answer from existing code paths. | Maintainer-accepted amendment or scoping of D-09/Law 0001 and an accepted route decision naming who receives an image request and what the user is told before the click. The approved click-to-load direction is the input; R0 reconciles it with D-09 rather than reopening it. |
| **R1 — Parser contract (blocking)** | Evaluate a configurable fork/upstream change and an alternate parser. Candidate targets are CommonMark 0.31.2 and published GFM 0.29-gfm, not an assumed common base version. Compare official examples independently of the dependency's edited corpus. Exercise single/double/triple tildes, extended autolink punctuation/email/protocol cases, Apple inline attributes, table spans, HTML comments, `textarea` block boundaries, and the P-versus-P/S punctuation definition (CommonMark 0.31.2 example 354). Fixture sealed objects adjacent to emphasis delimiters, extended autolinks, table pipes and link/image brackets in both dialects. | Pinned versions, source revisions and official corpus provenance/checksums; AST or test-only canonical HTML comparison with enumerated mismatches; reviewed decision on existing span tests; specified placeholder grammar class per dialect; dependency/license/notice review. Native restrictions are reported separately from parser failures. |
| **R2 — Surface and preference contract (blocking)** | Trace rendered page previews versus markup-preserving mounted/quiet editor styling, notes, and files. Test the interaction of the header toggle with All pages / Focused page only / Never. Confirm whether dialect is intentionally preview-only. | Surface/precedence matrix and picker wording, chosen storage scope, unset/unknown-value and restart behavior, and invalidation tests for selected and nonselected previews. No unapproved editor/file scope expansion. |
| **R3 — HTML composition (blocking)** | Prototype mixed HTML/Markdown, cross-block scope, escaped text, malformed nesting, quoted `>`, comments, and unsupported-element fallback. Exercise sealed tokens in attributes, removed elements, destinations, and comments. Investigate importer resource behavior if still considered. | Reviewed composition algorithm, element/attribute/native-style mapping and URL policy, explicit GFM-filter behavior, depth/work limits and fixtures proving object identity/order and text provenance. Instrument parsing/conversion itself for requests. |
| **R4 — Request policy (blocking)** | Investigate request-session defaults rather than assuming ephemeral configuration removes all metadata. Observe App Transport Security's effect on `http` images with the current Info.plist, and do not add a global ATS exception without review. Refuse destinations containing sealed placeholders. Verify decoder format support and decoded-size bounding on the macOS 13.0 deployment target, not only the build SDK; untrusted image data is decoded in-process. Decide schemes, URL credentials, cookies/authentication, referrer and other headers, proxies, redirects including cross-origin/downgrade, loopback/private-network destinations, relative/base URLs, cache/storage/logging, timeout/concurrency, streamed byte bounds, MIME validation, raster/vector/animated formats and decoded size. | Reviewed request and consent policy with numeric limits, format list, lifecycle table, and accepted route decision. Instrumented transport tests for pre-activation inactivity and each allowed/denied redirect and destination; document residual exposure from authorized requests. |
| **R5 — Native interactions and lifecycle (blocking)** | Prototype TextKit 1 image attachment cells beside sealed objects, in links/tables and multiselections, including objects inside alt text. Define the load gesture against ADR-0023 and the preview's plain-click selection. Exercise expiry between click/dispatch/redirect/completion, page close/switch, source replacement, and preference changes during loading. | Exact text and pasteboard expectations for all image states and Services overloads; rendered order of alt-text objects in each state; keyboard/VoiceOver and nonselected-page activation behavior; stale-result rejection, request identity, and layout/scroll/minimap observations. Review against the accepted law and ADR-0023. |
| **R6 — Integrated release validation** | Run pinned syntax fixtures, native policy tests, and AppKit interaction checks together; benchmark representative large/nested pages and large decoded images. Verify request counts across opening, scrolling, reparsing, resizing and retries. | Recorded commands/results, mismatch/restriction matrix, geometry and performance results, and manual interaction evidence. No inferred conformance or request-isolation result from screenshots alone. |

Primary standards consulted on 2026-10-16:
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and
[GFM 0.29-gfm](https://github.github.com/gfm/). They define different base
syntax in some cases; selecting current CommonMark plus GFM extensions does
not automatically implement the older published GFM grammar. Their examples
use HTML as a structural oracle; a test-only serializer/comparator is needed
for native parsing tests, not browser-equivalent AppKit screenshots.

## Proposed implementation sequence

1. **Close R0–R5.** Record the network authority decision, parser and
   placeholder grammar, surface matrix, HTML composition and allowlist,
   request policy, and native image-state contract. Complete the
   integrated prototype and required authority review before production wiring.
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

These are proposed delivery checks, subject to the research and authority
reviews above, not evidence of existing guarantees.

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

0. **Network authority (R0):** D-09 amendment or scoping, ledger treatment,
   and the accepted image route for the approved click-to-load behavior.
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
   resource limits. Obtain acceptance of the new route; click-to-load alone
   does not close this decision.
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
examples above are derived from the specification text, not executed. The research gates remain open; this
review does not select a parser, approve an allowlist or network policy, or
establish implementation readiness.
