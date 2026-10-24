# Isolated sealed-object parser research

Executed on 2026-10-17 UTC (2026-10-16 local). This is test-only research, not a parser selection or an implementation of the preview contract. All task-created files are within this directory. No app build, dependency edits, global configuration edits, or commits were performed.

## Candidates actually built

| Result key | Source | Exact source revision | Runtime version |
| --- | --- | --- | --- |
| `commonmark` | Official `commonmark/cmark`, tag `0.31.2` | `eec0eeba6d31189fd828314576494566d539b1e3` | `0.31.2` |
| `gfm` | Existing pinned `swiftlang/swift-cmark` checkout | `08ddb528923cc1a6527e02b7a1aee9e516ca749a` | `0.29.0.gfm.13` |
| `gfm-official` | Official historical `github/cmark-gfm`, tag `0.29.0.gfm.0` | `b8eb2e00de094999f978e9cb02b1a78d810812d3` | `0.29.0.gfm.0` |

The historical GFM annotated tag object is `de54db6182ecb140f6071a67e97837482d7c6b8d`; the table identifies its commit. The existing checkout is at `shell/.build/index-build/checkouts/swift-cmark`, matching `shell/Package.resolved`; the other local checkout under `package-swift-lsp` had the same revision. The Swift wrapper was not used or relabeled as CommonMark. Its resolved revision is `25cb61d3482054b09ae76ca4f281b1bfe7fe5a43`.

The C harness uses each parser's own XML AST serializer. Both GFM builds enable `table`, `strikethrough`, `autolink`, `tagfilter`, and `tasklist`. Smart punctuation, footnotes, and Apple-specific parse options are not enabled. Test-only HTML uses `CMARK_OPT_UNSAFE` to expose raw HTML; this is not a proposed app setting. `--html-core` is a diagnostic mode with GFM extensions disabled, not a CommonMark 0.31.2 candidate.

Toolchain: Apple clang 21.0.0 (`clang-2100.3.34.2`), CMake 3.31.7, Python 3.13.9, Git 2.51.0; arm64 macOS. Full tool output, source-file SHA-256 manifests, binary SHA-256 values, build commands and failures are in `results/provenance.json` and `results/build-commands.jsonl`. Original upstream `COPYING` files remain in the ignored source checkouts and are included in the manifests. Retained specifications and example-containing adaptations are attributed in [CORPUS-NOTICE.md](CORPUS-NOTICE.md). No new app dependency or shipping notice change was made; this is not a full redistribution/license review.

## Reproduce

Before rerunning: bootstrap downloads pinned sources from GitHub and official
examples from `spec.commonmark.org` and `github.github.com`; it builds local C
executables. Later fixture/unit commands are offline and do not launch a GUI.
No settings or permissions are changed. Obtain operator approval before a new
networked bootstrap.

From the repository root:

```sh
python3 tools/markdown-preview-lab/parser/bootstrap.py
python3 tools/markdown-preview-lab/parser/run.py
python3 -B -m unittest discover -s tools/markdown-preview-lab/parser -p test_lab.py -v
```

The bootstrap requires the existing pinned checkout, `clang`, `cmake`, `git`, Python, and network access to GitHub and the two standards sites. It checks commit revisions and fixed official-corpus SHA-256 values. All downloads, build outputs, and compiler temporary files are directed into this directory; nothing is installed. `build/` and `vendor/` are ignored local artifacts. Subsequent `run.py` and unit-test runs are offline. The regression runner checks binary, harness, and downloaded-corpus hashes before parsing.

## Executed results

- **270/270 AST assertions passed:** 45 hand-authored fixture templates × two token spellings × three real C parsers. Each expected tree is constructed independently of parser output in `fixtures.py`.
- **8/8 lab unit tests passed:** XML projection, narrow HTML-event comparison, displayed tab/space extraction, corpus completeness, fixture IDs, and differing punctuation expectations.
- Direct internal punctuation probes: ASCII `A` is `0` in all three parsers; U+FFFC is `1` in CommonMark 0.31.2 and `0` in both GFM implementations. Python independently identifies U+FFFC as `So`.
- The executable deviation regression passed against `known-mismatches.json`. That records observed deviations; it does **not** turn those deviations into standards conformance.

XML projection removes only `sourcepos` and `xml:space`, supplies an absent resource title as the empty string, and discards empty text children. It retains node nesting, literals, destinations, titles, and child order. Full unprojected XML, canonical expected/actual trees, HTML, and token field locations are saved for every fixture in `results/ast-results.jsonl`. Source positions are recorded but not asserted. Field occurrences are not object identities: an autolink can duplicate a spelling into both label and destination.

### Reproduced findings

Here `{P}` means either the fixed alphanumeric `OTSAttachment0123456789ABCDEF0123456789ABCDEF0Z` or literal U+FFFC. These are observations of the pinned binaries, not project policy.

| ID | Input / state | Observed AST and consequence | Evidence |
| --- | --- | --- | --- |
| P01 | `_note_{P}`, `{P}_note_`, `{P}_note_{P}` | ASCII leaves the underscore syntax as text in every candidate. U+FFFC permits `emph(note)` in CommonMark 0.31.2, but leaves literal underscores in both GFM candidates. | `underscore-after`, `underscore-before`, `underscore-both`; all spelling/candidate combinations |
| P02 | `a*{P}*b` | ASCII creates emphasis in every candidate. U+FFFC is plain text in CommonMark 0.31.2 but creates emphasis in both GFM candidates. Asterisks beside `note` have separate passing controls. | `star-interior`, `star-before`, `star-after`, `star-around` |
| P03 | `www.example.com{P}`, `https://example.com{P}`, and path variants | Both GFM candidates include **either spelling**, including U+FFFC, in the label and destination. CommonMark leaves bare URLs as text. A trailing period is outside the GFM link. | `autolink-www-domain`, `autolink-http-domain`, both `*-path` fixtures, `autolink-trailing-period` |
| P04 | `person@example.com{P}` | GFM absorbs the ASCII suffix into the email link. U+FFFC remains text after the link. A Unicode category change alone is not an opaque-atom mechanism. | `autolink-email` |
| P05 | Pipe-adjacent cells, escaped pipes, and a token in a third cell of a two-column table | Both GFM parsers form table nodes. **The excess third cell and its token are absent from the AST.** CommonMark retains the table-like source as paragraph text. | `table-pipe-before`, `table-pipe-after`, `table-escaped-pipe`, `table-excess-cell` |
| P06 | Link/image brackets, labels, alt text, titles, inline/reference destinations | Tokens can be text children or resource metadata, never sealed-object nodes. Inserting a token between `]` and `(` breaks the inline resource syntax; GFM still autolinks the exposed URL. Alt-text order is represented as text, not native object identity. | `link-*`, `image-*`, `reference-destination`, `angle-autolink` |
| P07 | HTML tag/attribute names, quoted/unquoted attribute values, comments, `src`, `srcset`, CSS `url()`, HTML `alt`, block/script content | A token-only tag name or `data-{P}` attribute name is valid raw HTML with ASCII, ordinary text with U+FFFC. Both spellings in valid attribute values/comments are inside an opaque HTML literal, not child text or separate attribute nodes. | `html-*` fixtures; raw XML and literal fields |

All findings remain research observations. No shipping fix was attempted. Next verification for P01–P07 is an explicit per-dialect atom contract plus composer/native identity and order tests, including discarded syntax and metadata-only occurrences. The fixtures do not establish that either spelling preserves an attachment through composition.

### Independent official examples, not the fork's edited test corpus

| Candidate | Exact HTML | HTML-event equality | Recorded exact mismatch count |
| --- | --- | --- | --- |
| Official CommonMark 0.31.2 | 652/652 | 652/652 | 0 |
| Pinned Swift GFM fork | 651/677 | 653/677 | 26 |
| Official historical GFM | 661/677 | 663/677 | 16 |

Primary oracle downloads:

- `https://spec.commonmark.org/0.31.2/spec.json`: 140487 bytes; SHA-256 `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`.
- `https://github.github.com/gfm/`: 508310 bytes; SHA-256 `b153d814fdfc8624bb6da7449162c1cd707a637f7d1c1b636eb44b9cf63fa220`. Its exact version heading is `Version 0.29-gfm (2019-04-06)`. The extractor reads all 677 numbered example pairs, preserves displayed spaces, decodes entities, and converts displayed tab arrows to tabs. Extraction is saved as `results/gfm-official-examples.json`.

Full expected/actual HTML, Markdown, example numbers, and sections are in the three `*-corpus-results.jsonl` files. `results/summary.json` enumerates every mismatch and the diagnostic comparisons:

- **Serializer only:** GFM examples **279, 280** have equivalent test HTML events after attribute sorting and void-element syntax normalization. No whitespace or nested emphasis is removed by this comparison.
- **Extension-context differences, verified with `--html-core`:** **140, 141, 142, 145, 147** match their published base examples when tag filtering is disabled; **611, 615, 617, 620, 621** match with extended autolinking disabled. The full-extension results remain visible as mismatches; the runner does not silently switch modes for its headline totals.
- **Unresolved published-example differences, official historical GFM:** **324** (numeric reference), **633, 634, 635** (`mailto`/`xmpp` recognition and boundaries).
- **Unresolved published-example differences, pinned fork:** **324** (numeric reference); **398, 426, 434, 435, 436, 473, 474, 475, 477** (nested strong structure); **634, 635** (`xmpp`); **649, 650** (comment grammar).

**Availability limitation:** an official CommonMark 0.31.2 implementation and a historical official GFM candidate were available and executed. Neither tested GFM configuration demonstrates exact published 0.29-gfm behavior across the entire official corpus. The existing Swift fork is therefore a measured GFM candidate, not a substitute asserted to implement the full published dialect. An exact GFM target would require resolving the enumerated differences and the base-example/extension configuration contract. This research does not close R1.

## Scope and remaining limits

This is isolated parser evidence for the sealed-object portion of R1, not the whole R1 matrix. Single/double/triple-tilde controls, Apple inline-attribute options, custom table spans, and `textarea` boundaries are not separately exercised as placeholder fixtures. Official corpora run independently but do not replace those custom-feature investigations. No Swift wrapper, AppKit composer, `safeURL`, native HTML mapping, object identity, image consent/load behavior, transport instrumentation, accessibility, deployment-target compatibility, or performance test ran. Parser output is not evidence of app URL refusal or resource-request isolation. Native restrictions were not mixed into parser results.

The repository started at `54d38a549b597f9fd5a664e48db05a293bccbb5d`; during execution another activity advanced HEAD to `103eef0270843173c3acbf9f3013bd421f602dd6` with a design-document commit. Other labs also appeared outside this task's write scope. They were not edited by this task. `results/scope-audit.json` records the tracked worktree state and concurrent changes; do not interpret the changed design document as a parser-lab edit. No initial/final global-clean-tree assertion is made.

Early build attempts exposed the two upstreams' differently named punctuation functions and a missing private-header declaration; both were corrected in the lab harness. Initial fixture expectations overlooked GFM's autolinking of a URL exposed by broken bracket syntax, and the first corpus-count guard assumed 652 instead of GFM's 677 examples. These corrections are recorded in `results/exploratory-expectation-corrections.json` and the build log, not hidden by the final pass. Upstream compile warnings remain recorded, including pointer-to-int casts in historical GFM tasklist code; no vendor source was patched.

## Files and evidence

- `.gitignore`: excludes only lab builds, downloaded source checkouts, and bytecode.
- `bootstrap.py`, `harness.c`: revision/checksum verification and standalone C builds/probes.
- `fixtures.py`: 45 explicit structural templates, expanded across both spellings/dialects.
- `run.py`, `test_lab.py`, `known-mismatches.json`: offline AST/corpus regressions and lab self-tests.
- `results/provenance.json`, `build-commands.jsonl`, `test-commands.jsonl`, `unit-tests.json`, `scope-audit.json`: tool/revision/hash/command/scope evidence.
- `results/ast-results.jsonl`, `summary.json`, `*-corpus-results.jsonl`: complete machine observations and enumerated deviations.
- `results/commonmark-0.31.2-spec.json`, `gfm-0.29-spec.html`, `gfm-official-examples.json`: independently downloaded and extracted oracles.
- `results/exploratory-expectation-corrections.json`: pre-correction expectation failures.
- `README.md`: this report. All paths in this list are relative to the parser lab.
