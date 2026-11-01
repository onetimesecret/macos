# Rust Markdown preview integration

## Follow-up after PR #336

PR #337 now uses the user-selected vendored comrak Rust runtime subset. All five
source-position goals are active; definition/title/quote positions and repeated
reference objects have corrected expectations through Rust, FFI, and Swift.
The earlier stock-comrak limitations below describe the PR B baseline, not the
current follow-up implementation. See the [vendor guide](../../crates/markdown/patches/README.md)
and [current validation](markdown-followup-validation.md).

This draft records implementation observations and remaining decisions for PR B
of [issue 332](https://github.com/onetimesecret/macos/issues/332), following
[PR 333](https://github.com/onetimesecret/macos/pull/333). It does not establish
additional product guarantees.

## Source and scope

The branch starts at merged main `3373e56f5344879b4c72db4bf522ee3d64e23d31`.
The native composition source is draft PR 328 at
`439bf529417429c58e30562bd5da58416e6134c3`: `PreviewComposer`, `HTMLTokenizer`,
`HTMLEntities`, `MarkdownDocument`, the native renderer and their tests. The C
adapter, vendored parsers, research labs and unrelated changes are excluded.

`MarkdownParser` calls the Rust ABI, decodes refusal envelopes before documents,
and uses the existing direct `decodeOwnedJSON` allocation/free helper. GFM is
the shipping default. Tests pass CommonMark explicitly; the dialect setting and
image loading remain separate work.

## Existing authority

Accepted [Law 0001's preview copy row](../law/0001-sealed-object.md#appkits-text-routes)
states exactly:

> the rendered text between the objects is the ink, never the source markdown, and each object goes by reference, in rendered order

Its preview drag row states exactly:

> no drag starts from a preview, with an object in the selection or not

Accepted [ADR 0012 Amendment 1](../adr/0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval)
states exactly:

> All three complete-payload writes are core-side. The Swift shell asks the
> core to write to a named destination and never receives the sealed payload.

Interpretation for this implementation: parsing consumes the existing visible
page string and U+FFFC attachment offsets. It does not request a resolved sealed
value. The existing preview copy, link, reader and expiry routes continue through
the coordinator and core. Tests exercise those routes; no broader erasure or
network-observability guarantee is inferred from them.

## Native composition policy proposed for review

| Input | Implemented output |
| --- | --- |
| `em`, `i`, `strong`, `b`, `del`, `s`, `strike`, `code` | Native font or text decoration traits |
| `span` | Scoped content; CSS and event attributes are ignored |
| `a` | Address descriptor; renderer accepts HTTP, HTTPS and address-only mailto, refusing web userinfo and object stand-ins. The first matching attribute supplies the value; an object in any duplicate refuses the destination. |
| `br`, `p`, `div` | Native line/block boundaries |
| `img` and Markdown images | Alt text, original objects and inert image descriptors |
| Comments | Omit comment text and recover its objects |
| Other elements | Unsupported/malformed tag markup retains entity spellings and whitespace. GFM-filtered tags decode supported entities once and retain whitespace; filtering precedes the native allowlist. |
| CommonMark raw-text elements | Literal body treatment, with composition fallback for incompatible structured events |

There is no browser view, HTML importer or image-fetch implementation in this
composition path. This is a code observation, not evidence that the proposed
allowlist is accepted. Nonbreaking spaces, en spaces and explicit line separators
are preserved at HTML-block edges; trimming only removes ASCII HTML whitespace.

## PR 333 follow-ups

| Item | Disposition |
| --- | --- |
| Repeated reference source-position refusal | The real CommonMark fixture `[r]: /u{obj}\n| a |\n| - |\n\n[x][r] [y][r]` returns `duplicateObject`. Rendering uses the complete original page, with the same attachment once and no partial composition. It is an expected fallback diagnostic. |
| Other source-position goals | The five ignored Rust goals and their stock-comrak pins remain. Swift tests explicitly pin current definition/title and quote placement, including movement after later text. This remains a known limitation for review, rather than a source-position correction. |
| URL/object fixtures | GFM URLs can extend through an object. Their destination contains U+FFFC and becomes inactive while the attachment stays visible once. Angle autolinks retain their displayed object and inactive destination. |
| List-ending definitions | An object in a definition ending a list before an empty line renders after the list. A Swift AST regression pins this difference from the old C parser. |
| Reference expansion | Short pages can leave the third reference literal when comrak's expansion budget is exhausted. The migrated fixture pins that output. |
| Conservative table pre-scan | A non-table setext page can return `tableCellLimit` under a low budget. A Swift regression checks original-page fallback. The actual-cell check does not undo an earlier refusal. |
| NULL and decoding | `unavailable` distinguishes a null result from `invalidResponse` decoding failure and typed parser refusals. This ABI cannot identify which internal NULL cause occurred; the consumer does not invent a cause. Test-owned buffers verify release once on success and refusal/decoding paths. |
| xcframework | The supported shell-test script rebuilds both Apple architectures with test-util and copies the current header before Swift compiles. Generated bindings remain untracked. |
| Generic walker branches | The pinned dependency and four GFM extensions are unchanged. Audit opaque-node fallback arms before upgrading comrak or enabling another extension. |

## Allocation lifetime and performance

The parser is synchronous. It borrows the UTF-8 input for the call; Swift may
materialize a temporary C string. Rust allocates a normalized source, collision
values, a comrak arena, the document tree and output JSON. The normalized source,
collision values and registered output buffer use their existing wiping owners.
Comrak nodes, document strings and serde scratch use ordinary deallocation.
The output allocation remains live during direct Swift decoding and is released
afterward; there is no intermediate JSON `String` copy.

Decoded Swift strings, HTML tokenizer atoms and composition runs use ordinary
allocation. The AST and composer are local to one render; only the attributed
rendering and the existing source rendering are retained by the view. Reseeding
with the same rendering identity returns before parsing. A new source rendering
refreshes the preview. No whole-operation wiping assertion follows from this
inventory. Parser limits remain 1,000,000 input scalars, depth 64 and 100,000 table
cells by default, alongside the composer's event/token/output budgets.

The manual synthetic profile separates source scans/normalization, table scanning,
comrak plus the document walk, and JSON's count and write passes. It reproduces
the serializer's two-pass algorithm; it does not instrument the production FFI
registry or isolate allocator overhead. Ten release-build iterations on this Mac:

| Input / objects | Dialect | Source us | Table us | Parse/walk us | JSON count us | JSON write us |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 7,700 bytes / 100 | CommonMark | 50 | 0 | 270 | 42 | 70 |
| 7,700 bytes / 100 | GFM | 43 | 5 | 245 | 37 | 69 |
| 77,000 bytes / 1,000 | CommonMark | 422 | 0 | 2,195 | 363 | 679 |
| 77,000 bytes / 1,000 | GFM | 408 | 37 | 2,283 | 353 | 661 |

These are sample means on synthetic pages, not latency limits or an allocation
profiler result. Preallocation and both JSON passes are retained. The Swift
performance test separately times real FFI parsing/decoding and complete native
rendering on synthetic pages, without a timing assertion.

```sh
cargo test --locked --release -p companion-markdown preview_pipeline_profile -- --ignored --nocapture
scripts/test-shell.sh --filter MarkdownIntegrationPerformanceTests
scripts/test-shell.sh
```

The manual profile is an additional ignored test, separate from the five existing
ignored source-position goals. No app launch, installed-app replacement or manual
UI validation is part of these runs. Model-based tests use the suite's temporary
state and ephemeral credential seams.

## Validation record

- Focused Swift integration run before final additional regressions: 250 tests passed.
- Rust Markdown suite: 96 passed, five existing source-position goals and one manual profile ignored.
- Manual release profile: passed; measurements above.
- Markdown all-target clippy with warnings denied: passed.
- Full shell suite: 2,489 tests passed (393 OnetimePad and 2,096 CompanionKit), including the final additional regressions.
- Swift synthetic sample: 6,200 bytes took 3.35/3.43 ms to parse/decode and 9.24/9.33 ms to render completely (CommonMark/GFM). At 62,000 bytes, parse/decode took 32.22/32.34 ms and complete rendering took 91.74/90.92 ms. These debug-shell samples include the real release-built Rust FFI, are single samples and have no timing gate.
- Workspace formatting and whitespace checks passed; ADR lint passed all 53 records.
- SwiftPM reports no remote dependencies. Retained third-party license text was compared exactly; copied xcframework notices match the canonical file.

Remaining review topics include the proposed native HTML allowlist and documented
stock-comrak source-position limitations. The [final validation record](pr334-final-validation.md)
describes isolated AppKit interaction/accessibility checks and inspected render specimens.
VoiceOver speech and an installed-app walkthrough were not exercised. Dialect settings
and image loading remain outside this implementation. The [PR 334 follow-up record](pr334-review-followup.md)
tracks earlier review fixes and validation.
