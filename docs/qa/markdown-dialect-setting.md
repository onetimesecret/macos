# PR C: Markdown dialect preference

This implementation record follows PR B (#334), merged as
`2c3a056c8908543d4fbb3563243ad6d7dd42dd51`. It records implementation and
validation observations, not additional product requirements.

## Sequence after PR B

The [Markdown preview design plan](../spec/design/2026-1016-markdown-dialects-and-preview.md)
proposes the dialect preference and render invalidation, followed by image
loading and integrated preview validation. [Issue #332](https://github.com/onetimesecret/macos/issues/332)
also separates the dialect setting (R2) and image work (R4/R5) from the parser
and native composition changes.

- PR C implements the typed dialect preference and updates open previews.
- Subsequent image work needs explicit load controls, request and redirect
  policy, resource limits, cancellation, expiry and cache decisions, plus
  image-specific accessibility and copy behavior.
- The five existing parser source-position goals and broader synchronous
  rendering latency work remain follow-ups. The research lab and legacy draft
  #328 are separate from PR C.

## Implementation choices

The picker is in Settings → Code, beside Preview rendering, using the existing
navigation. It offers GitHub Flavored Markdown and CommonMark. The setting uses
the model's existing form-factor defaults, keyed by `markdownDialect` with raw
values `gfm` and `commonMark`. Missing and unknown values resolve to GFM without
rewriting the stored value during initialization.

A distinct change posts a dedicated model-scoped dialect notification. Mounted
rolls reparse selected and unselected rendered previews and remeasure them.
Source and quiet-page rendering caches are reused. Each preview's seed
comparison includes the dialect as well as its source rendering identity, and
the reseed call requires an explicit dialect. Newly opened previews use the
current choice.

This choice applies to rendered previews. Editor-side hybrid styling, the
Preview rendering scope, and each page's preview toggle remain independent.
Image loading, parser versions, native table limits and HTML composition policy
are unchanged in this slice.

## Validation scope

The setting tests use temporary state directories and in-memory credentials.
They cover missing and unknown settings, restoration into a new model, one
dialect notification per distinct change, source cache reuse, and independent
scope and page toggles.
Mounted-roll tests switch both ways across selected and unselected previews in
two rolls, exercise all four GFM extensions through the setting, open a preview
after a change, and check chip identity and original source text after refresh.

The Settings test renders its own unshown window at the existing 480-by-390
point size for both selections. It checks content width against the viewport
and scrolls to the document's end, checking that the final content is reachable.
SwiftUI controls were not exposed by the runner's in-process accessibility tree,
so accessible activation is unverified. No installed application is launched,
replaced, quit or reset. VoiceOver speech and rotor operation are outside this
test scope.

## First Claude review dispositions

The [first review](https://github.com/onetimesecret/macos/pull/335#issuecomment-6461130884)
ran against `2309b108`. Its static notes were checked against the Swift sources.

| Item | Disposition |
| --- | --- |
| 1: Default dialect on reseed | Removed the default; every caller names its dialect. |
| 2: Implicit stored raw values | Explicit `commonMark` and `gfm` values, with literal-value regressions. |
| 3: Imposed-frame assertion | Replaced with width and end-of-scroll geometry checks; inspected both Settings selections. |
| 4: Adjacent picker styles | Both use inline style. |
| 5: Stale comments | Removed the obsolete reseed comment. The quiet-cache notification remains specific to cache invalidation; dialect changes now have their own notification. An extra initialization comment is unnecessary. |
| 6: Cache guard | Positive same-source/same-dialect early return. |
| 7: Unaffected quiet renderings | Dedicated notification refreshes previews without discarding their source or quiet-page caches; tested. |
| 8: Toggle parity | Added an explicit pre-toggle state assertion. |
| 9: Raw HTML reachability | Added mounted GFM → CommonMark → GFM raw-text coverage. |
| 10: Hybrid editor difference | Retained the documented rendered-preview scope; hybrid styling is separate work. |
| 11: Prose marks | Retained intentional TextProv attribution; no stripping or repository-wide changes. |

Initial validation: 2,558 local Swift tests passed, with two opt-in profiles
skipped. All seven CI/review checks passed at `2309b108`. After the first review
fixes, the focused suite passed 153 tests, with two opt-in profiles skipped.

## Second Claude review dispositions

The second review at `09ceeca2` found no production correctness defect. Its
additional coverage suggestions produced a mounted preview-height regression
using a table taller than the page minimum, plus an open inline CommonMark
raw-text fixture with a later heading. The latter shows the complete original
source under CommonMark; switching back to GFM restores the formatted headings.
This characterizes the existing composition-refusal fallback, which becomes
selectable through the new setting.

The static `render` helper retains its GFM default for direct fixture calls;
the first review explicitly allowed that default. The production view seam
requires a dialect, and both mounted-preview routes pass the model's choice.
The helper does not read a model preference. Changing all direct fixture calls
would add no coverage of the preference boundary.

Removed the obsolete observation comment. Separate seed fields, additional
initialization/type comments, and hybrid editor interpretation remain unchanged:
there is no asynchronous or throwing gap between the seed assignments, literal
storage values are tested, and editor styling is outside this slice. Intentional
TextProv marks remain in prose.

The full Swift suite after the production fixes passed 2,560 tests, with two
opt-in profiles skipped. Both new/expanded targeted checks passed. Subsequent
changes add test coverage and this record; production behavior is unchanged.

## Ready-state review dispositions

Both automatic Claude reviews and CI passed at `f506354f`. The ready-state review
identified two small hardening changes: model observations now register before
the scroll-clip guard, and parser/raw-text/filter decisions use exhaustive
dialect switches. A detached-roll regression exercises notification delivery
without a clip; the focused hardening suite passed 154 tests.

The ownership guard remains. Accepted [ADR-0036](../adr/0036-editing-presentations-are-mutually-exclusive.md)
states exactly: “Ordinary switches show no non-owner glance.” The primary
editor and panel root views mount content only for the selected presentation.
The ownership round-trip regression now changes dialect in the incoming owner
and checks that returning to the original presentation uses the current dialect
and restores its original editor/storage. It does not establish installed-window
visibility through a manual walkthrough.

The same review's threading note does not apply: `PageModel` is already declared
`@MainActor`. Comment-only suggestions remain deferred under the repository's
review-response instructions. The static fixture-renderer default and hybrid
editor scope retain the dispositions above. Selection UX and a manual VoiceOver
pass remain separate validation/polish work. Greptile reported its missing-label
skip; it supplied no code finding and is not one of this PR's CI/Claude checks.

Final local validation after this hardening: 2,562 Swift tests passed (393
OnetimePad and 2,169 CompanionKit), with two opt-in profiles skipped. Whitespace
checks and all 53 ADR lint checks passed.
