# Supplemental R1 contract fixtures — offline

This is a separate C-only experiment. It does not select a dialect, change the preview contract, or close R1. Existing lab files, evidence, source checkouts, and builds are read-only inputs. No network, bootstrap, package resolution, app build/launch, GUI, accessibility, permission, or settings operation was used. No commit was made by this task.

## Offline reproduction

From the repository root, using the already available checkouts and generated headers:

```sh
python3 -B tools/markdown-preview-lab/parser/contract/build.py
python3 -B tools/markdown-preview-lab/parser/contract/test_review.py
python3 -B tools/markdown-preview-lab/parser/contract/run.py
```

Only `contract/` is written. Reviewed builds use ignored `contract/build/review/`; new evidence uses `contract/results/review/`. Existing top-level `results/` files and original binaries under `build/` are preserved, including `initial-expectation-corrections.json`. `build.py` directly compiles C sources, excluding upstream CLI `main.c`; it does not invoke any previous lab script or reuse precompiled parser libraries. `run.py` also executes the three existing parent-lab parser binaries as read-only comparison controls.

## Pinned source and runtime identity

| Candidate | Source revision | Header and runtime version | Reviewed binary SHA-256 |
| --- | --- | --- | --- |
| Official CommonMark | `eec0eeba6d31189fd828314576494566d539b1e3` | `0.31.2` | `48f4a1d663face16ffccd5e902a57963d4aa238567ee6f1401127ed320f85de4` |
| Pinned Swift fork | `08ddb528923cc1a6527e02b7a1aee9e516ca749a` | `0.29.0.gfm.13` | `1e70e3a7d30e29ea133a51952249cb9ec68661f61722da9e8bb518ae7d1b9948` |
| Official historical GFM | `b8eb2e00de094999f978e9cb02b1a78d810812d3` | `0.29.0.gfm.0` | `4ee962f1aa91225b23d17762b2005539207d7772e2cd03f60357b360796c1136` |

The Swift wrapper remains `25cb61d3482054b09ae76ca4f281b1bfe7fe5a43`. `results/review/provenance.json` records source-file and compiler-derived input hashes, per-translation-unit dependency files and arguments, original binary hashes, runtime/header version probes, Mach-O load commands, wrapper excerpts, toolchain, and platform. Before edits, all **441 saved source hashes matched** (119 CommonMark, 167 fork, 155 historical GFM); that observation is retained in `results/review/before-changes.json`. Complete manifests are validated before any parser subprocess and again after the fixture run. Every saved source hash still matches. These are source-based and executable observations, not normative project policy.

All 19/34/34 parser C files, respectively, were compiled with `-O2 -mmacosx-version-min=13.0`. The three arm64 binaries report `minos 13.0`, SDK `27.0`. Execution used the current macOS 27.2 host and Apple clang 21.0.0, not macOS 13. A deployment-target build is **not** a macOS 13 runtime test; Intel, universal binaries, Swift conversion, and app linking were not tested.

## Actual wrapper configuration versus individual toggles

Inspected code, not a library label, defines these modes:

- `shell/Sources/CompanionKit/MarkdownPreviewView.swift:326` calls `Document(parsing: markdown, options: [.disableSmartOpts])`.
- At pinned `swift-markdown/Sources/Markdown/Parser/CommonMarkConverter.swift:614–626`, the exact initialization is `var cmarkOptions = CMARK_OPT_TABLE_SPANS`. The subsequent code conditionally adds `CMARK_OPT_SMART` and `CMARK_OPT_SOURCEPOS`, and attaches exactly `table`, `strikethrough`, `tasklist`.
- `ParseOptions.swift:19–32` exposes the Swift switches. Double-tilde-only and disabling table spans are C experiment toggles, not existing Swift `ParseOptions` switches.

| Mode | Candidate | Exact C parse mask | Extensions / interpretation |
| --- | --- | ---: | --- |
| `cm-core` | Official CommonMark | 0 | None; actual 0.31.2 candidate |
| `cm-smart` | Official CommonMark | 1024 | None; selected SMART toggle |
| `legacy-core` | Historical GFM | 0 | None; historical core, not CommonMark 0.31.2 |
| `legacy-gfm` | Historical GFM | 0 | Five GFM extensions |
| `legacy-double` | Historical GFM | 16384 | Five extensions + DOUBLE_TILDE |
| `swift-core` | Swift fork | 0 | None; fork core, not CommonMark 0.31.2 |
| `swift-gfm` | Swift fork | 0 | Five GFM extensions; previous lab configuration |
| `swift-double` | Swift fork | 16384 | Five extensions + DOUBLE_TILDE |
| `swift-preview` | Swift fork | 1048578 | Complete current preview C invocation: SPANS + SOURCEPOS; three wrapper extensions |
| `swift-preview-spans-off` | Swift fork | 2 | Only SPANS removed from preview |
| `swift-default` | Swift fork | 1049602 | Complete C invocation for Swift options `[]`: SPANS + SOURCEPOS + SMART; three extensions |
| `swift-gfm-spans` | Swift fork | 1048576 | Only SPANS added to five-extension mode; not the wrapper configuration |
| `swift-preview-double` | Swift fork | 1064962 | Only DOUBLE_TILDE added to preview |
| `swift-preview-no-sourcepos` | Swift fork | 1048576 | Only SOURCEPOS removed from preview |

Five GFM extensions means `table`, `strikethrough`, `autolink`, `tagfilter`, `tasklist`. Three wrapper extensions means `table`, `strikethrough`, `tasklist`: **no autolink or tagfilter**. This distinction is asserted using a bare URL and textarea output, not just metadata.

HTML serialization is separately fixed at `CMARK_OPT_UNSAFE` (131072) to expose grammar output without source-position HTML attributes; XML serialization uses `CMARK_OPT_SOURCEPOS` (2). These are diagnostic C serializers, not the app renderer or proposed app settings. Removing SOURCEPOS leaves the projected AST and this fixed-mode HTML unchanged; source-range correctness and Swift behavior are not inferred from that comparison.

## Executed results and new observations

- **560/560 fixture rows passed:** 40 explicit structural templates × 14 modes; **560 AST + 560 HTML + 560 XML projection checks**. Expected ASTs are authored independently of actual parser output. Expected HTML is generated from those expected ASTs: these are **not independent AST and HTML oracles**. The saved official HTML examples provide separate selected comparisons.
- **14/14** mode metadata checks; **120/120** preview-toggle pair checks.
- **240/240** exact comparisons with existing binaries: 40 inputs × HTML/XML × three original baseline configurations. No baseline output difference was introduced by the separate harness build.
- **45/70** selected official HTML comparisons are equal; all **70/70** expected-outcome regressions pass. The 25 differences are deliberate cross-mode/cross-dialect comparisons, not 25 new failures added to the earlier full-corpus totals.

| Finding | Reproduced behavior | Fixture evidence |
| --- | --- | --- |
| C01 — Tilde grammar | With strikethrough attached, both GFM implementations and the actual wrapper configuration accept single and double tildes; triple inline runs stay literal. DOUBLE_TILDE rejects single runs. Triple-tilde fences remain code blocks. ASCII/U+FFFC contents have separate cases. | `tilde-*`, `official-gfm-491/492/493` |
| C02 — Apple attributes are core syntax | `^[note](key)` is an `attribute` node with payload `key` in every pinned-fork mode, including zero extensions. The other candidates produce a literal caret plus an ordinary link. Spaced payloads, rich labels, empty/missing payloads, escaping, and tokens in labels/payloads are checked separately. The fork C HTML renderer omits attribute payloads; XML also omits them. | `attribute-*`; API `cmark_node_get_attributes`; fork `src/inlines.c:1662–1669`, `src/html.c:424–435`, `src/xml.c:138–140` |
| C03 — Spans depend on the complete configuration | Current preview turns `||` into colspan/filler cells and a caret-only cell into rowspan/filler cells. Spans-off retains independent empty cells and literal carets. Tests check colspan 2/3, header spans, numeric rowspan, combined spans, whitespace/caret controls, and tokens inside spanning cells. | `table-*`; wrapper converter `:588–597`; fork `extensions/table.c:324–355,580–603` |
| C04 — Raw span XML is incomplete and malformed | **30 rows** produce invalid XML: six body-span fixtures × five spans-on modes. The serializer emits valueless `colspan`, `rowspan`, or filler attributes, and omits numeric sizes. Header spans can produce valid XML while omitting span metadata. API JSON is compared with the expected AST, and exact HTML with HTML generated from that AST. Repaired diagnostic XML must also match the expected projection. This is an XML-serializer limitation, not an inferred parser grammar failure. | `results/review/fixtures.jsonl`; fork `extensions/table.c:825–853`; API `cmark_gfm_extensions_get_table_cell_colspan/rowspan` |
| C05 — Textarea boundary differs from tag filtering | Official CommonMark and the pinned fork core treat textarea as type-1 HTML through its closing tag, including blank lines, and allow it to interrupt a paragraph. Historical GFM does not: blank-line/paragraph boundaries differ. Attaching tagfilter changes emitted tags separately from the AST boundary. Uppercase tags and closing-tag/following-text boundaries are covered. | `textarea-*`, `official-cm-171`; each candidate's `src/scanners.re` |
| C06 — Official punctuation control | CommonMark example 354 keeps `*$*alpha.`, `*£*bravo.`, `*€*charlie.` literal. Both GFM source versions instead emphasize the Unicode currency symbols, but not the ASCII dollar. This separates the base punctuation rules from extension attachment. | `official-cm-354` in all 14 modes |
| C07 — SMART cannot stand in for wrapper options | The selected CommonMark SMART mode changes `---` to an em dash in table-like paragraph text. In the full wrapper-default mode, the table extension consumes the divider syntax instead. The ordinary quote/dash/ellipsis control distinguishes wrapper default from actual preview. | `smart-option-control`, table cases, mode-pair results |

The five official controls are read only from existing saved CommonMark examples **171, 354** and GFM examples **491, 492, 493**. Exact new comparison differences are:

- **12 × CommonMark 354:** every historical/fork mode differs on Unicode currency punctuation; both official CommonMark modes match.
- **6 × CommonMark 171:** three historical modes differ in textarea grammar; three pinned five-extension modes differ through tagfilter serialization. Pinned core and the actual preview do not have that tagfilter difference.
- **7 × GFM 491:** four core/no-strikethrough modes and three selected double-only modes differ on the published single-tilde example.
- **0 × GFM 492/493:** every mode matches these paragraph-boundary/triple-inline controls.

Per-mode mismatch IDs and full expected/actual strings from the reviewed run are in `results/review/summary.json` and `results/review/official-comparisons.jsonl`. The earlier full official-corpus totals were not rerun or rewritten. No new exact-dialect conformance conclusion follows from this selected matrix.

## Evidence format, scope, and limits

`fixtures.py` constructs expected structures from specified syntax and inspected source behavior, not parser-trained snapshots. The runner removes empty text nodes and merges adjacent text nodes; other node nesting and API properties remain explicit. `expected_xml` is a well-formed serialization of the expected API tree, **not** a byte oracle for the lossy upstream serializer. Raw upstream XML remains unmodified in `actual_xml`. The 30 expected-invalid cases no longer pass merely because parsing raises an error. The checker removes only known valueless span attributes on `table_cell` start tags, in the five combinations emitted by the pinned serializer, from a **diagnostic copy**. Unknown valueless attributes, duplicate attributes, and unexpected combinations are rejected. The diagnostic copy must parse and its complete projection must equal the expected tree. `diagnostic_xml`, `xml_span_repairs`, projection fields, and original errors retain this evidence. Attribute payloads and numeric spans are tested through APIs rather than reconstructed from missing XML fields.

An initial expectation missed SMART conversion of table-divider text in the extension-free CommonMark SMART mode; its ten failed rows remain in `initial-expectation-corrections.json`. The corrected expectation follows the SMART grammar and an existing explicit control. No parser source was changed to obtain a pass.

The original supplement's pre-build audit recorded 737 hashes, including the old lab's evidence/build inputs and selected external sentinels. Another activity edited and committed the design document during that earlier task; its historical evidence remains intact. The review fix separately checks current source manifests and records preservation of prior evidence in `results/review/scope-audit.json`. It changes only files within `contract/` and makes no commits.

Remaining limits: no complete Swift `Document` execution/conversion test, app/native rendering test, object-identity or alt-text replacement test, transport instrumentation, sanitizers/fuzzing, performance measurement, macOS 13 runtime, or Intel run. Attribute reference forms and exhaustive malformed/nested span behavior remain outside these 40 templates. C HTML diagnostics do not establish native rendering or resource-request behavior.

## Review fixes and regression evidence

- **P2/source preflight:** the runtime gate validates every entry in every complete `source_files_sha256` manifest, including the external Swift checkout. Compiler inputs are derived from `clang -MMD -MF` for **90 translation units** (20/35/35 including the harness), not include-directory globs. The resulting 38/69/69 input entries include all eight reported omissions. Dependency-file hashes, dependency lists, and the union of compiler inputs are revalidated before execution. The emitted SDK settings dependency is hashed by absolute path; `-MMD` does not inventory the full SDK/system-header tree.
- **P2/XML:** all **560/560 projections pass**, including **30/30** repaired diagnostic copies. A parse error alone is insufficient. Empty/truncated/unrelated malformed XML, foreign-tag markers, unknown/duplicate markers, unexpected combinations, missing structure, and wrong text are rejected.
- **P3/oracle wording:** expected HTML is explicitly documented as generated from the expected AST, independent of actual parser output but not an independent structural oracle.
- **34/34 isolated regression tests pass.** Eight separate synthetic mutations cover `src/entities.inc`, `src/case_fold_switch.inc`, and `extensions/{autolink,ext_scanners,strikethrough,table,tagfilter,tasklist}.h`. Each is rejected by runner preflight with **zero parser-execution and subprocess calls**. A non-compiled manifest entry (`COPYING`) and a missing source have additional rejection tests. No real checkout is mutated. The suite also checks dependency escaping, actual dependency coverage, all five known marker combinations, ten XML rejection cases, quoted/literal marker preservation, and all 560 saved XML projections.

The regression report is `results/review/regression-tests.json`; build/command logs, reviewed provenance, raw/diagnostic XML, exact HTML, and counts are in the same new directory. `scope-audit.json` verifies preservation of prior evidence and the expectations-corrections file. No new official-example mismatch was introduced: the selected comparisons remain **45/70 equal**, with **25 expected differences**.

### Files changed by this review fix

- Modified: `build.py`, `run.py`, `README.md`.
- Added: `test_review.py` and evidence under `results/review/` (`before-changes.json`, `build-commands.jsonl`, `commands.jsonl`, `provenance.json`, `start-state.json`, `regression-tests.json`, `fixtures.jsonl`, `mode-metadata.json`, `mode-pairs.jsonl`, `previous-binary-comparisons.jsonl`, `official-comparisons.jsonl`, `summary.json`, `scope-audit.json`).
- Unchanged: `harness.c`, `profiles.py`, `fixtures.py`, `.gitignore`, all previous results, original binaries, parser sources, and parent-lab evidence.

All paths above are relative to `tools/markdown-preview-lab/parser/contract/`. Ignored executables and compiler scratch files are under `build/`.

Official example inputs and example-containing adaptations in this supplement are covered by the attribution and CC-BY-SA 4.0 terms in [`../CORPUS-NOTICE.md`](../CORPUS-NOTICE.md). That existing notice and all original evidence remain unchanged. Original parser `COPYING` files are read-only source inputs; this supplement is not a completed redistribution review.
