---
id: 2026-1016-markdown-dialects-and-preview
title: Markdown dialects and restricted preview
status: draft
dated: 2026-10-16
surfaces: OnetimePad Markdown preview and Settings
---

# Markdown dialects and restricted preview

## Status and scope authority

The maintainer approved the following direction in the design conversation
on 2026-10-16: CommonMark and GitHub Flavored Markdown are selectable in
Settings; GFM is the default; supported HTML formatting renders without
scripts or embedded browser content; remote images load only after an
explicit click. The approval was: “Yes agreed. Please capture the plan at
docs/spec/design”.

This document records that agreed scope and a proposed implementation plan.
Its draft status applies to the technical details and open decisions, not
to whether the dialect setting is wanted. Target requirements below are not
a description of shipped behavior or evidence of validated guarantees.
This document does not amend an accepted behavior law or ADR.

## Summary

The Markdown preview supports CommonMark and GitHub Flavored Markdown
(GFM), selected through a Markdown dialect setting. The selection changes
parsing semantics, not merely visual styling. Both dialects use a restricted
preview with supported HTML formatting and click-to-load remote images.

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

The intended user-facing location is **Settings → Editor → Markdown dialect**.
The options are **CommonMark** and **GitHub Flavored Markdown**, with GFM as
the default. Mapping this location onto the existing settings navigation is
an implementation detail, not authorization to reorganize Settings.

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

A setting change reparses and refreshes open previews. The page-header
preview toggle remains separate from the dialect choice, as does the
existing **Preview rendering** scope control.

### Restricted HTML

Both dialects render supported HTML formatting without scripts or embedded
browser content. This is an intentional restriction, not unrestricted HTML
rendering or a promise of browser-equivalent output. The supported element
and attribute set, and the treatment of unsupported markup, require a
reviewed allowlist before implementation is complete.

The same remote-image rule applies to an image expressed in Markdown or
supported HTML. HTML rendering is not a second path for automatic resource
loading.

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

These existing requirements apply to both dialects. Their copy, link,
expiry, selection, and reader routes need regression coverage when the
renderer changes. A new image-loading route requires review against that
law; permission to load an image is not permission to bypass the page's
existing read gates.

The accepted [ADR-0030, Decision](../../adr/0030-visible-pages-share-preview-rendering.md#decision)
states:

> Every rendering input must invalidate affected quiet renderings: page content,
> typeface, preview scope, syntax-highlighting state, and page-owned manual or
> inferred language state.

Interpretation for this plan: dialect is an additional rendering input.
This is not evidence that dialect invalidation is already implemented.

## Baseline before PR B

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
- [`PageModel.swift`](../../../shell/Sources/CompanionKit/PageModel.swift)
  owns presentation preferences, the per-page preview toggle, and rendering
  cache invalidation.
- [`SettingsSections.swift`](../../../shell/Sources/CompanionKit/SettingsSections.swift)
  places the existing preview and syntax-highlighting controls in
  `CodeSettingsView`.

## Proposed implementation sequence

The following steps are proposals, not settled dependency or storage decisions.

1. **Define the parser contract.** Pin the CommonMark and GFM specification
   versions and fixture sets. Demonstrate different parse results for the
   extension syntax in the table before integrating the setting. Assess a
   configurable parser integration or an upstream change; styling an
   already GFM-parsed tree is not a CommonMark implementation. Any dependency
   change includes version, license, and third-party-notice review.
2. **Add the preference.** Introduce a typed dialect value and a picker
   following the existing settings patterns. Proposed storage is one
   app-wide preference using the model's existing defaults mechanism, with
   GFM for an unset or unrecognized value. Restart behavior and the final
   storage scope need confirmation.
3. **Integrate parsing and invalidation.** Pass the dialect explicitly into
   rendering and include it in cache dependencies. Refresh selected and
   nonselected previews and remeasure the roll after a change. Review
   editor-side Markdown styling separately rather than silently changing
   its regex-based interpretation.
4. **Complete dialect rendering.** Cover the selected standards' constructs,
   including GFM extended autolinks and disallowed raw HTML. Preserve sealed
   attachment identity and order through parsing and rendering. Record
   intentional output restrictions separately from syntax support.
5. **Add restricted HTML.** Define and review the allowlist and unsupported
   markup fallback. Render permitted formatting without an executable or
   embedded browser surface. Exercise malformed and nested HTML and image
   references inside HTML.
6. **Add click-to-load images.** Define consent and request policy before
   introducing a fetch path. Review redirects, URL schemes, credentials,
   resource limits, cancellation, page expiry, and cache lifetime. Keep
   loaded image attachments distinct from sealed objects and define their
   copy behavior.
7. **Validate the integrated preview.** Extend
   [`MarkdownPreviewRenderingTests.swift`](../../../shell/Tests/CompanionKitTests/MarkdownPreviewRenderingTests.swift)
   and
   [`CheckpointMarkdownPreviewTests.swift`](../../../shell/Tests/CompanionKitTests/CheckpointMarkdownPreviewTests.swift),
   add settings and loading tests, and perform an AppKit interaction pass.
   Rendering screenshots alone do not demonstrate parser conformance or
   the absence of automatic requests.

## Acceptance criteria

- Both named dialects are selectable; an unset selection uses GFM.
- CommonMark does not interpret GFM-only tables, task markers,
  strikethrough, or extended autolinks as extensions.
- GFM renders those extensions according to the selected GFM version.
- A dialect change refreshes every open preview without a relaunch.
- Supported HTML formatting renders under the reviewed allowlist; scripts
  and embedded browser content do not execute or appear as active content.
- A remote image produces no fetch before its explicit load action,
  whether its source syntax is Markdown or HTML.
- Shared CommonMark constructs retain their expected structure in both modes.
- Sealed-object order and the accepted preview copy, link, reader, expiry,
  and no-drag behavior remain covered in both modes.
- The user-facing description distinguishes dialect support from the
  intentional HTML and resource-loading restrictions.

These criteria describe delivery requirements; no implementation or test
result is recorded by this document.

## Open decisions

1. **Conformance target:** exact CommonMark and GFM versions, parser choice,
   and treatment of nonstandard features such as table spans. Closed by
   parser evaluation and a reviewed conformance matrix against
   [CommonMark](https://spec.commonmark.org/) and
   [GFM](https://github.github.com/gfm/).
2. **Preference scope:** restart behavior, app-wide versus page-owned state,
   and whether the setting also governs hybrid editor styling, quiet pages,
   notes, and file-backed previews. Closed by a surface and preference review;
   the agreed baseline is the rendered page preview.
3. **HTML policy:** permitted elements and attributes, URL treatment, and
   unsupported-markup fallback. Closed by a reviewed allowlist.
4. **Image policy:** per-image versus broader consent, repeat loading,
   request metadata and credentials, redirects, caching, resource limits,
   formats, local/relative destinations, failure states, and copying a
   loaded image. Closed by a loading-policy and interaction review.
5. **Interaction review:** image-load behavior when a page expires, switches,
   or closes during a request, plus keyboard and VoiceOver activation.
   Closed by explicit lifecycle requirements and acceptance coverage.

## PR B delivery record for review

T󠄁h󠄁i󠄁s󠄁 i󠄁s󠄁 a󠄁n󠄁 i󠄁m󠄁p󠄁l󠄁e󠄁m󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁,󠄁 n󠄁o󠄁t󠄁 a󠄁c󠄁c󠄁e󠄁p󠄁t󠄁a󠄁n󠄁c󠄁e󠄁 o󠄁f󠄁 t󠄁h󠄁e󠄁 d󠄁r󠄁a󠄁f󠄁t󠄁'󠄁s󠄁 o󠄁p󠄁e󠄁n󠄁 d󠄁e󠄁c󠄁i󠄁s󠄁i󠄁o󠄁n󠄁s󠄁.󠄁
P󠄁R󠄁 B󠄁 f󠄁o󠄁l󠄁l󠄁o󠄁w󠄁s󠄁 t󠄁h󠄁e󠄁 R󠄁u󠄁s󠄁t󠄁 p󠄁a󠄁r󠄁s󠄁e󠄁r󠄁 f󠄁o󠄁u󠄁n󠄁d󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 m󠄁e󠄁r󠄁g󠄁e󠄁d󠄁 i󠄁n󠄁 P󠄁R󠄁 3󠄁3󠄁3󠄁.󠄁 I󠄁t󠄁 r󠄁e󠄁u󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 n󠄁a󠄁t󠄁i󠄁v󠄁e󠄁
c󠄁o󠄁m󠄁p󠄁o󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁 w󠄁o󠄁r󠄁k󠄁 f󠄁r󠄁o󠄁m󠄁 P󠄁R󠄁 3󠄁2󠄁8󠄁 a󠄁t󠄁 `439bf529417429c58e30562bd5da58416e6134c3` a󠄁n󠄁d󠄁
r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁s󠄁 i󠄁t󠄁s󠄁 C󠄁 p󠄁a󠄁r󠄁s󠄁e󠄁r󠄁 a󠄁d󠄁a󠄁p󠄁t󠄁e󠄁r󠄁 w󠄁i󠄁t󠄁h󠄁 a󠄁 R󠄁u󠄁s󠄁t󠄁 J󠄁S󠄁O󠄁N󠄁 d󠄁e󠄁c󠄁o󠄁d󠄁e󠄁r󠄁.󠄁 T󠄁h󠄁e󠄁 S󠄁w󠄁i󠄁f󠄁t󠄁 p󠄁a󠄁c󠄁k󠄁a󠄁g󠄁e󠄁 n󠄁o󠄁
l󠄁o󠄁n󠄁g󠄁e󠄁r󠄁 d󠄁e󠄁p󠄁e󠄁n󠄁d󠄁s󠄁 o󠄁n󠄁 s󠄁w󠄁i󠄁f󠄁t󠄁-󠄁m󠄁a󠄁r󠄁k󠄁d󠄁o󠄁w󠄁n󠄁 o󠄁r󠄁 s󠄁w󠄁i󠄁f󠄁t󠄁-󠄁c󠄁m󠄁a󠄁r󠄁k󠄁 a󠄁n󠄁d󠄁 i󠄁n󠄁t󠄁r󠄁o󠄁d󠄁u󠄁c󠄁e󠄁s󠄁 n󠄁o󠄁 v󠄁e󠄁n󠄁d󠄁o󠄁r󠄁e󠄁d󠄁 p󠄁a󠄁r󠄁s󠄁e󠄁r󠄁.󠄁

R󠄁1󠄁 n󠄁o󠄁w󠄁 p󠄁a󠄁r󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 `companion_markdown_parse_json` u󠄁s󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁m󠄁r󠄁a󠄁k󠄁 0󠄁.󠄁5󠄁7󠄁.󠄁0󠄁.󠄁 C󠄁o󠄁r󠄁p󠄁u󠄁s󠄁
c󠄁o󠄁m󠄁p󠄁a󠄁r󠄁i󠄁s󠄁o󠄁n󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 i󠄁n󠄁 R󠄁u󠄁s󠄁t󠄁:󠄁 6󠄁5󠄁2󠄁/󠄁6󠄁5󠄁2󠄁 C󠄁o󠄁m󠄁m󠄁o󠄁n󠄁M󠄁a󠄁r󠄁k󠄁 e󠄁x󠄁a󠄁m󠄁p󠄁l󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁 6󠄁6󠄁4󠄁/󠄁6󠄁7󠄁7󠄁 c󠄁o󠄁m󠄁b󠄁i󠄁n󠄁e󠄁d󠄁
G󠄁F󠄁M󠄁 p󠄁a󠄁r󠄁s󠄁e󠄁r󠄁/󠄁w󠄁r󠄁i󠄁t󠄁e󠄁r󠄁 o󠄁u󠄁t󠄁p󠄁u󠄁t󠄁s󠄁,󠄁 w󠄁i󠄁t󠄁h󠄁 a󠄁l󠄁l󠄁 d󠄁i󠄁f󠄁f󠄁e󠄁r󠄁e󠄁n󠄁c󠄁e󠄁s󠄁 e󠄁n󠄁u󠄁m󠄁e󠄁r󠄁a󠄁t󠄁e󠄁d󠄁 b󠄁y󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 t󠄁e󠄁s󠄁t󠄁s󠄁.󠄁
T󠄁h󠄁e󠄁 S󠄁w󠄁i󠄁f󠄁t󠄁 a󠄁d󠄁a󠄁p󠄁t󠄁e󠄁r󠄁 t󠄁e󠄁s󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 s󠄁h󠄁a󠄁r󠄁e󠄁d󠄁 g󠄁o󠄁l󠄁d󠄁e󠄁n󠄁 d󠄁o󠄁c󠄁u󠄁m󠄁e󠄁n󠄁t󠄁,󠄁 e󠄁v󠄁e󠄁r󠄁y󠄁 r󠄁e󠄁f󠄁u󠄁s󠄁a󠄁l󠄁 s󠄁h󠄁a󠄁p󠄁e󠄁,󠄁 e󠄁m󠄁b󠄁e󠄁d󠄁d󠄁e󠄁d󠄁
N󠄁U󠄁L󠄁s󠄁,󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁 U󠄁T󠄁F󠄁-󠄁1󠄁6󠄁 o󠄁f󠄁f󠄁s󠄁e󠄁t󠄁s󠄁,󠄁 o󠄁u󠄁t󠄁p󠄁u󠄁t󠄁-󠄁b󠄁u󠄁f󠄁f󠄁e󠄁r󠄁 r󠄁e󠄁l󠄁e󠄁a󠄁s󠄁e󠄁 a󠄁n󠄁d󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁-󠄁p󠄁a󠄁g󠄁e󠄁 f󠄁a󠄁l󠄁l󠄁b󠄁a󠄁c󠄁k󠄁.󠄁
F󠄁i󠄁v󠄁e󠄁 u󠄁p󠄁s󠄁t󠄁r󠄁e󠄁a󠄁m󠄁 s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁-󠄁p󠄁o󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁 g󠄁o󠄁a󠄁l󠄁s󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 i󠄁g󠄁n󠄁o󠄁r󠄁e󠄁d󠄁 a󠄁n󠄁d󠄁 p󠄁a󠄁i󠄁r󠄁e󠄁d󠄁 w󠄁i󠄁t󠄁h󠄁 s󠄁t󠄁o󠄁c󠄁k󠄁-󠄁b󠄁e󠄁h󠄁a󠄁v󠄁i󠄁o󠄁r󠄁
t󠄁e󠄁s󠄁t󠄁s󠄁;󠄁 i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 s󠄁i󠄁l󠄁e󠄁n󠄁t󠄁l󠄁y󠄁 t󠄁r󠄁e󠄁a󠄁t󠄁 t󠄁h󠄁o󠄁s󠄁e󠄁 g󠄁o󠄁a󠄁l󠄁s󠄁 a󠄁s󠄁 f󠄁i󠄁x󠄁e󠄁d󠄁.󠄁

R󠄁3󠄁 c󠄁o󠄁m󠄁p󠄁o󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 A󠄁S󠄁T󠄁'󠄁s󠄁 r󠄁a󠄁w󠄁 H󠄁T󠄁M󠄁L󠄁 i󠄁n󠄁t󠄁o󠄁 n󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 t󠄁e󠄁x󠄁t󠄁 u󠄁n󠄁d󠄁e󠄁r󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁p󠄁o󠄁s󠄁e󠄁d󠄁 e󠄁l󠄁e󠄁m󠄁e󠄁n󠄁t󠄁 p󠄁o󠄁l󠄁i󠄁c󠄁y󠄁.󠄁
I󠄁t󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁r󠄁v󠄁e󠄁s󠄁 a󠄁t󠄁t󠄁a󠄁c󠄁h󠄁m󠄁e󠄁n󠄁t󠄁s󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 c󠄁o󠄁m󠄁p󠄁o󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 k󠄁e󠄁e󠄁p󠄁s󠄁 r󠄁e󠄁s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁 d󠄁e󠄁s󠄁c󠄁r󠄁i󠄁p󠄁t󠄁o󠄁r󠄁s󠄁 i󠄁n󠄁e󠄁r󠄁t󠄁,󠄁
a󠄁n󠄁d󠄁 p󠄁r󠄁e󠄁s󠄁e󠄁r󠄁v󠄁e󠄁s󠄁 s󠄁i󠄁g󠄁n󠄁i󠄁f󠄁i󠄁c󠄁a󠄁n󠄁t󠄁 s󠄁p󠄁a󠄁c󠄁e󠄁s󠄁 a󠄁t󠄁 H󠄁T󠄁M󠄁L󠄁-󠄁b󠄁l󠄁o󠄁c󠄁k󠄁 e󠄁d󠄁g󠄁e󠄁s󠄁.󠄁 G󠄁F󠄁M󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁;󠄁
C󠄁o󠄁m󠄁m󠄁o󠄁n󠄁M󠄁a󠄁r󠄁k󠄁 i󠄁s󠄁 e󠄁x󠄁e󠄁r󠄁c󠄁i󠄁s󠄁e󠄁d󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁 t󠄁e󠄁s󠄁t󠄁 c󠄁a󠄁l󠄁l󠄁s󠄁.󠄁 R󠄁2󠄁'󠄁s󠄁 d󠄁i󠄁a󠄁l󠄁e󠄁c󠄁t󠄁 s󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁d󠄁
R󠄁4󠄁/󠄁R󠄁5󠄁 i󠄁m󠄁a󠄁g󠄁e󠄁 l󠄁o󠄁a󠄁d󠄁i󠄁n󠄁g󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 w󠄁o󠄁r󠄁k󠄁.󠄁

T󠄁h󠄁e󠄁 [i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 Q󠄁A󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁](../../qa/markdown-preview-rust-integration.md) l󠄁i󠄁s󠄁t󠄁s󠄁
t󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁p󠄁o󠄁s󠄁e󠄁d󠄁 a󠄁l󠄁l󠄁o󠄁w󠄁l󠄁i󠄁s󠄁t󠄁,󠄁 f󠄁i󠄁x󠄁t󠄁u󠄁r󠄁e󠄁 r󠄁e󠄁b󠄁a󠄁s󠄁e󠄁l󠄁i󠄁n󠄁e󠄁s󠄁,󠄁 k󠄁n󠄁o󠄁w󠄁n󠄁 s󠄁o󠄁u󠄁r󠄁c󠄁e󠄁-󠄁p󠄁o󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁 l󠄁i󠄁m󠄁i󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁,󠄁
a󠄁l󠄁l󠄁o󠄁c󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 l󠄁i󠄁f󠄁e󠄁t󠄁i󠄁m󠄁e󠄁s󠄁,󠄁 r󠄁e󠄁p󠄁r󠄁o󠄁d󠄁u󠄁c󠄁i󠄁b󠄁l󠄁e󠄁 p󠄁e󠄁r󠄁f󠄁o󠄁r󠄁m󠄁a󠄁n󠄁c󠄁e󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁s󠄁 a󠄁n󠄁d󠄁 v󠄁a󠄁l󠄁i󠄁d󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 r󠄁e󠄁s󠄁u󠄁l󠄁t󠄁s󠄁.󠄁
