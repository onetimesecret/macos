# PR 334 review follow-up

Final local recheck passed all 2,518 Swift tests: 393 OnetimePad and 2,125
CompanionKit. The first build of the new test annotations hit an SDK name
collision; qualifying `CompanionKit.PreviewTrait` corrected that test-only issue.
One subsequent full run failed three existing link-menu tests because their
native menu contained no `openLinkFromMenu:` item. With code unchanged, the
typography and menu suites passed together (92 tests), followed by the complete
2,518-test recheck. No menu fixture was modified or weakened, and the specific
AppKit/process-state cause was not established. Current-head CI is checked
separately after publication. Workspace formatting, whitespace and all 53 ADR
lint checks passed; Rust source and dependencies are unchanged from the prior
passing Rust checks.

## Second completed automatic follow-up

[CI](https://github.com/onetimesecret/macos/actions/runs/40571980021) and
[Claude](https://github.com/onetimesecret/macos/actions/runs/40571980097) passed
on `04b20a05244307b49b190302350c7bf3c635818b`. Claude confirmed all three
Copilot findings were addressed and reported no correctness blocker. This final
local follow-up addresses its two further resource-use suggestions:

- Production rendering opts out of composition diagnostic collection. Standalone
  composition keeps its existing default. Tests compare output and refusal
  semantics with collection enabled and disabled.
- Font conversion results are cached by retained base `NSFont` and trait set,
  independently of link strings or occurrence IDs. Count-based regressions check
  repeated styles, heading sizes and inherited code/bold/italic typography.

Other review items have explicit dispositions:

| Item | Disposition |
| --- | --- |
| Synchronous reseeding | The draft design record now explicitly describes the measured roughly half-second four-page batch and the main-actor limitation. Background parsing/cancellation is separate work. |
| Empty image ordinals | They count source occurrences, including invisible fallbacks. No loading control consumes those IDs in this PR. The design record explicitly defers descriptor anchors and accessible image presentation to R4/R5. |
| Display-style equality | Retained equality of displayed traits/address. Link occurrences remain distinct integer cache keys; a regression verifies equal displayed styles produce occurrence IDs `0,1,0,2` across nesting/restoration/repetition. Production font caching uses its own base-font/traits key. |
| Ordinary-suite performance cases | Retained. They also check parse shape, rendered text and unchanged reseeding. Together they took 0.826 seconds in the preceding full run, compared with about 61 seconds for CompanionKit. No reduction of that coverage was justified by this sample. |
| Separate input ceilings | The design record now distinguishes lexical source and decoded-event limits, including empty-fragment/object charging and tokenization checks. |
| Entity lookahead | The design record now states the 32-scalar cap; the existing exact-boundary regression remains. |
| Owned-helper optional release refactor | Deferred as optional style work. Both existing paths already use the same checked ownership helper; no ownership code change is needed. |
| UTF-8 temporary optimization | Deferred pending profiling of that specific copy. The allocation inventory already identifies the possible temporary C string. |
| Synthetic copy characters | Existing main at `3373e56f` already emits markers/tabs, U+2028 and U+200B through the rendered selection route. The design record makes this observation and the remaining product/accessibility review explicit, citing the accepted copy row without inferring approval of every character. |
| Attribution stripping | Declined again: configured TextProv attribution is retained. No repository-wide policy is changed. |

Second-batch local validation passed all 2,513 Swift tests: 393 OnetimePad and
2,120 CompanionKit. This includes the final inline raw-text fixtures, long-link
evaluation counts, image whitespace matrix and literal U+FFFC ink regression.
Rust sources and dependency resolution are unchanged from the first batch's
passing checks. Formatting, whitespace and all 53 ADR lint checks passed again.

## Automatic follow-up after the first batch

All seven checks passed on `b5d63c7fe653acc6130fe8f0b1f4f88316f2758b`:
[CI](https://github.com/onetimesecret/macos/actions/runs/40569722616) and
[Claude](https://github.com/onetimesecret/macos/actions/runs/40569722629).
The completed static review and three newly posted Copilot threads identified
three additional actionable issues. The second batch addresses them:

| Feedback | Disposition |
| --- | --- |
| Repeated long-link validation | Composer scopes have integer occurrence IDs. The renderer caches explicit accepted `NSURL` or refused results by occurrence, avoiding a long-string dictionary key per run. Nested/restored scopes reuse the same ID; distinct occurrences remain distinct. Count-based regressions cover long accepted/refused destinations with many child runs, both syntax forms and both dialects. |
| Image fallback whitespace | Whitespace state follows the final nonempty fallback part. Empty fallbacks leave the state unchanged. Regressions cover empty, trailing space, newline, line-separator and object-ending fallbacks for HTML and Markdown images. |
| Inline raw-text fidelity | Parser-decoded text and break/boundary events, including native block transitions, refuse an active CommonMark raw-text scope. The original-page fallback retains entity spellings and source breaks. Real-parser script and native thematic-break fixtures exercise the route; rawHTML-only chunks remain composable. |
| Empty image descriptor | An empty fallback remains invisible and produces no text-range descriptor. An anchor/placeholder design remains with image loading; inserting an invisible character now would change copied ink. |
| Entity-decoded U+FFFC | Retained ordinary text semantics. A renderer/selection regression verifies that `&#xFFFC;` becomes ink with no attachment attribute and is selected as ink. No authoritative requirement for replacing that literal character has been identified. |
| Tokenizer budget after charging | Retained shared charging before tokenization. Passing post-charge `remainingInput` would reject a valid leaf that just consumed its budget; the existing exact-boundary and cumulative-budget tests exercise this ordering. |
| NULL diagnostic severity | Retained fault-level reporting for the ABI/encoding/serialization/panic failure channel. The consumer distinguishes unavailable output without inferring its specific internal cause. |
| More input scans and synchronous rendering | Retained the measured behavior and explicit latency limitation. No asynchronous renderer or whole-operation erasure assertion is introduced. |
| TextProv attribution | Retained intentional U+E0101 attribution from the configured Markdown edit hook. Original third-party license text and executable source are checked separately. A repo-wide strip or attribution-policy change is outside this follow-up. |
| Task authorization prose | Removed the unnecessary authorization sentence from this repository record. Authorization comes from the chat, not repository instructions to reviewers. |

Copilot threads:
[link policy](https://github.com/onetimesecret/macos/pull/334#discussion_r4393166255),
[raw text](https://github.com/onetimesecret/macos/pull/334#discussion_r4393166314),
[image whitespace](https://github.com/onetimesecret/macos/pull/334#discussion_r4393166359).

This records code changes and dispositions for the
[initial Claude review](https://github.com/onetimesecret/macos/pull/334#issuecomment-6451110269)
of `f221e6db1302fca2d3f75d9e5ccdc766b44277de`. That review was static and
reported no blocking defect. Its observations are feedback, not authority for
product guarantees.

## Starting state

The PR branch matched the checkout and remote, with no unresolved merge or local
changes. GitHub account `delano` was verified. All seven checks passed on the
initial head: [CI](https://github.com/onetimesecret/macos/actions/runs/40566123967)
and [Claude](https://github.com/onetimesecret/macos/actions/runs/40566123869).
Formal reviews, inline threads and paginated inline comments were empty.

## First implementation batch

| Feedback | Disposition and evidence |
| --- | --- |
| Encoded mailto controls | The renderer checks the decoded path before clearing query and fragment. Tests cover Markdown and HTML in both dialects, encoded whitespace/control values, valid encoded non-ASCII and discarded query controls. No behavior of an external mail client was tested. |
| Ordered task numbering | Ordered task markers include their ordinal and checkbox. Hanging indentation accounts for the widest marker. Regressions cover non-1 starts, mixed task and ordinary items, nesting and shown-selection text. |
| Tokenizer memory representation | Private `UInt32` units replace the per-scalar enum array; object identities occupy a separate sparse array. Unicode scalars use their scalar values; object indices start at `0x110000`. Unicode, repeated/sparse object, raw-text and million-unit boundary tests exercise reconstruction and budgets. This compares storage shape, not measured peak resident memory. |
| Double input traversal | Budget accounting now occurs during unit construction. Empty text fragments and objects retain their one-unit cost. Array capacity grows during construction instead of a separate scalar-count/reserve pass; this tradeoff remains explicit. |
| Trapping name conversions | Case folding operates on validated Unicode scalar values, without narrowing to `UInt8` or truncating values. High-scalar and non-ASCII syntax tests retain literal output. |
| Recomputed style | Style is cached and refreshed at all six Markdown/link/HTML stack mutation sites. Tests cover repeated traits, nested/reused links and recovered HTML nesting. Existing composition fixtures remain unchanged. |
| Matched closing-tag object recovery | Recovery follows the scope pop. This is a no-op for accepted closing tags today; malformed object-bearing close tags remain literal and retain object order in the regression. |
| Decimal identity coupling | The decoder checks the atom table against exact input offsets and `String(index)` identities. Attachment lookup also requires canonical decimal spelling. Malformed identities, counts, duplicates and offsets are rejected with exactly-once buffer release tests. |
| Production serializer measurement | Added an opt-in FFI profile calling `content_json::markdown_json` and `companion_string_free`, comparing every returned byte with the document serialization. It includes production terminator checks, registry registration, document drop and free. The separate parser-stage profile remains explicitly synthetic; no crate dependency cycle was introduced. |
| Several large previews | Added a four-page offscreen reseed/layout batch using an isolated model with temporary state and the test-util ephemeral client. Unchanged rendering identities are reseeded again. This measures that synthetic batch, not a manually operated roll. |
| Token defaults | Both tokenizer and composer default to 1,000,000 tokens; explicit smaller budgets remain tested. |
| Release-helper branch | Retained. Both branches use the existing ownership helper; shortening it with another direct free call would conflict with the helper-only release invariant. |
| Empty dependency list | Removed the redundant `dependencies: []` entry. SwiftPM supplies the empty default. |
| Literal U+FFFC | The existing Rust regression treats an undeclared U+FFFC as ordinary text. Only declared offsets name attachments. The plane-16 collision check addresses a separate placeholder representation. |
| Image accessibility description | Deferred for accessibility/design review. Alt text currently appears as text with an image descriptor; no VoiceOver result or new text-range accessibility design is asserted. |
| Native HTML policy and five source-position goals | Retained as review topics. The allowlist is a proposal, and the five ignored Rust goals remain paired with stock-behavior tests. No review comment adopts that policy or fixes those goals. |

## Explicit composition behavior

The new side-by-side regression preserves these existing choices for review:

| Token kind | Entity and whitespace behavior |
| --- | --- |
| Ordinary raw HTML text | Decode supported entities once and collapse ASCII HTML whitespace |
| Malformed literal markup | Preserve source entity spellings and whitespace |
| Unsupported well-formed tag | Preserve source entity spellings and whitespace |
| GFM-filtered tag | Decode supported entities once; retain whitespace |

CommonMark raw HTML chunks keep the tokenizer's raw-text handling. Parser-decoded
text, break/boundary events and native block starts during an active raw-text
element now refuse composition and use the complete original-page fallback.
Objects remain references in that state. This avoids using already-decoded
Markdown events to reconstruct an inline script or textarea body. Real-parser
regressions cover entity spellings, newlines and hard breaks.

## Production-path measurement

The opt-in FFI profile used ten release-build samples per synthetic page/dialect.
The encode interval includes both serializer passes, buffer checks, registration
and document drop; the free interval includes deregistration and buffer cleanup.
Parsing and the expected-byte comparison are outside these intervals.

| Input / objects | Dialect | Encode/register/drop mean us | Free mean us |
| --- | --- | ---: | ---: |
| 7,700 bytes / 100 | CommonMark | 293 | 31 |
| 7,700 bytes / 100 | GFM | 205 | 19 |
| 77,000 bytes / 1,000 | CommonMark | 1,567 | 152 |
| 77,000 bytes / 1,000 | GFM | 1,333 | 130 |

These are measurements on one Mac, not latency limits. No measured end-to-end
speed improvement is inferred from the smaller tokenizer units or cached style.

```sh
cargo test --locked --release -p companion-ffi markdown_json_production_profile -- --ignored --nocapture
scripts/test-shell.sh --filter MarkdownIntegrationPerformanceTests
scripts/test-shell.sh
```

## Validation and review rounds

Rust checks passed: 96 Markdown tests with five existing source-position goals
and one manual profile ignored; 13 Markdown FFI tests and 11 JSON ownership tests,
with the new FFI profile ignored in ordinary runs. The production profile passed
when run explicitly. All-target Markdown/FFI clippy, workspace formatting,
whitespace checks and all 53 ADR lint checks passed.

The focused Swift run exposed one new fixture that expected adjacent text parts
without the tokenizer's established coalescing. Its expectation was corrected;
tokenization behavior was unchanged. The complete shell suite then passed
2,505 tests: 393 OnetimePad and 2,112 CompanionKit.

In that run, four offscreen 62,000-byte previews took 503.63 ms together to
reseed and assign their attributed text. Subsequent layout calls took 0.003 ms
and unchanged reseeds took 0.005 ms; these separate calls do not isolate any
layout work already performed during reseeding. The synthetic single-page
sample took about 87 ms for a complete 62 KB render and 32 ms for parse/decode.
Main-actor latency for multiple changed large pages remains visible for review;
there is no asynchronous rendering change in this batch.

No installed app was launched, replaced, quit or reset. Remote checks and the
requested Claude follow-up rounds are verified separately on each pushed head.
