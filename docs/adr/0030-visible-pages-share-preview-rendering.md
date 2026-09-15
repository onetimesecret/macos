---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0030: Visible pages share preview rendering

- **Status:** accepted
- **Date:** 2026-09-14
- **Supersedes in part:** [ADR-0024](0024-caret-only-automation-and-display-only-color.md), specifically amendment C's restriction of syntax color to the editable page, and [ADR-0029](0029-betlang-source-language-detection-behind-the-existing-c-abi.md), specifically its exclusion of quiet roll pages from display-only highlighting. Their remaining decisions stand.
- **Depends on:** [ADR-0022](0022-fence-regions-coalesce-stamps-in-display.md) for fence-region display grouping.

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The time roll can show several readable pages at once. One page is mounted in the
editor and the others are quiet, noninteractive renderings. The prototype made
those quiet pages flat base-font ink. Moving the editor therefore changed a
page's heading weight, code font, fence wash, links, and token color even though
the page's bytes and its visible place in the roll had not changed.

ADR-0024 allowed fenced-code color only on the editable page and expressly sent
requests to color another surface back to that decision. ADR-0029 retained that
surface boundary when it allowed an accepted inferred language to drive
bare-fence highlighting. The visible roll is now the workload that reopens both
boundaries. The quiet regions show the readable page itself, not a chip excerpt,
ledger residue, thumbnail, or concealed-content representation. Treating them
as recognition surfaces makes presentation depend on keyboard ownership rather
than on the document being shown.

Established IDE behavior informs the choice without becoming a project
guarantee. Visual Studio Code documents language identifiers as the basis for
language support and editor grammars, and says its color theme affects “the
editor highlighting colors”; IntelliJ IDEA says file types link a language
service to files and that its Language Defaults highlighting applies “to all
supported programming languages by default.” Interpretation: mainstream code
editors attach language and highlighting presentation to a document or file
type, not to whether that editor currently owns the caret. Both products also
provide a plain-text file/language mode. That supports stable rendering across
visible pages and an explicit plain-ink escape hatch; it does not require every
read surface to become an editor.

Primary product documentation consulted on 2026-09-14:

- [Visual Studio Code: Language Identifiers](https://code.visualstudio.com/docs/languages/identifiers)
- [Visual Studio Code: Themes](https://code.visualstudio.com/docs/getstarted/themes)
- [IntelliJ IDEA: File type associations](https://www.jetbrains.com/help/idea/settings-file-types.html)
- [IntelliJ IDEA: Colors and fonts](https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html)

## Decision

Add one persisted `Preview rendering` preference with three scopes:

- **All pages** is the default. The mounted page and every visible quiet roll
  page receive the same display-only Markdown structure and syntax-token color.
- **Focused page only** preserves the earlier roll behavior. The mounted page
  receives preview rendering and quiet pages remain flat.
- **Never** renders mounted and quiet pages as plain ink. It bypasses Markdown
  presentation and whole-file Source-mode presentation rather than merely
  removing token colors.

“Focused page” means the page mounted in the one editor, whether that editor is
editable or is the read-only resting glance. Keyboard focus itself does not
change rendering.

Preview rendering remains markup-preserving. It may change fonts, foreground
colors, paragraph metrics, links, list indentation, and fence wash, but it never
changes page bytes. Select-all-copy and sealing continue to use exactly what was
typed. Chip faces remain non-secret attachments and are not syntax-colored.
The ledger, minimap, chips, and other recognition surfaces remain outside this
amendment.

Quiet pages receive heading and code typography, link and list treatment, fence
wash, and syntax-token color under **All pages**. They do not receive block
created/modified labels or spacing reserved for those labels: those temporal
annotations belong to the mounted editor rather than to Markdown preview.
The minimap continues to render geometry only and no text.

A manually accepted or inferred rendering language is page-owned display state,
not coordinator-owned focus state. It applies to the mounted page and, under
**All pages**, its quiet rendering for the lifetime already assigned to that
choice. It does not rewrite a bare fence or become persisted content. Explicit
fence info strings remain part of the page and continue to take precedence.

The existing `Syntax highlighting` setting remains the narrower color control.
Turning it off removes token colors while preserving Markdown structure, code
typography, fence wash, and file render mode. **Never** is the deliberate
plain-text-mode equivalent and therefore has the broader effect described
above.

Every rendering input must invalidate affected quiet renderings: page content,
typeface, preview scope, syntax-highlighting state, and page-owned manual or
inferred language state. A visible refresh must remeasure the roll and publish
updated geometry so the rail minimap retains truthful proportions.

## Consequences

- A visible page no longer changes presentation merely because the editor moves
  to or away from it. **All pages** follows the document-oriented convention of
  code editors and is the default for unset preferences.
- Readers who prefer the prototype's quieter roll retain it explicitly through
  **Focused page only**. Readers who want no Markdown or Source presentation
  have **Never**.
- Quiet rendering can no longer be represented by an attributed string alone
  when fence wash is enabled. Its rendering contract must also carry derived
  fence regions, while excluding editor-only block labels and their spacing.
- Manual and inferred language choices must move behind a page-keyed presentation
  seam shared by mounted and quiet rendering. This state remains display-only
  and does not alter the artifact.
- Restyling all visible quiet pages costs a page-wide Markdown scan and, where
  applicable, tokenization. Caching remains necessary, and every declared
  rendering dependency must participate in invalidation.
- The setting changes presentation only. Quiet pages remain noneditable and
  nonselectable; clicking one still promotes it into the single editor. Chips do
  not expose sealed content, and no new content crosses a process or network
  boundary.
- ADR-0024's caret-only automation and display-only byte-preservation rules
  stand. ADR-0029's inference architecture, release gates, and exclusion of
  recognition surfaces other than quiet roll pages stand.

## Decision history

- 2026-09-14: Accepted. The visible time roll triggered ADR-0024's condition for
  reconsidering color outside the editable page. This record partially
  supersedes ADR-0024 and ADR-0029 only for visible quiet roll rendering.
  Implementation on `fix/focus-gate` remains incomplete until quiet rendering
  carries fence geometry without block-label spacing, page-owned language state
  reaches quiet pages, and every rendering dependency invalidates the cache.

## Eject triggers

- On minimum supported hardware, changing preview scope or moving the editor
  repeatedly blocks the main thread for more than two 60 Hz frames while the
  bounded roll contains representative large pages. Revisit eager all-page
  rendering, cache granularity, or the default; do not weaken byte preservation.
- Quiet syntax color or fence wash makes inactive pages compete with the mounted
  page strongly enough that repeated usability observation cannot identify the
  editing target without relying on the caret. Revisit emphasis or the default
  scope while retaining stable document rendering.
- A page-owned manual or inferred language survives longer than readers expect
  and repeatedly produces stale or misleading color after edits. Revisit its
  lifetime and invalidation boundary, not the rule that it remains display-only.
- Accessibility testing finds that the three scopes, token colors, or focused
  page distinction cannot be understood without color. Add non-color state or
  revise the presentation before release.
