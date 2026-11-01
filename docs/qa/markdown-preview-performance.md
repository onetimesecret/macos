# Large Markdown preview follow-up

This is an implementation and measurement record after #336. Timings are local
samples, not latency requirements or evidence of a frame-time bound.

## Measured stages

The opt-in Swift integration profile uses repeated headings, emphasis, links,
and paragraphs, with four 62,000-byte pages in its mounted-preview batch.
The Rust release profile also includes sealed objects and numeric entities.
These are synthetic fixtures rather than a representative user-document corpus.

| Sample | Before | Deferred path |
| --- | ---: | ---: |
| Four-page synchronous reseed call | 459 ms | 0.41 ms |
| Completion after the reseed call returns | Not separate | 370 ms |
| Unchanged four-page reseed | 0.010 ms | 0.009 ms |

On the Swift debug shell with the test-util Rust core, a 62 KB page takes about
3.7–4.2 ms through the Rust FFI and 27.8 ms in Swift response decoding and
validation. The synchronous render helper takes another 75–78 ms including
its own parse/decode. These independently sampled calls should not be treated
as an exact subtraction-based composition measurement.

The Rust release profile reports roughly 2.2–2.5 ms parse/walk, 0.35–0.41 ms
JSON sizing, and 0.65–0.75 ms JSON writing for its 77 KB/1,000-object fixture.
It reports source normalization and the table pre-scan separately.

## Implementation

- Sources below 16,384 UTF-16 units retain synchronous rendering.
- Larger mounted previews use a serial parser actor for Rust parsing and
  Swift JSON decoding. A changed source/dialect request cancels its predecessor;
  equivalent pending work is reused. Cancellation
  is checked before and after parsing; an already executing Rust call is
  allowed to finish before its result is discarded.
- Native attributed-text composition stays on the main actor and yields
  after every 16 top-level blocks. The finished result is installed together.
- The view shows a loading label while work is pending. Selection and the
  preview copy/service/read routes do not offer that label as page content.
- A result must match the current pending generation. Exact UTF-16 text,
  complete chip metadata and attributes determine equivalent source. Completion
  asks the roll to rebase its reading position and remeasure the preview.
- The JSON ownership/free path and parser limits are unchanged. No document
  cache is introduced by this change.

AppKit storage installation and layout still run on the main actor. One very
large paragraph, nested block, or native table can still take a substantial
single turn: yielding between top-level blocks is not a hard time budget.
The static render helper remains synchronous for explicit callers and tests.

## Reproduction and validation

```sh
PREVIEW_PROFILE=1 scripts/test-shell.sh --filter MarkdownIntegrationPerformanceTests
cargo test -p companion-markdown --release preview_pipeline_profile -- --ignored --nocapture
```

`MarkdownDeferredRenderingTests` covers interim reader/copy refusal, replacement
and dialect changes during pending work, preservation of the last completed
text for reading-position rebasing, and cancellation of queued parsing.
The view uses weak capture until rendering finishes. An immediate-deallocation
assertion was not used: a plain AppKit text view also survives briefly while
AppKit performs deferred cleanup, independently of this rendering task.

The focused Markdown/image run passed 250 tests with four opt-in tests skipped.
The three controlled-network tests passed in a separate explicit run.
Full-suite results and human VoiceOver observations are recorded separately.

## Expanded measurements

The code sampled below is committed in `2869caca9f75d86be9165a38f8d3031623561b8b`.
A serial debug run, without a concurrent compiler job, measured:

| Sample | Time |
| --- | ---: |
| 62 KB Rust bridge, CommonMark / GFM | 3.67 / 3.77 ms |
| Swift response decode, CommonMark / GFM | 27.02 / 27.30 ms |
| Synchronous complete render helper, CommonMark / GFM | 73.27 / 74.91 ms |
| Four 62 KB pages, synchronous reseed | 2.82 ms |
| Deferred completion after reseed | 400.31 ms |
| Unchanged four-page reseed | 0.013 ms |
| 1,024-cell native table composition | 41.08 ms |
| Same table layout at 640 points | 33.77 ms |

An earlier expanded run overlapped a sanitizer build and measured 5.79 ms
reseed / 671.99 ms completion. The original samples above and both later runs
show host/workload variation; none establishes a latency bound. Table layout
and one large block remain synchronous work.

A separate test-owned window with eight mounted previews and 32 image controls
ran 120 alternating 320/1,200-point resizes. Synchronous resize p50/p95 was
9.36/13.97 ms. The overridden native key-loop method observed 1,738 calls,
361.26 ms total, about 3.01 ms per resize, including AppKit's own calls.
Another 120 final-layout calls added one recalculation. This is programmatic
resize coverage, not a physical live-drag measurement. Window-wide coalescing
remains a performance follow-up; immediate restored-control traversal is still
covered by the current tests.

Nine deferred-render tests pass, including equal-source task reuse, a literal
Unicode edit, cancellation cleanup and awaiting the actual superseded task.
The final Swift ThreadSanitizer run passed 30 tests, including 400 concurrent
FFI parses. The Rust static library was not sanitizer-instrumented. The tests
use a lock for concurrent result collection while parsing outside that lock.

The final application commit `61ccb43a` extends equivalent-source reuse to
completed pages without images. A full typeface snapshot invalidates reuse
when prose/code family or size changes, even with the same source wrapper.
The full Swift suite, 30-case sanitizer subset and 866-check UI matrix pass.
The stage timings above are prior samples, not a new profile of that commit.

Reported synchronous reseed times cover the complete four-preview batch. The
shared actor queues parse/JSON work across mounted pages, so completion includes
the work queued ahead of each page. A time check between blocks could shorten
large batches, but would still leave the cost of one block unbounded.

## Literal source comparison

The final comparison uses `NSString.isEqual(to:)`. Apple's
[method documentation](https://developer.apple.com/documentation/foundation/nsstring/isequal%28to%3A%29)
states: “UTF-16 code units are individually compared.” The equal-length
Angstrom edit regression remains active, so canonical-equivalent strings still
replace the pending source when their literal units differ.

A synthetic string-only benchmark ran 100 equal comparisons per sample:

| Units / content | Optimized walk | Optimized NSString | Debug walk | Debug NSString |
| --- | ---: | ---: | ---: | ---: |
| 62,000 / ASCII | 0.315 ms | 0.0020 ms | 1.05 ms | 0.0017 ms |
| 1,000,000 / ASCII | 3.94 ms | 0.026 ms | 16.03 ms | 0.026 ms |
| 62,000 / Unicode | 0.365 ms | 0.0031 ms | 1.18 ms | 0.0033 ms |

These are mean per-call samples with repeated inputs. Attribute comparison,
composition and layout are absent; this is not a complete reseed measurement.
The final application files are committed by `afbee4ac`. Full Swift, the 30-case
sanitizer subset and the 866-check UI matrix pass on those source bytes.
