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

This is an implementation record, not acceptance of the draft's open decisions.
PR B follows the Rust parser foundation merged in PR 333. It reuses the native
composition work from PR 328 at `439bf529417429c58e30562bd5da58416e6134c3` and
replaces its C parser adapter with a Rust JSON decoder. The Swift package no
longer depends on swift-markdown or swift-cmark and introduces no vendored parser.

R1 now parses through `companion_markdown_parse_json` using comrak 0.57.0. Corpus
comparisons remain in Rust: 652/652 CommonMark examples and 664/677 combined
GFM parser/writer outputs, with all differences enumerated by the existing tests.
The Swift adapter tests the shared golden document, every refusal shape, embedded
NULs, original UTF-16 offsets, output-buffer release and original-page fallback.
Five upstream source-position goals remain ignored and paired with stock-behavior
tests; integration does not silently treat those goals as fixed.

R3 composes the AST's raw HTML into native text under the proposed element policy.
It preserves attachments through composition, keeps resource descriptors inert,
and preserves significant spaces at HTML-block edges. GFM remains the default;
CommonMark is exercised through explicit test calls. R2's dialect setting and
R4/R5 image loading remain separate work.

The [integration QA record](../../qa/markdown-preview-rust-integration.md) lists
the proposed allowlist, fixture rebaselines, known source-position limitations,
allocation lifetimes, reproducible performance commands and validation results.

### Native HTML fidelity recorded for review

| Case | Implemented representation |
| --- | --- |
| Unsupported or malformed tag literal | Preserve entity spellings and whitespace. A stray less-than prefix is ordinary data, so subsequent real tags still compose. |
| GFM-filtered tag | Decode the supported references once while preserving the literal tag's whitespace. Its body can contain independently styled native HTML. |
| Literal whitespace boundary | Literal/filtered text is not collapsed. A trailing tab or carriage return need not suppress a following collapsed space; this differs from browser whitespace handling. |
| Duplicate href/src attributes | Use the first value, including an empty one; an object in any matching duplicate refuses the whole address. |
| Object scope metadata | Composition can record scope style on an object. Native attachment output uses independent base attributes and omits link styling. |
| Self-closing slash spacing | The slash must be adjacent to the tag end: `<br />` parses; `<br/ >` and `<a href="x" / >` stay literal. |
| CommonMark raw-HTML title/textarea bodies | Tags stay literal while RCDATA body references decode once. Inline structured events that lost raw spelling still use the original-page fallback. |

The [final validation record](../../qa/pr334-final-validation.md) describes the isolated
AppKit accessibility and interaction checks and inspected visual specimens. VoiceOver
speech/rotor operation and an installed-app walkthrough were not exercised.

### Known integration limits for review

Native table construction has separate defaults of eight columns and 1,024 cumulative
cells per page, including headers and padded empty cells across tables. Exceeding either
uses the complete original-page fallback. Parser and composition ceilings remain separate.
The accepted 1,024-cell boundary was measured and inspected at 320/640 points; results
and commands are in the final validation record. These measurements are not latency gates.

Reseeding remains synchronous on the main actor: Rust parsing, Swift decoding
and native attributed-text composition happen in the layout path. A synthetic
batch of four changed 62 KB previews took about 0.5 seconds on the development
Mac. This is a known interaction-latency limitation. Cached unchanged renderings
avoid reseeding; this PR does not introduce background parsing or cancellation.

The parser's source-scalar limit and the composer's decoded-event input limit
are separate ceilings with the same default value. The composer also charges
empty fragments and object identities; passing the parser does not imply that
composition fits its limits. Tokenization has its own per-leaf check after the
shared composition charge. Raw HTML character references use the supported
named subset and a 32-scalar lookahead cap, rather than HTML5's full table.

Empty image fallbacks remain invisible and have no text-range descriptor, while
their source occurrence is counted. Anchor/placeholder behavior and image-specific
accessibility presentation remain R4/R5 decisions. No VoiceOver validation result
is recorded. Copy output includes rendered list markers/tabs, line separators and
the thematic-break character; those representations also appear in the renderer
at main revision `3373e56f5344879b4c72db4bf522ee3d64e23d31`.

The accepted [Law 0001 preview-copy row](../../law/0001-sealed-object.md#appkits-text-routes)
states exactly: "the rendered text between the objects is the ink, never the source markdown".
The observed representation above is not evidence of a separate accepted decision
about every synthetic character or its accessibility presentation. Those details
remain explicit review topics.
