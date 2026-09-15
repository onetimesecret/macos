# Implementation plan: source-language detection

Status: **proposed** · 2026-09-12  
Specification: [feature behavior](README.md) · Decision: [ADR-0029](../../../adr/0029-betlang-source-language-detection-behind-the-existing-c-abi.md)

This is an ordered delivery plan, not a record of completed work. No issues or
milestones have been created. Paths below are relative to the repository root.
Source observations include the working tree as inspected on this date; they
are not evidence of accepted policy.

## Immediate execution step

Measurement and production-path implementation can begin before the adapter or
any user-visible surface is approved for release. ADR-0029 says: “Keep ranked
scores internal for evaluation. Choose minimum evidence, top-score, and
top-two-margin thresholds from the local corpus before freezing the adapter.”
This ordering makes threshold selection a release gate, not a prerequisite for
building the path needed to measure integration cost and behavior.

The non-shipping `tools/language-eval` harness calls the recorded registry
artifact directly, retains ranked results, and keeps thresholds configurable.
Its synthetic tuning and hold-out data must not include clipboard history,
private documents, or real secrets. In parallel, implement the core adapter,
C/Swift bridge, bounded worker, and an explicitly enabled development-only
ordinary-paste shadow path. The shadow path must leave the existing paste
unchanged and must not expose automatic edits or a user-visible setting.
Provisional thresholds and successful integration tests are evidence to review;
they are not approval to ship the dependency, detector, or automatic behavior.

## Integration map

| Area | Existing source and hook | Planned work |
|---|---|---|
| Non-shipping evaluation | `tools/language-eval` | Run the exact registry artifact over synthetic/public tuning and hold-out data; retain rankings and report quality and local costs. |
| Rust inference | `crates/core/Cargo.toml`, `crates/core/src/lib.rs` | Add exact dependency and a new `language_detection` module; safe label API and evaluated abstention policy. |
| C ABI | `crates/ffi/src/lib.rs`, `crates/ffi/include/companion_ffi.h` | Add stateless pointer/length export, error containment, ownership docs, and boundary tests. |
| Framework | `scripts/build-core.sh`, `bindings/include/companion_ffi.h` | Regenerate copied header/framework through the existing build route. |
| Swift bridge | `shell/Sources/CompanionKit/CompanionClient.swift` | Add owned-string wrapper; keep inference independent of store mutation. |
| Ordinary paste | `shell/Sources/CompanionKit/InkEditorView.swift`, `paste(_:)` | Intercept eligible plain-text pastes; bypass, async target checks, one replacement. |
| Edit and undo | Same file: `editOps`, `emit`, `nextEditIsAutomation`; `PageModel.applyOps` | Use core undo-step routing, not an AppKit undo group; editor currently sets `allowsUndo = false`. |
| Fence parsing | `InkEditorView.swift`, `InkStyle.FenceScanner`, `Coordinator.restyle()` | Retain raw info-string presence separately from resolved highlighter; index body ranges and suggestions. |
| Coloring | `shell/Sources/CompanionKit/CodeInk.swift`, `canonicalLanguage(ofInfoString:)`, `Tokenizer` | Explicit detector-label mapping; whole-file source path; plain fallback. |
| Font | `InkEditorView.swift`, `InkStyle.Typeface`, `styleParagraph` | Code font independent of custom prose family; range-aware layout measurements. |
| Settings | `shell/Sources/CompanionKit/PageModel.swift`, `SettingsSections.swift`, `FormFactor.settingsDefaults` | Default-off preference, common settings UI, no retrospective edits. |
| Open/reload | `PageModel.openFile(at:)`, `shell/Sources/CompanionKit/FileCoordinator.swift` | Render-mode suggestion lifecycle and revision tracking. |
| Drop/header | `shell/Sources/CompanionKit/FileSurface.swift`, `FileDropDecision.opens`, `FileHeaderState.format` | Align drop acceptance with content validation; expose actual selected mode. |
| File content validation | `crates/core/src/files.rs`, `FileStore::open`, `read_once`; `crates/ffi/src/files.rs` | Extension-independent text eligibility, bounded reads, no Betlang admission decision. |

Current `CodeInk` canonical names: `swift`, `rust`, `python`, `ruby`,
`javascript`, `typescript`, `go`, `shell`, `sql`, `json`, `yaml`, `toml`.
For all other Betlang slugs, keep the original label and use uncolored code
presentation unless a separately tested renderer mapping is introduced. Include
an exhaustive 48-label mapping test so new upstream labels cannot silently
select the wrong scanner.

## Phase 0 — executable evaluation and dependency qualification

This phase has two distinct outcomes: evidence collection may proceed now;
shipping remains gated on review of the resulting quality, resource, license,
retention, and supported-target evidence.

Deliverables:

- [x] ADR-0029 is accepted, including its narrow partial replacement of
  ADR-0024. Confirm the initial default off, session-only rendering choices, and
  v1 encoding scope before implementation.
- [x] Retrieve the published `0.1.1` crate and record the registry checksum
  `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`, package
  VCS revision `13b5cbf7b934fdbd4be0bb7437faeb03124700de`, and matching 47,840-byte
  model SHA-256 `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`.
  ADR-0029's erratum records the package/source discrepancy and makes the
  published registry artifact the review target.
- [ ] Inspect the packaged inference window, initialization, and transitive
  dependencies on each supported target.
- [x] Define and verify where `THIRD_PARTY_NOTICES.md` enters both the app and
  framework packaging. The release scripts compare both packaged copies byte for
  byte with the canonical notice.
- [ ] Complete the license audit and resolve the model-weight licensing ambiguity
  recorded by ADR-0029. Notice inclusion does not resolve that release blocker.
  Check `deny.toml`; do not broaden license allowances to silence a failed check
  without review.
- [ ] Review source-derived scratch retention, panic handling, and concurrency.
  Do not promise erasure merely because inference is local. Decide whether
  upstream changes or a reviewed patch are needed before processing user text.
- [x] Build a non-shipping evaluation harness against exact `betlang = "=0.1.1"`
  with configurable evidence, top-score, and top-two-margin thresholds. Keep all
  ranked scores in generated measurement output. Do not route it through the
  production core, C ABI, Swift shell, clipboard, or document model.
- [ ] Complete the synthetic/public, redistributable evaluation corpus. A tracked
  synthetic starter corpus and deterministic 1,200-case paste-negative family
  now exercise the harness; extend it to every label, very short snippets,
  multilingual prose, lists, Markdown, chat messages, URLs, credentials-shaped
  synthetic strings, logs, stack traces, JSON/YAML/TOML, mixed prose/code,
  unsupported languages, malformed text, and binary samples. Never use real
  clipboard history or secrets.
- [x] Run tuning and hold-out sets and publish the generated report. The
  [2026-09-14 evaluation](evaluation-2026-09-14.md) kept exact examples disjoint,
  preserved the selected candidate, and failed the proposed automatic-paste gate.
  The corpus still does not complete the planned every-label and ambiguity matrix,
  including `c/cpp`; that remaining corpus work is not erased by this execution.
- [ ] Select and document top-score, top-two-margin, minimum evidence, and paste
  eligibility thresholds. A tuning-selected candidate is documented, but its
  untouched holdout failed and production values remain provisional. Zed PR #61412 supplies an external starting baseline:
  20 input bytes, a 0.20 minimum score, and a 0.20 candidate-group gap; it does
  not validate Companion's automatic-paste use case. Proposed automatic-paste gate: at least 99% precision
  on eligible held-out paste cases and no automatic conversions on a dedicated
  suite of at least 1,000 prose/list/URL negative cases. Publish counts and
  uncertainty; zero observed errors is not proof of a zero production error rate.
  Do not meet precision by abstaining on everything: report useful-code coverage
  and obtain review of that trade-off.
- [ ] Measure cold/warm inference and end-to-end Swift request cost on supported
  hardware, including release `opt-level = "s"`. Proposed responsiveness target:
  warm p95 request overhead below 10 ms and cold completion below 100 ms on the
  named baseline machine. Agree on a memory/binary budget from measured results.

Exit: the experiment has been run, the exact artifact is qualified, thresholds
and measured trade-offs are recorded, license/retention questions are resolved,
and the production adapter and initial surfaces are selected. Starting the
experiment does not require this exit to be satisfied. If paste quality fails,
reduce scope to explicit suggestions; do not label Betlang a reliable
code-versus-prose detector.

## Phase 1 — core, C ABI, and Swift service

- [ ] Implement safe core API and conservative abstention policy. Reuse the
  packaged model lifecycle, with no network or file-path responsibility.
- [ ] Add C export and header ownership contract from the ADR. Unit-test empty
  input, null/length combinations, oversized lengths rejected before reads,
  UTF-8 eligibility, embedded NUL, canonical labels, and failure-to-NULL behavior.
  Do not test invalid pointers by dereferencing them.
- [ ] Add Swift wrapper using pointer/length for the lifetime of the synchronous
  call and `companion_string_free` after copying a successful label.
- [ ] Add a bounded serial worker initially; no unbounded tasks per fence or
  inference while holding the editor/store lock. Carry an immutable request ID,
  document ID, revision, target range, trigger, and selection snapshot.
- [ ] Keep only current requests/results. Invalidate on document edit, projection
  replacement, close, undo, or relevant mode change. Drop stale completions and
  release snapshots promptly. Do not persist cache keys, source, or scores.
- [ ] Regenerate framework/header and verify Swift linkage. Test concurrent calls
  at the Rust layer and cancellation/stale-result behavior at the Swift layer.

Exit: headless core tests and C/Swift bridge tests pass with a verified artifact.
No user-visible text changes yet.

## Phase 2 — manual selection and bare-fence suggestions

- [ ] Distinguish empty info strings from explicit unsupported labels. Gather
  fence bodies before scheduling inference; never infer inside `restyle()`.
- [ ] Implement context-menu and keyboard-accessible Detect action with explicit
  targeting, suggestion dismissal, and manual language selection.
- [ ] Add accepted session-only fence highlighting and explicit insert-label/wrap
  commands. Validate range/revision at acceptance and emit ordinary edit ops only
  for commands that actually modify markup.
- [ ] Reuse CodeInk; implement fixed-width code font and test proportional prose
  layouts. Keep unknown labels legible without pretending token colors exist.
- [ ] Leave quiet renderings and chip/sealed-content paths untouched.

Exit: suggestions and accepted display-only styling do not change stored text;
explicit commands are independently undoable. Tests distinguish unchanged text
from intentionally inserted labels/fences.

## Phase 3 — opt-in automatic paste fencing

- [ ] Add General setting, initialized off for missing defaults, and one-paste
  bypass. Mount through the shared settings view used by the shell surfaces.
- [ ] Build a pure paste-replacement planner: input payload, destination context,
  accepted label, safe delimiter, structural newlines, final caret range. Keep
  language inference outside this planner.
- [ ] Wire one pre-insertion request into ordinary `paste(_:)`. Define and test
  pending-request cancellation on typing, selection changes, tab changes, close,
  read-only transitions, and IME composition. Ensure fallback does not duplicate
  paste or insert into a different document after a switch.
- [ ] Use the existing core new-undo-step mechanism for the complete replacement.
  Do not emit a plain insertion followed by a second fence insertion.
- [ ] Apply only to Markdown-capable targets and documented whole-line contexts.
  Pasting in Source mode remains ordinary source text; pasting inside a fence
  never creates a nested fence.

Exit: quality and latency gates pass; undo/redo restores exact payload and
replacement selection; no automatic document edits occur with the setting off.
If pending-paste semantics cannot be made predictable, hold this phase rather
than silently transforming content after insertion.

## Phase 4 — extension-independent text opening and rendering modes

- [ ] Specify core UTF-8/binary admission tests independently of Betlang. Make
  file reading bounded before allocating the whole file; handle file growth and
  existing read-witness checks without weakening them.
- [ ] Route panel, drops, and reopen through shared validation. Accept unknown
  suffixes/extensionless regular text files, reject directories and binary input
  with an actionable reason, and retain the 4 MiB limit. Report unsupported
  encodings accurately instead of calling them binary.
- [ ] Add per-file Plain Text / Markdown / Source mode state, suggestion UI,
  filename hints, explicit-choice precedence, and session dismissal.
- [ ] Implement a whole-document tokenizer path. Do not wrap file content in
  Markdown fences or apply Markdown list automation to source/plain mode.
- [ ] Cover external reload, restored draft, Save As, close/reopen, and stale
  inference. Keep file save and existing undo/draft behavior independent of
  rendering metadata.

Exit: opening depends on supported text content, not source-language recognition;
changing rendering mode alone creates no edit ops, dirty state, or disk write.
All save/encoding regressions are tested against the existing file pipeline.

## Phase 5 — distribution and regression verification

- [ ] Verify notices in final app and separately distributed framework artifacts.
  Add a CI check of the exact dependency/model hash; fail closed on drift.
- [ ] Re-run held-out evaluation and cold/warm performance with the shipped
  release profile. Record hardware, package revision, corpus version, and sizes.
- [ ] Exercise keyboard access, VoiceOver, IME, custom fonts, read-only resting
  view, file drops, selection replacement, and undo on an actual AppKit surface.
- [ ] Update user documentation with defaults, bypass, supported encodings,
  language/highlighter distinction, and known ambiguous cases. Do not advertise
  upstream benchmark accuracy as a product guarantee.

Exit: acceptance checklist passes and no unresolved artifact, licensing, policy,
or user-text-handling gate remains. Each UI phase can release independently.

## Regression matrix

| Area | Required cases |
|---|---|
| Abstention | Empty/whitespace, fewer than eight non-whitespace bytes, low score/margin, unsupported source, prose/lists, non-finite scores, invalid UTF-8. |
| Paste | Off/on/bypass; inline versus whole-line; CRLF payload, missing trailing newline, tabs, Unicode/emoji; embedded backtick runs; already fenced text; Markdown prediction; rich clipboard becomes plain text. |
| Undo | Replace selection, one undo restores old content/caret, redo deterministic, no orphan rules, ordinary typing before/after remains separate; pages and files. |
| Races | Edit/selection/document switch/close/undo during inference, second paste while pending, IME, stale projection, no duplicate paste. |
| Fences | Empty versus unknown explicit label, explicit label precedence, multiple fences, empty/unterminated fences, long delimiters, body edit invalidation, no cross-fence token state. |
| Files | Unknown suffix and no suffix, ordinary prose, UTF-8 BOM, CRLF, invalid encoding, NUL/control-heavy data, binary with text suffix, size boundary/file growth, reload/draft/Save As. |
| Rendering | All 48 slugs mapped explicitly; 12 existing colorers; unsupported label stays uncolored; whole-file source without Markdown interpretation; proportional prose with fixed-width code. |
| Boundaries | NULL ownership, one free per success, no input retained by wrapper, no store-lock inference, cancellation releases request state, sealed routes never invoke detector. |
| Presentation-only | No character edit ops, dirty flag, or file write from accepting a rendering suggestion; copy retains markup unless an explicit text-changing action occurred. |
| Packaging | Exact registry/model checksums, notices present in final artifacts, dependency license audit, supported-target builds, cold/warm performance and memory. |

Extend `shell/Tests/CompanionKitTests/CodeInkTests.swift` and
`CodeHighlightingTests.swift`. Update existing bare-fence/plain-outside-fence tests
only for the intentionally selected new modes; preserve assertions for default
and explicit-unknown-label behavior. Add focused detector/paste/file-mode tests.

## Validation commands for implementation

Run from the repository root. These use existing project build/test entry points;
they were not run for this documentation-only task.

```sh
cargo test -p companion-core
cargo test -p companion-ffi
scripts/test-shell.sh --filter CodeInkTests
scripts/test-shell.sh --filter CodeHighlightingTests
cargo test --workspace
cargo test --workspace --features test-util
scripts/test-shell.sh
```

The shell wrapper rebuilds the framework with test utilities before Swift tests.
Consult `CONTRIBUTING.md` and `.github/workflows/ci.yml` for the complete lint,
build, and supported-target checks. Add package-hash and evaluation commands only
after their scripts exist; this plan does not invent runnable script names.
