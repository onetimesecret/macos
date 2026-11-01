# PR 334 final feedback and UI validation

This is an execution record for PR 334, not a specification or a new product guarantee.

## Final Claude review dispositions

The ready-for-review run [40576859806](https://github.com/onetimesecret/macos/actions/runs/40576859806)
completed successfully on `9c3305c7`. Its suggestions were checked against code and tests.

| Feedback | Disposition |
| --- | --- |
| Unclosed inline HTML frames consume the combined depth budget | Retain the bounded original-page fallback. A default-limit regression accepts 64 unclosed spans and refuses 65/100 across block events in both dialects. Dropping older frames could silently change link/formatting scopes. |
| Encoded delimiters/control characters in web hosts | Decode the encoded host once and refuse those values before producing an interactive link. Valid IPv6 literals, including scoped addresses, remain covered. |
| Repeated first href/src decoding | Decode matching attributes in one pass, retaining the first destination and refusing object-bearing duplicates. |
| Equality excludes occurrence bookkeeping | Synthesized equality now includes the occurrence. Tests distinguish repeated scopes and restoration of the same scope. |
| Newlines inherit an unclosed link | Generated block separators have no link; subsequent content resumes the active scope. |
| Duplicate owned-JSON helper call | Retain the small branch. Both paths delegate ownership and default release to the shared helper; no new core-string free site is introduced. |
| Default performance tests print timings and run large specimens | Default tests retain small output/cache regressions. Large measurements now require `PREVIEW_PROFILE=1`. |
| Ordered-list arithmetic relies on comrak's number limits | Validate ordered ranges recursively during decoding and refuse malformed responses before rendering. Boundary/overflow fixtures also verify one release. |
| Two renderer observation closures | Use one internal diagnostic callback with typed cases. |
| GFM-filtered script-body styling and unclosed anchors across blocks | Existing explicit native-composition policies remain. Tests pin both behaviors; no script execution path is added. |
| Attribution in notices/prose | Preserve intentional TextProv attribution and unchanged license blocks. Cargo.lock and notice headings remain available as version references. |

## UI and accessibility execution

Tests construct their own windows without ordering them on screen. Every model uses
a temporary state directory and the test-util in-memory credential client through
`PageModel.Seams(stateDirectory:client:)`. Copy/link fixtures use their own pasteboards
and recorded URL-opening callbacks. No installed app is launched, replaced, quit or reset.

The new runtime checks exercise the native accessibility action on the preview toggle,
text-area role, character count, rendered text, attributed text, selected text/ranges,
keyboard selection extension, screen-frame geometry, focus transfer and source restoration.
A sealed fixture exposes its rendered object character without the fixture's sealed text.
Existing mounted-roll tests exercise copy, links, expiry, no-drag behavior, promotion,
table selection, page transitions and toggle/source restoration.

Four bitmap specimens were inspected at 320 and 640 points in Aqua and Dark Aqua:
headings, native HTML traits, Unicode text, ordered tasks, a table, a quote/link,
image alt text and fenced code. That inspection found a real layout defect: default
NSTextBlock widths collapsed quote/code lines to roughly one character after a table.
Quote/code blocks now use the available width. A regression checks line-fragment widths,
nested quotes, table transitions and narrow/wide/narrow resizing.

The first new accessibility fixture assumed a button action's Boolean result represented
its state and a document-movement command reset the read-only selection. It now checks the
actual toggle state/focus and sets an explicit insertion point before extending selection.
No production accessibility behavior was changed to satisfy the fixture.

This validation does not include VoiceOver speech/rotor operation or an installed-app
walkthrough. Image-load controls and image-specific accessible roles remain the separate
R4/R5 work; this PR renders alt text and inert descriptors.

```sh
PREVIEW_QA_ARTIFACTS=/tmp/pr334-ui scripts/test-shell.sh --filter 'PreviewComposerTests|MarkdownPreviewRenderingTests|MarkdownBridgeTests|CheckpointMarkdownPreviewTests|MarkdownIntegrationPerformanceTests'
PREVIEW_PROFILE=1 scripts/test-shell.sh --filter MarkdownIntegrationPerformanceTests
scripts/test-shell.sh
git diff --check
python3 scripts/lint-adrs.py docs/adr
```

The full local suite passed 2,549 tests: 393 OnetimePad and 2,156 CompanionKit tests;
two additional opt-in profiles were skipped. The focused native/preview run passed 255
tests with the native profile skipped. Both opt-in profiles passed when requested explicitly.
Whitespace checks and all 53 ADR lint checks passed. Current-head remote checks are
recorded separately in the PR description.
The inspected images are local artifacts under `/tmp/pr334-ui`; they are not shipped assets.

## Final-head review decisions

The [review on 4127490a](https://github.com/onetimesecret/macos/actions/runs/40615156351)
confirmed the earlier fixes and raised additional non-blocking follow-ups.

- Keep synchronous rendering within PR B's existing per-page limits. This is an explicit
  implementation tradeoff: unchanged renderings are reused, but several newly changed
  large pages can still pause the main actor for about half a second. Background rendering
  and a latency-based roll budget need a separate design; no responsiveness guarantee is
  inferred from scalar ceilings or cache counts.
- Cache heading sizing, table-header traits and base attributes as well as inline fonts.
  Hoist immutable character sets. List marker measurement remains one operation per item,
  needed for actual hanging-indent width; ordered marker strings generally differ.
- Keep original objects in a final unclosed CommonMark raw-text scope. Refusing decoded
  text/break events avoids reconstructing lost raw spelling; an object already has exact
  identity. Both composer-stream and real-parser regressions cover an object-only tail.
- Retain fault classification for malformed bridge data and duplicate composer identities.
  The existing real repeated-reference regression explicitly observes the Rust parser's
  duplicateObject refusal before composition, then verifies original-page fallback with
  the same attachment once. Parser duplicateObject is already logged at info level.
  This does not prove every possible composer invariant unreachable; it distinguishes the
  documented parser refusal from an internal consistency failure.
- An empty-alt image can have no rendered text range. Trimming a whitespace-only HTML
  block can remove its descriptor, leaving a gap before the next visible source occurrence.
  A regression records that numbering. R4/R5 must introduce image anchors without adding
  synthetic copied ink; this PR does not implement image loading or accessible image controls.
- IPv6 tests continue to require interactive valid addresses. Literal validation accepts
  bracketed and unbracketed host representations rather than relying on one Foundation
  representation; this does not represent a runtime test on macOS 13 hardware.
- Entity decoding uses a fixed small name table, not the HTML5 table, and bounded lookahead:
  at most 31 name scalars between ampersand and semicolon. Tight and loose lists currently
  share spacing. These are fidelity limits; no conformance beyond the tested subset is asserted.
- Swift's withCString temporary and decoded Swift documents receive no explicit wipe.
  The input Data view references the Rust response buffer until the shared helper releases
  it; separately allocated Foundation decoder temporaries are not explicitly wiped here.
  Rust zeroizing owners do not extend to independent Swift copies. Avoiding a UTF-8 copy
  would not wipe the input String or decoded tree.
- Preserve intentional TextProv attribution in the changelog and notice prose.

## Final tokenizer follow-up

The review on 9c1e10ee found one additional fidelity defect: scanning quotes immediately
after a stray less-than character could consume later closing/formatting tags. The tokenizer
now distinguishes a plausible markup prefix before entering the quote-aware tag scan.
Token-level and real-parser fixtures preserve the literal comparison/apostrophe and apply
subsequent native formatting, including an intervening original object.

Compact storage now branches explicitly on the object-marker range before subtracting its
base. UTF-8 length is computed before the FFI string closure. The shared document input
budget is still charged before each raw-HTML leaf uses its own tokenizer ceiling; the
existing exact-limit tests remain the executable explanation for that arrangement.

No timing assertion is added: the opt-in profile remains a measurement rather than a
machine-dependent acceptance gate. The 100,000-cell AppKit case is no longer accepted:
native tables now use separate column/cell budgets; background/latency work remains.
There is no new visible refusal affordance: fallback displays the original page and copying
uses what that fallback shows. That interaction distinction remains explicit for future
preview-state design. No notice attribution is stripped and no comment-only changes replace
the regressions or the recorded policies.

## Attribute-state and address coverage follow-up

The review of 1373d076 found the residual malformed-attribute form of the quote-scanning
defect. The tag pre-scan now follows attribute-name/value grammar, sharing the unquoted-value
predicate with parsing. Only a valid equals/value boundary can begin a quoted value.
Malformed attribute names or unquoted values use the first greater-than delimiter;
valid quoted values can still include greater-than characters. Declaration/PI scanning
remains separate. Token-level matrices and a real-parser fixture include original objects
and subsequent formatting.

The private compact representation keeps four-byte units and now substitutes U+FFFD for
an invalid scalar unit rather than aborting. Normal construction still starts from typed
Unicode scalars; the existing boundary/source-reconstruction cases continue to exercise it.

A 328-case rendered matrix checks raw/encoded format characters in web hosts and mailto
addresses, both syntaxes/dialects and allowed non-ASCII examples. Every case checks label
output and a policy evaluation, so literal unparsed input cannot satisfy the regression.
Unreachable HTML/code marker paths and redundant object-loop block resets were removed.

The proposed design table now states literal/filtered entity behavior, literal whitespace
boundaries, duplicate-address attributes and object scope metadata explicitly. The allocation
record distinguishes the borrowed Data view over the Rust response from independent Swift
and Foundation allocations. Native table budgeting is measured below; background rendering and visible refusal-state design remain follow-ups.

## Native table budget and boundary measurement

NativePreviewLimits defaults to eight columns and 1,024 cumulative cells per page.
Headers and padded empty cells count, including cells in separate tables. Checked
multiplication/addition precedes native table allocation. A refused native budget uses
the complete original-page fallback and info-level logging. Parser/composition budgets
are unchanged; this new guard applies only to actual native tables.

Six regular regressions cover exact/over-limit cells, column limits, multiple tables,
original object identity/order, non-table/CommonMark input and arithmetic overflow.
The opt-in profile uses a PageModel with temporary state and in-memory credentials.
It constructs an accepted eight-column, 128-row table (1,024 cells; 5,561 source bytes).
Reseeding took 51.46 ms at 320 points; the following explicit layout took 0.003 ms.
Resizing/layout at 640 points took 40.31 ms. Reseeding can include eager layout.
Used widths were 285.5/605.5 points within 296/616-point text containers; glyph geometry
checks passed. Both boundary bitmap specimens were inspected, in addition to the four
general light/dark specimens. This is a sample on one Mac, not a timing gate.

The profile ran under an isolated 90-second process timeout and completed normally.
The 100,000-cell native allocation was not attempted; it is outside the new native
budget. Large ordinary pages still render synchronously, so background work and a
general latency budget remain separate design work.

```sh
PREVIEW_NATIVE_TABLE_PROFILE=1 PREVIEW_QA_ARTIFACTS=/tmp/pr334-native-table-ui scripts/test-shell.sh --filter MarkdownPreviewRenderingTests/testOptInNativeTableRenderAndLayoutProfile
```

The proposed fidelity table also names self-closing slash spacing and CommonMark
title/textarea RCDATA entity handling. Encoded-host validation/opening keeps its
recorded policy. The cached empty-trait font conversion and bounded opt-in test
counter remain small implementation notes; no production counter change is needed.
