# Markdown follow-up validation after #336

The branch starts from merged main `54160fa75ec578ee5ddf5094a795eff58e959c3e`.
This record reports implementation and executed checks, not additional product
promises. PR #337 is marked ready for review. The human spoken walkthrough remains
unverified; ready status does not record that check as complete.

## Current implementation

- The user selected a vendored patched comrak Rust crate. `vendor/comrak`
  contains the runtime subset of the official 0.57.0 package plus two recorded
  patches. The former C parsers and research lab are separate.
- All five source-position goals are active. Swift and FFI fixtures now expect
  definition objects before subsequent text and successful repeated references.
- Large previews parse/decode on a serial actor and compose in cooperative
  main-actor batches. The loading label uses preview typography; completion
  posts an accessibility value-change notification after updating the roll.
- Image actions retain full accessibility destinations while compact labels
  keep the action visible. Narrow image tables stack and restore on widening.
  Raster pixel dimensions, not an image's logical point size, determine Retina
  fitting. Native key loops refresh on geometry and visibility changes.
- The explicit system-DNS/proxy routing proposal and pre-activation help remain.
  The real-socket positive fixture uses an immutable source commit and verifies
  MIME, byte digest, dimensions, and decoded pixels. Fixture publication and
  cleanup are bounded and include diagnostic reports.

## Executed checks

- Latest full Swift suite: **2,631 passed, five opt-in tests skipped**, with no
  failures (393 OnetimePad and 2,238 CompanionKit passed).
- All 41 image-control, nine deferred-render and 18 loader tests pass in the
  full suite on this keyboard-navigation-enabled Mac.
- Native Tab tests explicitly skip when macOS keyboard navigation is disabled.
  Visibility/recalculation metadata tests still run in that configuration.
  The first CI head failed only the preference-dependent Tab test; the skip
  condition addresses that runner difference without changing user settings.
- Three opt-in real-socket tests pass: pinned PNG through a loopback CONNECT
  proxy with default TLS, proxy-authentication refusal, and untrusted local TLS
  refusal. Timeout/SIGTERM diagnostic publication was also exercised.
- Vendored Rust parser and four direct AST regressions pass; the five formerly
  ignored goals run in the normal suite. The real FFI Markdown subset passes.
- Source reproduction from the official archive plus both patches, verifier
  mutation tests, workspace formatting, targeted all-target Clippy, English
  strings parsing, diff checks, and all 53 ADR checks pass.
- Root cargo-deny checks pass. A separate registry-version policy projection
  checks the pinned upstream comrak version because the tested cargo-deny
  version omits path packages. See the vendor README for the exact tool scope.

Earlier local full runs failed four UI cases with the same assertions on merged
main. The latest full run above passes those cases; this change does not purport
to repair the unrelated animation/menu tests.

## Human and network limitations

The native keyboard order was exercised in the isolated host at 320/600 points,
including disabled controls and the native scroller. Those actions do not
certify spoken VoiceOver, rotor behavior, or visual size/sharpness on physical
1x/2x displays. That human walkthrough remains unverified.

The host app's `AXIsProcessTrusted=false` was a self-check, not a prerequisite
for the automated in-process tests. The app under test does not need permission
to control other apps for these tests. The chat's native-control tool capability
is independent of that macOS permission. On the supplied macOS 27 screenshots,
the permission pane is named Device Control and Data Access.

A positive trusted-private-origin fixture was unavailable. The positive tunnel
and untrusted-local-TLS cases do not certify that separate scenario. No system
proxy/trust settings or Keychain contents were changed.

All model tests and the manual host inject temporary state and in-memory
credentials. No person's running app was launched, replaced, quit, or reset.

## Evidence and housekeeping

- `/tmp/pr337-vendor-swift-full.log`
- `/tmp/pr337-vendor-swift-final-focused.log`
- `/tmp/pr337-imagecontrols-feedback.log`
- `/tmp/pr337-network-followup-tests.log`
- `/tmp/pr337-vendor-clippy.log`
- `/tmp/markdown-followup-validation/tab-traversal.json`

#332 is reconciled and stays open for unfinished validation. Superseded #328 is
closed; its original branch remains available. The research lab was not imported.

See the [vendor provenance and reproduction guide](../../crates/markdown/patches/README.md),
[review dispositions](pr337-review-followup.md),
[performance record](markdown-preview-performance.md), and
[human image walkthrough](markdown-image-polish.md).

## Expanded execution at final code

All implementation changes in this pass are committed in
`afbee4ac6d1e9dae88d23ebd5fc595f88dd75052`. Later documentation and CI
invocation changes do not change the tested application source bytes. The final UI probe records that clean
commit plus source and linked-binary hashes; earlier dirty-snapshot probes are
superseded by its final 866-check run.

| Check | Result and scope |
| --- | --- |
| Full Swift | 2,631 passed, five opt-in skips; no failures. |
| Swift ThreadSanitizer | 30 passed; 400 concurrent real FFI calls plus deferred-render and loader tests. Linked Rust static library was not instrumented. |
| Rust workspace with `test-util` | 1,356 passed, three manual profile skips. A native unique-pasteboard assertion failed on the initial run, then passed alone and in the full rerun; its source is unchanged by this PR. |
| Python scripts | 157 passed, including all 15 vendor-verifier tests. Initial sandbox failures involved compiler-cache writes and temporary Git fixture commits; the permitted run passed. |
| Vendor reproduction | 134 official archive files accounted for: 32 retained, 102 explicitly excluded, plus one patch-added regression file. Both patches reproduce the 33-file tree. |
| Bounded parser stress | 42,520 dialect cases, each with one direct AST parse and four application parses, covering line endings, references/titles, nested prefixes, Unicode, NUL and object offsets. No panic or inconsistent repeated result observed. Temporary harness; no coverage-guided fuzzing. |
| Expanded UI | 866 checks, zero failures/skips; 24 width/font/appearance cycles, actual font Settings paths, native keyboard traversal and AX actions/metadata, copy/object identity, capacity and late-completion lifecycles. 36 PNGs; deterministic raster loader, real parser/UI. |
| Controlled network | Three real-socket tests passed separately on final code: immutable public PNG tunnel/default TLS, proxy authentication refusal, untrusted local TLS refusal. |
| Numeric-host policy | Eight alternate IPv4 forms rejected before injected transport; native numeric parsing was checked without DNS/network. DNS/private-peer routing remains the recorded system-policy proposal. |
| Other checks | Archive reproduction, corrected locked advisory projection, formatting, English strings, all 53 ADRs and diff checks pass. |

Final executable commands included:

```sh
swift test --package-path shell
cargo test --workspace --locked --features test-util
python3 -m unittest discover -s scripts/tests -v
python3 scripts/verify-vendored-comrak.py --upstream
PREVIEW_NETWORK_TESTS=1 swift test --skip-build --package-path shell --filter PreviewImageNetworkTests
swift test --package-path shell --scratch-path /tmp/pr337-tsan-build --sanitize thread --filter 'MarkdownParserTests.testParsesOnManyThreadsEqualTheSameParsesInTurn|MarkdownDeferredRenderingTests|MarkdownPreviewRenderingTests.testReseeding|PreviewImageLoaderTests'
PREVIEW_PROFILE=1 PREVIEW_NATIVE_TABLE_PROFILE=1 swift test --skip-build --package-path shell --filter 'MarkdownIntegrationPerformanceTests.testOptInLargePreviewProfile|MarkdownPreviewRenderingTests.testOptInNativeTableRenderAndLayoutProfile'
```

Expanded logs and artifacts:

- `/tmp/pr337-literal-final-swift-full.log`
- `/tmp/pr337-literal-final-tsan.log`
- `/tmp/pr337-expanded-rust-workspace-retry.log`
- `/tmp/pr337-expanded-python-final.log`
- `/tmp/pr337-expanded-real-network.log`
- `/tmp/pr337-expanded-advisories.log`
- `/tmp/pr337-parser-stress/` (temporary harness and log)
- `/tmp/pr337-expanded-ui/` (probe, report, source/binary hashes and specimens)
- `/tmp/pr337-keyloop-profile/` (test-owned window timing probe)
- `/tmp/pr337-expanded-profiles-serial.log`

The second review's drain-bound concern was not reproduced or exhaustively
disproved. Window-wide key-loop coalescing and remaining main-actor table/block
latency remain performance follow-ups. Human spoken VoiceOver/rotor and physical
display judgment, a trusted private-origin fixture, and final-head CI/review
remain separate readiness checks. The PR was draft at this checkpoint; it is now ready for review.

The background probe's in-process `accessibilityPerformPress()` calls changed
button state although their return value was false. The 866 checks cover
resulting actions and metadata; external AX-client success and spoken output
were not certified.

The first CI correction passed cargo-deny 0.19.9 locally but failed the Action's
0.20.2 CLI. The final workflow pins the Action commit and places `--config`
before `check`. The official macOS 0.20.2 release binary was downloaded to a
temporary directory, checked against the GitHub release SHA-256, and used to run
the exact pinned Action entrypoint/argument grouping successfully. Installed
tools were unchanged. Evidence: `/tmp/pr337-cargo-deny-0.20.2/`.

The last application fix reuses completed equivalent output on pages without
images, preserving selection and avoiding the loading flash. Typeface is part
of the render identity, including code-family changes with unchanged prose.
Two regressions bring the final full Swift total to 2,631 passes/five opt-in
skips, and the final sanitizer subset to 30 passes. The 866-check UI matrix
was rerun on clean application commit `61ccb43a`; source hashes match.

A process-only keyboard-mode experiment used argument-domain values 0 and 3.
The requested values were visible through `UserDefaults`, but AppKit reported
full keyboard access true in both processes on this enabled-preference host.
That override is not used to force CI traversal. Evidence is in
`/tmp/pr337-keyloop-profile/keyboard-zero.log` and `keyboard-three.log`.
All six CI build/test jobs passed on preceding head `efcd15fe`; final-head CI
and Claude review are separate from that result.

## Additional upstream and comparison checks

The final application files are committed by `afbee4ac` (application change
`82c8574f`). Full Swift: 2,631 passes/five skips; ThreadSanitizer: 30 passes;
isolated UI: 866 checks/zero failures/skips, with a clean matching source and
linked-binary snapshot. The mounted-height regression awaits its render task
instead of attaching a callback that a later layout could replace.

A full copy of the official comrak archive was unpacked under a temporary
directory, verified with the recorded archive digest, and given only the
recorded parser patch. Its parser file matches the shipped vendor bytes.
`cargo test --no-default-features --locked --lib` passed all 556 upstream library
tests, including source-position and pathological-input cases. This uses the
full upstream manifest/test modules outside the shipped subset. Upstream
optional-feature and doctest coverage is not inferred from this run. Evidence:
`/tmp/pr337-upstream-comrak-tests/run.log`.

A string-only comparison benchmark used 100 repetitions per synthetic sample.
The optimized one-million-unit comparison measured 3.94 ms with the bridged
UTF-16 walk and 0.026 ms with `NSString.isEqual(to:)`; literal Unicode edit
regressions pass with the latter. Debug and optimized logs/source are under
`/tmp/pr337-source-comparison*`. These are comparison timings, not full reseed
or frame-time results. The root scan also passes with the exact pinned
cargo-deny 0.20.2 binary and `--locked`; the workspace lock bytes were unchanged.
All six build/test jobs passed on previous head `90e6385a`; final-head CI and
Claude review remain separate.

## Review follow-up at `6986d17a`

The source update `891b168c` simplifies deferred completion and removes the
unreachable image-consent reuse option. The generation check still rejects
superseded renders; current cancellation still installs the current source
without leaving the preview busy. Destination/range tests now refresh a mounted
preview through model edits, and network-fixture log creation throws on failure.

- 50 focused Swift tests passed; three default opt-in skips.
- All three real-network cases passed when enabled separately.
- All 158 Python script tests passed on an approved rerun after sandbox
  restrictions blocked Xcode caches, Icon Studio services and the signing agent.
- The registry-origin projection now runs every cargo-deny category. The exact
  pinned 0.20.2 tool reports advisories, bans, licenses and sources OK.
- All 16 vendor-verifier tests, workspace formatting, local vendor inventory
  and all 53 ADR checks pass.

These are focused follow-up results; the full Swift/Rust counts above describe
the earlier source snapshot. Final pushed-head CI and updated bot reviews are
checked separately. Human spoken/physical-display validation remains unverified.
