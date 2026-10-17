---
id: 2026-1016-markdown-dialects-and-preview
title: Markdown dialects and restricted preview
status: accepted
documentation_status: reviewed
dated: 2026-10-16
reviewed: 2026-10-16
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

The maintainer accepted this implementation plan on 2026-10-16 with the
instruction: “Please update the plan to reviewed and accepted and to remove
any remaining draft suggestions”. This record is reviewed and accepted for
production implementation. Its architecture, scope and delivery requirements
are operative; implementation specifications and verification are work to
complete, not prerequisites for permission to begin application changes.

The accepted [UI/UX successor](2026-1016-ui-ux-decisions.md),
[ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md)
and [Law 0001 amendment](../../law/0001-sealed-object.md#amendments) enact R0's
policy reconciliation. This plan implements those records without changing
their scope. Acceptance does not report shipped behavior, completed tests or
runtime validation. R1–R6 below identify delivery work and its required evidence.

The enacted reconciliation updates the older decisions for the approved scope;
it does not reopen dialect selection, restricted HTML or explicitly activated
remote images. Removing images would require a new maintainer scope decision,
not merely an unresolved reconciliation gate.

## Summary

The target Markdown preview supports CommonMark and GitHub Flavored Markdown
(GFM), selected through a Markdown dialect setting. The selection changes
parsing semantics, not merely visual styling. Both dialects use a restricted
preview with supported HTML formatting and click-to-load remote images.

## Implementation authorization and completion boundary

**Proceed with production implementation.** Build the parser, composer, native
output, preference and image-state paths in the application codebase, with
focused tests alongside each integration step. Research tools support specific
technical checks; an isolated prototype is not the implementation deliverable.
R1–R5 are implementation workstreams, not research-only approval gates. R6 is
the integrated release check.

Separate parser conformance from restricted native output, represent sealed
objects explicitly through parsing and composition, and keep image authorization
and request state independent of render caches. Implement the parser contract,
HTML policy, preference matrix and image lifecycle with their tests. Specify
and test the request policy before connecting a real image loader. Acceptance
authorizes this work; it does not mark any of those checks complete.

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
autolinks. The conformance targets are CommonMark 0.31.2 and the published
GFM 0.29-gfm specification, with independently pinned official corpora.
A label alone does not establish conformance.

A setting change reparses and refreshes open rendered page previews. The
page-header preview toggle remains separate from the dialect choice, as
does the existing **Preview rendering** scope control. R2 implements and tests
their precedence matrix. Dialect selection applies only to rendered page
previews, not markup-preserving editor styling, note editors or file editors.
These are different rendering paths, not one shared renderer.

### Restricted HTML

Both dialects render supported HTML formatting without scripts or embedded
browser content. This is an intentional restriction, not unrestricted HTML
rendering or a promise of browser-equivalent output. The supported element
and attribute set, and the treatment of unsupported markup, require a
reviewed allowlist before implementation is complete.

The accepted resource policy applies to Markdown images and supported HTML
images through the same loader. The HTML policy must explicitly handle CSS,
`srcset`, SVG and other resource-bearing constructs; restricting only `img.src`
is insufficient. The native pipeline has no resource-loading operation during
parsing or formatting.

### Images

Remote images load only after an explicit click. Opening a preview,
changing dialect, or scrolling to an image does not authorize its fetch.
The pre-load presentation includes the image's alt text and an explicit
load action.

R4 and R5 deliver the request policy, consent lifecycle, cache behavior,
supported formats, numeric limits, deterministic local-image fallback and
failure/retry presentation as implementation specifications and tests.
Click-to-load does not by itself establish a privacy result for an authorized
request.

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
are specified and tested in R4. The accepted amendment does not make
ADR-0012's whole proposed base accepted.

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
surface in Law 0001. R2 implements the header-toggle/scope/dialect matrix below.
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

These jointly close R0. R1–R6 are the delivery workstreams below; no runtime
request, parser or AppKit result is supplied by enactment.

## Implementation baseline

These are code observations, not additional product requirements. Bullets
naming the composer describe the code after the R3 slice in the
[delivery record](#delivery-record):

- [`MarkdownPreviewView.swift`](../../../shell/Sources/CompanionKit/MarkdownPreviewView.swift)
  parses with `Document(parsing:options:)` and converts the resulting tree
  into native AppKit attributed text. Every text leaf, code span, break,
  Markdown trait, raw HTML leaf and image passes through one
  `PreviewCompositionStream` per rendering
  ([`PreviewComposer.swift`](../../../shell/Sources/CompanionKit/PreviewComposer.swift)).
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
  oracle. R1 replaces those expectations with fixtures for the selected
  published dialect grammar and records the removal of nonstandard spans.
- `InlineHTML` and `HTMLBlock` contain opaque HTML strings. The renderer
  tokenizes each with
  [`HTMLTokenizer`](../../../shell/Sources/CompanionKit/HTMLTokenizer.swift)
  and composes it in the document's one element stack.
  `swift-cmark/extensions/tagfilter.c` registers an HTML-output filter
  callback, not an AST transformation; the composer applies the GFM filter
  to native output instead.
- `MarkdownPreviewRenderer.init` replaces each sealed object's `U+FFFC`
  with an ASCII token (`OTSAttachment`, a per-render hex suffix, an index,
  and `Z`) before parsing; `parts(_:addressOf:)` turns each token spelling
  in a leaf into a typed object part, each token once, and an image address
  assigns only tokens inside the image's own source, keeping any other
  spelling as text so the composer refuses the address. `safeURL`
  refuses a link destination containing the token, and objects with no
  visible leaf are flushed as separate paragraphs. The parser therefore
  sees each object as letters and digits; R1's typed atom does not exist yet.
- A `Markdown.Image` composes as its alt text, the plain text of its inlines
  as CommonMark's HTML writer gives it, in secondary color, followed by any
  objects in its destination. Its destination is read only into a
  `PreviewImageDescriptor` under `NSAttributedString.Key.previewImage`; no
  code reads that attribute yet.
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

## Implementation architecture

### Surface and preference contract

Store the typed dialect selection app-wide in the existing application settings
defaults domain. Unset, unknown or incorrectly typed values select GFM. Restore
a recognized selection on restart. Do not add per-page overrides, page-content
fields or synchronization for this preference.

The page-header toggle chooses the existing rendered page-preview surface.
The **Preview rendering** scope controls markup-preserving source styling; it
does not disable an explicitly enabled page preview. Apply dialect only after
selecting the rendered surface. Keep the existing Tabs, note and file surfaces;
this feature does not add rendered previews to them.

| Surface | Header preview | All pages | Focused page only | Never | Dialect effect |
| --- | --- | --- | --- | --- | --- |
| Selected Timeline page | Off | Styled source | Styled source | Plain source | None |
| Nonselected Timeline page | Off | Styled source | Plain source | Plain source | None |
| Selected Timeline page | On | Rendered preview | Rendered preview | Rendered preview | Reparse |
| Nonselected Timeline page | On | Rendered preview | Rendered preview | Rendered preview | Reparse |
| Tabs page or note editor | Not applicable | Existing source styling | Existing source styling | Plain source | None |
| File editor | Not applicable | Existing file mode | Existing file mode | Existing plain presentation | None |

Preserve syntax-highlighting preference semantics within source styling. A
dialect change invalidates all rendered page previews, including nonselected
ones, and reseeding compares both source identity and dialect. Remeasure and
publish geometry, including above-viewport size changes; test scroll anchoring
rather than inferring it from a cache notification.

### Separate syntax, HTML composition, and native output

Implement this pipeline in the application's rendered-preview path:

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

Use a pinned, dialect-configured parser adapter and a typed composition
representation. R1 supplies the dependency selection, source revisions,
license/notice review and corpus tests as part of integration. The current
Swift wrapper cannot implement the named modes by disabling its extensions:
its Apple-specific core grammar also differs. Neither regex replacement of
parsed output nor hiding GFM styling restores CommonMark syntax.

HTML leaves cannot be rendered independently: `A <em>one **two**</em>` spans
HTML and Markdown nodes, while `<del>\n*x*\n</del>` and
`<del>\n\n*x*\n\n</del>` have different block parsing. Define element scope
across blocks, malformed-nesting recovery, whitespace, and whether unsupported
elements are escaped, unwrapped, or removed with their contents. Never feed
ordinary entity-decoded text such as `&lt;em&gt;literal&lt;/em&gt;` back into
HTML recognition. Implement a bounded tokenizer/composer with explicit
text provenance, object identities and recovery rules. Integrate it with the
parser and native renderer; an allowlist alone does not supply tree recovery.

The published [GFM §6.11](https://github.github.com/gfm/#disallowed-raw-html-extension-)
states:

> Filtering is done by replacing the leading `<` with the entity `&lt;`.

> All other HTML tags are left untouched.

Interpretation: `tagfilter` is distinct from the restrictive native allowlist.
Specify and test its native equivalent separately; dropping a tag/subtree
is not the same output as escaping it. Record any intentional deviation.

**HTML importer trap:** the installed macOS 27.0 SDK's AppKit
`NSAttributedString.h`, beside `NSWebResourceLoadDelegateDocumentOption`,
documents the default delegate as one that:

> will permit the loading of subsidiary resources but will not respond to authentication challenges

The same header states:

> In Mac OS X 10.4 and later, WebKit is always used for HTML documents

These are platform documentation statements, not runtime probe results.
Use explicit HTML-to-native mapping. Do not use AppKit HTML import or an
embedded browser for this feature. An `NSTextView` destination does not
establish importer behavior; deleting attachments after import is too late
to prevent import-time requests.

### Sealed-object placeholders are grammar input

Pipeline step 1 implements an application grammar extension for opaque object
identities. Neither published dialect defines this extension; the current
renderer substitutes text, and the substitute's character class changes parsing.

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

Implement sealed-object syntax as an explicit application extension to each
pinned dialect, using typed atoms and source positions through the parser
adapter and composer. R1 specifies and tests their delimiter, autolink, table
and resource-metadata behavior. Law 0001's one-position rule does not prescribe
a Markdown punctuation class. Do not rely on alphanumeric substitution alone.
Report ordinary-text conformance separately from object-containing fixtures
and native-output restrictions.

Under ADR-0059's accepted resource policy, a destination containing an object
or its placeholder (Markdown image, HTML `src`/`srcset`, CSS `url()`) is refused,
mirroring `safeURL`'s link refusal. R1/R3 also specify object treatment inside
attributes, comments and unsupported HTML. An object inside alt text remains
part of rendered order; R5 specifies its visible and copied position in every
image state, including after loading.

### Separate image state from rendering state

Implement the accepted route boundary with the following image-state
requirements. R4/R5 supply the detailed specifications and tests:

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

Record request, consent, cache and copy-state behavior with the corresponding
production implementation and tests. The route requirements do not establish
runtime privacy or persistence results. Unsupported local, relative and
non-network destinations use deterministic fallback; parsing their syntax
does not authorize loading them.

<a id="research-gates"></a>

## Delivery workstreams and verification

R0 is closed by the maintainer-directed accepted amendments above. R1–R5 are
accepted production implementation workstreams and may proceed in parallel
where their code dependencies permit. Complete their specifications and tests
alongside application integration, not as a separate research-only project or
another approval of the feature. R6 records integrated release validation.

Acceptance does not mark any outstanding work complete. A library label,
prototype test count or screenshot is not a substitute for the specified
application evidence. The loader depends on the R4 request contract and R5
authorization/lifecycle checks; those checks remain prerequisites for enabling
production requests, not for implementing the parser, renderer or preferences.

| Workstream | Required implementation | Completion evidence |
| --- | --- | --- |
| **R0 — Authority reconciliation (closed 2026-10-16)** | Enacted at the maintainer's instruction: D-09 scope, separate resource-destination authorization, bounded route inventory, ledger exclusion and source/preview clarification. | Accepted [UI/UX successor](2026-1016-ui-ux-decisions.md), [ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md) and [Law 0001 amendment](../../law/0001-sealed-object.md#amendments), plus principles amendment E and reciprocal ADR histories. Detailed request policy and transport experiments remain R4 work; no runtime result follows from R0. |
| **R1 — Parser integration** | Integrate pinned parsers targeting CommonMark 0.31.2 and published GFM 0.29-gfm, not an assumed common base version. Compare official examples independently of the dependency's edited corpus. Test single/double/triple tildes, extended autolink punctuation/email/protocol cases, Apple inline attributes, standard table cells without nonstandard spans, HTML comments, `textarea` block boundaries, and the P-versus-P/S punctuation definition (CommonMark 0.31.2 example 354). Fixture sealed atoms adjacent to emphasis delimiters, extended autolinks, table pipes and link/image brackets in both dialects. | Pinned versions, source revisions and official corpus provenance/checksums; AST or test-only canonical HTML comparison with enumerated mismatches; replacement of nonstandard span expectations; sealed-object grammar extension; dependency/license/notice review. Report ordinary-text conformance, object-containing fixtures and native restrictions separately. |
| **R2 — Preferences and invalidation** | Implement the preview-only dialect preference and the surface/precedence matrix above. Test the header toggle with All pages / Focused page only / Never. Preserve editor, note and file semantics. | Typed Settings picker, app-wide defaults storage, GFM fallback for unset/unknown values, restart coverage, and invalidation tests for selected and nonselected previews. |
| **R3 — Native HTML composition** | Integrate the bounded composer with Markdown parsing and native output. Cover mixed HTML/Markdown, cross-block scope, escaped text, malformed nesting, quoted `>`, comments, raw-text bodies and unsupported-element fallback. Exercise sealed atoms in attributes, omitted markup, destinations and comments. Use explicit native mapping, not AppKit HTML import. | Documented element/attribute/native-style mapping and URL policy, GFM-filter behavior, numeric depth/work limits, and application fixtures for object identity/order and text provenance. Instrument parsing/conversion itself for requests. |
| **R4 — Request contract and loader** | Specify and implement session/header behavior, schemes and ATS, URL credentials, cookies/authentication, referrer, proxies/intermediaries, redirects including cross-origin/downgrade, loopback/private-network destinations, relative/base URLs, cache/storage/logging, timeout/concurrency, streamed byte bounds, MIME validation, supported formats and decoded size. Refuse destinations containing sealed atoms or stand-ins. Keep the existing ATS configuration; a global exception needs a separate decision. Verify format support and decoded-size bounds on macOS 13.0, not only the build SDK; untrusted image data is decoded in-process. | Concrete request/consent policy, numeric limits, format list and lifecycle table recorded with the loader. Instrumented tests for pre-activation inactivity and every allowed/denied redirect and destination; document metadata exposure and other residual risks of authorized requests. Ephemeral session configuration alone is not request-isolation evidence. |
| **R5 — Native interactions and lifecycle** | Implement TextKit 1 image attachment cells beside sealed objects, in links/tables and multiselections, including alt-text objects. Implement ADR-0059's distinct destination-labelled Load Image control with unchanged link and promotion rules; ordinary text/link/image-body clicks do not load. Specify and test pointer/keyboard/VoiceOver mechanics. Exercise expiry between click/dispatch/redirect/completion, page close/switch, source replacement and preference changes during loading. | Exact text and pasteboard expectations for all image states and Services overloads; rendered order of alt-text objects in each state; keyboard/VoiceOver and nonselected-page activation behavior; stale-result rejection, request identity, and layout/scroll/minimap observations against the accepted law and ADR-0023. |
| **R6 — Integrated release validation** | Run pinned syntax fixtures, native policy tests, and AppKit interaction checks together; benchmark representative large/nested pages and large decoded images. Verify request counts across opening, scrolling, reparsing, resizing and retries. | Recorded commands/results, mismatch/restriction matrix, geometry and performance results, and manual interaction evidence. No inferred conformance or request-isolation result from screenshots alone. |

Primary standards consulted on 2026-10-16:
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and
[GFM 0.29-gfm](https://github.github.com/gfm/). They define different base
syntax in some cases; selecting current CommonMark plus GFM extensions does
not automatically implement the older published GFM grammar. Their examples
use HTML as a structural oracle; a test-only serializer/comparator is needed
for native parsing tests, not browser-equivalent AppKit screenshots.

## Implementation sequence

1. **Integrate parsing and composition in the application.** Introduce the
   explicit dialect/parser adapter and typed composer in the production preview
   path. Reuse useful lab code and fixtures, but test the actual renderer.
   Complete R1/R3 specifications, corpus comparisons and object-order coverage
   alongside this work. Do not substitute another isolated prototype for this
   integration.
2. **Wire preference and invalidation.** Add the typed picker under Code using
   the R2 storage and precedence contract. Use GFM for unset/unknown values.
   Pass dialect explicitly through rendering and reseeding, invalidate both
   model caches and views, and remeasure selected/nonselected previews without
   relaunch. Keep source editor, note and file behavior unchanged.
3. **Integrate restricted HTML and inert images.** Render the defined native
   subset, preserve text provenance and composed-copy semantics, and retain
   sealed-object positions. Finish native unloaded-state controls and tests
   while R4/R5 request and lifecycle work proceeds.
4. **Connect explicit image actions.** Implement the R4/R5 contract, numeric
   limits, bounded decoding, lifecycle checks and transport tests before
   enabling real requests. Publish geometry after image updates and reject
   obsolete dispatch/results. No loader action is authorized by display refresh.
5. **Complete R6 before release.** Extend
   [`MarkdownPreviewRenderingTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewRenderingTests.swift)
   and
   [`CheckpointMarkdownPreviewTests.swift`](../../../shell/Tests/CompanionKitTests/CheckpointMarkdownPreviewTests.swift),
   add syntax-corpus, settings, transport and lifecycle tests, and perform
   the AppKit interaction pass.

## Delivery record

Each entry records what the application code does after a slice and which
tests exercise it. An entry is evidence for its slice only: it closes no
workstream, satisfies no acceptance criterion by itself and changes no
accepted scope. Documents edited in the same slice are not evidence for it.

### 2026-10-16: R3 composition in the rendered page preview

**Integrated.** The composition prototype in
[`tools/markdown-preview-lab/composition/`](../../../tools/markdown-preview-lab/composition/)
(commit `62510ea9`) now runs in the application as
[`HTMLTokenizer.swift`](../../../shell/Sources/CompanionKit/HTMLTokenizer.swift),
[`HTMLEntities.swift`](../../../shell/Sources/CompanionKit/HTMLEntities.swift)
and [`PreviewComposer.swift`](../../../shell/Sources/CompanionKit/PreviewComposer.swift).
`MarkdownPreviewRenderer` in
[`MarkdownPreviewView.swift`](../../../shell/Sources/CompanionKit/MarkdownPreviewView.swift)
feeds one `PreviewCompositionStream` per rendering with every Markdown text
leaf, code span and code block, soft and hard break, Markdown trait
(emphasis, strong, strikethrough, inline code), raw HTML leaf, image and
flushed object, then maps the runs to native attributes. The lab package is
now a frozen research record; the application copy is the one maintained.

**Not integrated.** R1's parser adapter: the parser is still swift-markdown
0.9, with its Apple core grammar, table spans and attached GFM extensions,
and sealed objects are still ASCII tokens. R2's preference: the view always
composes as GFM, and `MarkdownPreviewView.render(_:dialect:limits:)` takes
CommonMark only from tests. R4 requests and R5 image controls, lifecycle and
accessibility: there is no Load Image control and no image attachment.

#### Composition contract as implemented

| Area | Implemented behavior |
| --- | --- |
| Formatting elements | `em` and `i` italic, `strong` and `b` bold, `del`, `s` and `strike` strikethrough, `code` code font with background; `span` scopes with no style. Markdown traits and HTML elements combine on the same text. |
| Block elements | `p` and `div` open and close with a line break where the output is not already at one, and open no scope: an omitted `</p>` costs no depth, and `</p>` or `</div>` ends no formatting. `br` emits U+2028, a line break inside its paragraph. |
| Scope | One element stack for the whole document, across Markdown blocks. A closing tag closes the nearest matching element and every element opened after it; an unmatched closing tag is literal text; an unclosed element lasts to the end of the page. |
| Links | `a` takes its first `href`, entity decoded once, refused if any `href` contains an object or placeholder; the renderer then applies the Markdown link policy (`safeURL`: http and https with a host, or mailto with its address alone). Inside a Markdown link, accepted or refused, no HTML link applies. Image text never takes a link. |
| Images | Markdown images and `img` become a `PreviewImageDescriptor` (rendering ordinal and address, `unreviewed`, `refused(missing)` or `refused(sealedObject)`) under `NSAttributedString.Key.previewImage`, over the fallback text in secondary color. Markdown alt text is the plain text of its inlines. For `img`, the first `alt` supplies text and every other attribute supplies only its objects, in attribute order. `srcset`, `style`, `poster`, `data` and every other attribute produce no output beyond their objects. Empty alt text leaves no visible text and no descriptor range. |
| Unsupported markup | Any other element is escaped as its literal tag text, without entity decoding, and its children compose. Malformed tags, declarations and processing instructions are literal. |
| GFM filter | Under GFM, `title`, `textarea`, `style`, `xmp`, `iframe`, `noembed`, `noframes`, `script` and `plaintext` tags are escaped before the element policy: the tag's own spelling becomes text, entity decoded once and never tokenized again, and opens no raw-text scope. |
| CommonMark raw text | Under CommonMark composition, `script`, `style`, `xmp`, `iframe`, `noembed` and `noframes` bodies are raw text, `title` and `textarea` bodies decode entities, and `plaintext` runs to the end. The scope spans raw HTML leaves; Markdown structure inside an open raw-text body fails the composition. |
| Comments | A valid comment leaves no text; each object inside it is emitted in place. |
| Whitespace | HTML text decodes entities once, then collapses each run of ASCII whitespace to one space, with none at a line start or after a space. Markdown text, literal tag text and raw-text bodies keep their spaces. The renderer trims an HTML block's leading and trailing whitespace and emits no paragraph for an HTML block left empty. |
| Entities | `amp`, `lt`, `gt`, `quot`, `apos`, `nbsp` and terminated decimal or hexadecimal references; a zero, surrogate or out of range scalar becomes U+FFFD; anything else stays as written. This is not the HTML5 table. |
| Objects | Each object reaches the composer once, as an opaque identity. Each event's output gives exactly its input objects in the same order, or the composition fails. Objects in attributes, comments and refused addresses are emitted at their element; an object never takes a link. A Markdown image's address takes only objects inside the image's own source: an object in a reference definition stays at the definition, and the image's address is refused because the token spelling stays in it. A token spelled twice outside an address fails the composition. |
| Limits | Per rendering: 1,000,000 input scalars, 4,000,000 events, 1,000,000 raw HTML tokens, combined Markdown and HTML depth 64, 2,000,000 output runs. Input is the working bound; Markdown traits cost events but no input, so the event budget is four times the input budget. |
| Failure | Any composition error, a limit included, renders the page's source text in one plain paragraph style with each object as its attachment, in source order. |

Changes from the prototype: HTML text whitespace collapses and `br` emits
U+2028 (the lab preserved raw whitespace and emitted a newline); `p` and
`div` open no scope (the lab pushed elements for them); composition is
streamed, with each event's output objects checked against its input
objects, instead of one preflight over a complete event array; the event,
token and run budgets are larger; the failure presentation above is new.

#### Tests

| File | Coverage |
| --- | --- |
| [`HTMLTokenizerTests.swift`](../../../shell/Tests/CompanionKitTests/HTMLTokenizerTests.swift) | The lab's tokenizer and entity suite, unchanged: quoted attributes, comments, raw-text scanning, typed objects, limits and 512 randomized source reconstructions. |
| [`PreviewComposerTests.swift`](../../../shell/Tests/CompanionKitTests/PreviewComposerTests.swift) | The lab's composer suite with the changed whitespace, `br` and block-element expectations, plus the stream API. |
| [`MarkdownPreviewCompositionTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewCompositionTests.swift) | Application fixtures through `MarkdownPreviewView`: exact text and style for the subset, mixed HTML and Markdown, cross-block scope, escaped text, unsupported and disallowed tags, comments, HTML links, image descriptors, objects in addresses and their copy order, reference images, Markdown links inside HTML links, HTML block layout, the dialect difference, the limit fallback, a long ordinary page, and a URL-load probe. |
| [`MarkdownPreviewRenderingTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewRenderingTests.swift) | Existing renderer fixtures; the HTML expectation now matches the composed output. |

The URL-load probe registers a `URLProtocol` with the shared URL loading
system, renders, lays out and draws a page of resource-bearing Markdown and
HTML, and records no request; a control request through `URLSession.shared`
is recorded by the same probe. It does not observe sessions with their own
configuration, out-of-process loading or raw sockets.

An adversarial review of the slice, before this record, executed inputs
against the renderer and found: a reference image whose definition followed
later text assigned that text's objects to itself, which removed them from
later raw HTML, so an `a` or `img` address with an object became
`unreviewed` and a tag broken by an object became formatting; an event
budget of 100,000 that sent ordinary pages over about 10,000 formatted lines
to the plain fallback; and an HTML link applying over a refused Markdown
link. Each is fixed above and has a fixture in
`MarkdownPreviewCompositionTests`. The review found no image attachment, no
token text in output, no crash on its malformed inputs and no quadratic path.

Run from `shell/` on 2026-10-16, macOS 27.2 on arm64, Apple Swift 6.4:
`swift test --filter "HTMLTokenizerTests|PreviewComposerTests|MarkdownPreviewCompositionTests|MarkdownPreviewRenderingTests|CheckpointMarkdownPreviewTests|DayScrollPreviewRenderingTests|PageModelPreviewRenderingTests"`,
196 tests, 0 failures. Not run: the full shell suite (left to CI), a macOS
13 runtime, a manual interaction pass and VoiceOver. An offscreen render of
a sample page was inspected by eye; it is not evidence beyond that page.

#### Open R3 items

- Review this contract against the acceptance criteria, in particular the
  whitespace, block-element, unclosed-element and failure choices.
- Under CommonMark composition an inline raw-text tag, as in
  `Use <script> and *this*`, fails the whole page into the plain fallback.
  Decide the raw-text scope of inline tags before R2 exposes CommonMark.
- Objects in Markdown link destinations, in link and image titles and in
  reference definitions still reach the output through the renderer's flush
  and catch-up path, so they appear at the next object or block end rather
  than at their element. R1's typed atom replaces this path.
- A force click on a link, Markdown or now HTML, goes through
  `quickLook(with:)`, which asks only `mayReadOut`, not the ⌘-click route.
  Whether AppKit's link preview there fetches the page is unverified; check
  it on hardware against Law 0001's link row and ADR-0023.
- The HTML5 named-reference table, numeric control remapping and an
  explicit empty-alt fallback and descriptor carrier (R5) are not
  implemented.

## Acceptance criteria

These delivery checks follow the accepted policy boundary and implementation
contracts above. They remain to be demonstrated; acceptance is not evidence
of implemented behavior.

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

## Required implementation specifications

Record concrete implementation details with production code and tests in the
corresponding workstream. These are delivery obligations under this accepted
plan, not draft feature suggestions or a further approval round. A change to
the accepted scope or governing law/ADR still requires its own recorded decision.

1. **Parser (R1):** dependency versions and source pins, official corpus
   provenance, mismatch disposition, removal of nonstandard table spans, and
   per-dialect sealed-atom grammar. An extension switch alone is not evidence.
2. **Preferences (R2):** typed storage, GFM fallback, restart behavior,
   header/scope precedence, live invalidation and geometry tests for the surface
   matrix above. Preserve source-editor, note and file semantics.
3. **Composition (R3):** element/attribute/native mappings, text provenance,
   raw-text handling, recovery rules, GFM filter order, URL treatment,
   unsupported-markup fallback and numeric work limits.
4. **Requests (R4):** explicit session and destination policy, consent
   revocation, redirect checks, cache/storage/logging behavior, format list,
   numeric transport/decoder limits and instrumented boundary tests before
   enabling the loader. Acceptance does not supply unmeasured numeric limits
   or decoder/runtime evidence.
5. **Native lifecycle (R5):** image states and occurrence identity, alt/object
   placement, exact copy/Services output, pointer/keyboard/VoiceOver activation,
   stale-work rejection, fitting, layout and scroll anchoring.
6. **Release evidence (R6):** integrated conformance, native interactions,
   transport counts, performance and deployment-runtime results. Report actual
   commands and unperformed checks separately.

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
that policy and close R0. They do not supply runtime evidence.

The maintainer's subsequent instruction accepts this plan for production
implementation and removes its research-only starting restriction. The
[research results](2026-1016-markdown-preview-research-results.md) remain evidence
only for their recorded experiments. This acceptance update changes
documentation, not application behavior; R1–R6
completion evidence must come from the implementation and validation work.
No application, transport, macOS 13 runtime or accessibility test was performed
to accept this document.
