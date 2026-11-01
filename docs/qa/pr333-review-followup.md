# PR 333 follow-up

This ledger records implementation decisions for the existing
[Claude review](https://github.com/onetimesecret/macos/pull/333#issuecomment-6381999153).
The review is feedback, rather than authority for product guarantees.
No reply or review comment is posted by this follow-up.

## Merge

Merged main at `1f83f70dc6410ec61e96512b5a7799986a59dd17` into the parser
branch. The only textual conflict was in `CHANGELOG.md`; both the parser and
sealed-object sync entries are retained.

## Feedback dispositions

| Feedback | Disposition and evidence |
| --- | --- |
| 1. Normalized plaintext allocation | `Source.text` uses `Zeroizing<String>`. Capacity includes NUL expansion, placeholder growth and the final newline, so normalization fits the initial allocation. A regression checks the owner type, expanded text and in-place zeroization. `Source.atoms` contains generated indexes and offsets, so it remains ordinary metadata. Document strings and comrak allocations still receive ordinary deallocation; this change does not eliminate those residual copies. |
| 2. Caller-controlled depth | `MAXIMUM_DEPTH` is 64 in the Rust parser, shared by direct and C callers. Smaller requested limits remain effective. Boundary, adversarial and FFI serialization tests exercise both dialects on a 512 KiB stack, including `usize::MAX`. The ceiling limits our document walk after comrak parses; it is not a universal allocation bound. |
| 3. Table-bound coverage and reproducibility | A test compares the normalized-input bound with the actual comrak cell count for all 677 GFM examples. Another tests an object inside a delimiter candidate after CR/CRLF normalization. The generator accepts explicit decimal page counts and seeds; `docs/qa/markdown-table-budget.md` provides the 1,400,000-page command. The earlier offline run is not treated as independently verified evidence. |
| 4. Hex-reference precedence | Parenthesized the bytewise case-fold operation in `numeric_reference_values`; behavior remains covered by upper/lower-case numeric-reference tests. |
| 5. Reference-definition fallback | Deferred to the integration checklist below. The stock-comrak behavior remains pinned by `comrak_0_57_keeps_definition_lines_in_a_paragraph_at_top_level`. Removing the refusal without a source-position fix would change object placement. |
| 6. Raw HTML | Retained parser-level raw markup. A new FFI regression checks script blocks and inline iframe tags in both dialects; the header describes the observed output. Filtering/rendering stays an integration responsibility. |
| Table-cell limit integer type | Retained `u64`/`uint64_t`: the pre-scan computes a saturating `u64` cell count, while scalar/depth limits and offsets use `usize`/`size_t`. No ABI change is needed. |
| Placement clones | `place` takes ownership of unplaced objects and moves them through containers and into output blocks, removing identity clones during placement. Existing placement and sealed-atom tests exercise the result. |
| Corpus notice cross-reference | `THIRD_PARTY_NOTICES.md` points to the corpus attribution and license records in `crates/markdown/tests/README.md`. |
| Dependency maturity | Retained the pinned comrak dependency and its selected transitive crates. The existing corpus and adversarial cases exercise parser behavior; advisory/license checks are not evidence of dependency maturity. No new production adoption occurs in this PR. |
| `entities` notice question | `cargo tree -p comrak -e normal,build --depth 2` lists `entities` under build dependencies. It is also this crate's dev dependency, not a resolved runtime addition, so the runtime notice list is unchanged. |

## Integration checklist for PR B

- Preserve and expose the known stock-comrak fallback case:
  `[r]: /u{obj}\n| a |\n| - |\n\n[x][r] [y][r]` returns
  `DuplicateObject("0")`, where `{obj}` denotes an object U+FFFC. The integration
  needs a deliberate plain-text fallback or a parser source-position fix.
- Rebaseline the two URL/object fixtures already identified by PR 333, and
  retain the five ignored source-position goals alongside their stock-comrak pins.
- Keep raw markup out of any unrestricted HTML execution path; the parser
  emits it unchanged, as the new FFI test demonstrates.
- Revisit Document/comrak plaintext allocation lifetimes before enabling the
  per-keystroke preview path. Wiping the normalized source alone does not wipe
  the whole parse operation.

## Validation

### Automatic review round after `cb03862b`

All CI jobs passed on that head, and Claude found no blocking correctness or
safety defect. The final local follow-up uses checked collision-vector capacity,
handles an object before a list's first item as a sibling, and updates the title
collision set incrementally after the destination. Regression cases exercise
the malformed-position case and the existing image/link object cases.

The corpus data now separates five test-writer tagfilter mismatches from eight
other combined parser/writer output mismatches. Tests pin the disjoint categories,
their exact 13-example union, byte output and the 664/677 total. This addresses
the inaccurate parser-only description through test structure and assertions.

The accepted authority for the Swift payload boundary is
[ADR-0012 Amendment 1](../adr/0012-framing-threat-boundary-and-persistence-model.md#amendment-1-three-egress-points-and-one-clear-interval):
"All three complete-payload writes are core-side. The Swift shell asks the
core to write to a named destination and never receives the sealed payload."
Our interpretation for this parser API is the caller obligation to supply
U+FFFC placeholders, stated in the header and tested through real FFI calls:
replacing a declared placeholder with ordinary text is refused as `objectOffset`.
The function cannot recognize resolved values if a caller omits object metadata;
the test does not establish such detection or a whole-operation erasure guarantee.

Retained the preallocation scans because growing the zeroizing collision vector
would retire its previous allocation. Source normalization and both JSON
serialization passes belong on PR B's performance-measurement list. Distinguishing
the documented NULL causes also remains a proposed consumer error-reporting task.
The existing ordinary-allocation limitations remain explicit above.

The Linux job at run `40559654315` completed the whole Markdown suite, including
the default 4,000-page generator, in 2.89 seconds. The generator remains enabled
in ordinary CI; no schedule or reduced default was introduced.

Local checks for this batch passed 96 Markdown tests with the same five ignored
goals and 13 Markdown FFI tests. Clippy with warnings denied, workspace formatting
and whitespace checks passed. The source-order regression reproduced the old
first-item placement before the fix. Dependency resolution and JSON ownership
code are unchanged from the earlier passing checks.

### Automatic review round after `916c15fb`

All CI jobs passed on that head. Claude's completed update again reported no
blocking defect. The next batch addresses its source-level suggestions:

- Refuse a body row before a table's header and any later header row, with
  parsed-tree mutation cases. Reuse the selected body-row index during object
  placement instead of looking it up twice.
- Pin unfiltered script blocks and inline iframe tags in direct parser AST
  tests as well as at the FFI boundary, independently of the test HTML writer.
- Use checked multiplication throughout the normalization-capacity arithmetic.
  Keep `InputLimit` for an arithmetic overflow; changing this unreachable-at-
  practical-input-size category would add an error/ABI change without a
  demonstrated caller benefit.
- Disable Git text normalization for the two digest-pinned corpus JSON files.
  Keep LF normalization for generated document JSON fixtures.
- Rename the small-stack FFI test to emphasize its adversarial inputs. The
  existing test still parses and serializes on a 512 KiB thread stack; a prose
  guarantee was not substituted for that executable coverage.

Allocation-lifetime decisions and restricted HTML rendering remain proposed PR B
work above. This follow-up does not create an accepted exception to a security
or privacy requirement. The default 4,000-page generator remains in ordinary CI;
the completed run did not show a reason to move coverage to a scheduled job.

Local validation for this batch passed 93 Markdown tests with the same five
ignored goals, plus all 12 Markdown FFI tests. Clippy with warnings denied,
workspace formatting, whitespace checks and the corpus digest tests passed.
`git check-attr` reports `text: unset` for both corpus files and `text: set`,
`eol: lf` for the generated document fixture. The earlier 11 JSON ownership
tests and dependency check passed before this batch; their sources and dependency
resolution are unchanged.

### Follow-up to the review of `761e25b2`

Claude's fourth completed update reported no blocking defect and listed these
remaining items. This follow-up treats the parser and FFI changes as defensive
hardening; it does not establish a new product guarantee.

| Item | Disposition |
| --- | --- |
| Unexpected list/table children | The walker returns `ParserFailure` for a non-item list child, a non-row table child or a non-cell row child. AST-mutation tests exercise each case after valid text and an object, so partial results are refused. Stock comrak input remains covered by the corpus. |
| Non-null refusal before UTF-8 validation | Preserved the byte-length shortcut and added a real FFI test around its boundary, including invalid UTF-8 and valid four-byte scalars. Rust/C descriptions state that callers decode and check the error case; a non-null refusal does not establish validated input. |
| Attribution in fixture documentation | Moved the existing marked corpus/table-budget prose, with its attribution intact, to `docs/qa/markdown-table-budget.md`. The fixture README links there using a code label. Its original source, digest and license paragraphs remain unchanged, and the fixture README contains no variation-selector marks. |
| Repeated-reference fallback | Retained the existing parser and FFI regression cases and the explicit PR B checklist above. Swift integration is outside this parser PR; no source-position tradeoff was changed to suppress the refusal. |
| Observations with no requested action | Kept the test-module split, conservative final line scan and dependency-version disposition. Test counts in the PR description are refreshed from this follow-up's runs. |

Local follow-up validation passed: 90 Markdown tests (five existing ignored),
12 Markdown FFI tests and 11 JSON ownership tests. Clippy with warnings denied,
workspace formatting and whitespace checks passed. Cargo-deny passed all four
gates, with the existing duplicate-version warnings. The moved prose and its
attribution were compared byte-for-byte, and the fixture README's relative link
resolves. Remote results are checked on the pushed head separately.

### Automatic review round after `2ba6e270`

All CI jobs passed on that head, and Claude completed a third updating review.
It accepted the document-AST/raw-HTML layering and retained downstream rendering,
reference-position fallback, performance measurement and attribution-policy notes.

The new BOM report exposed a concrete semantic defect, but its proposed fix was
not adopted. With two leading U+FEFF characters, normalization removed one and
comrak then skipped the next; stock comrak skips only the first. Removing an
entire leading run would also erase meaningful subsequent characters.

The source now retains BOM bytes for comrak to process and counts those bytes in
its recorded positions. Regression tests cover one, two and three BOMs in both
dialects, text and reference definitions, multibyte/plane-16 text, objects, CRLF,
byte columns and original UTF-16 offsets. The two-BOM regression failed before
the change. Local Markdown validation passed 87 tests with the same five ignored,
and clippy passed with warnings denied.

The FFI Rust description now states the depth cap, and the duplicate-dependency
note explicitly identifies the pre-existing betlang edge. Historical agent notes
are not used as current CI evidence. No parser-placement tradeoff was changed to
suppress a refusal, and intentional TextProv attribution remains intact.

### Automatic review round after `45db30bb`

All CI jobs passed on that head. Claude's next completed update was read before
this third batch, with these dispositions:

- Retained raw HTML as distinct document/inline JSON cases. This parser returns
  a document tree and does not execute HTML; the allegation that its HTML cases
  are indistinguishable from ordinary text does not match the enum or JSON.
  Filtering those cases here would change the composer's input contract. The
  future integration still needs restricted rendering; this decision does not
  establish a filtering or execution guarantee for that future consumer.
- Renamed the synthetic refusal-shape test, added the actual repeated-reference
  CommonMark input at the FFI boundary, and described the reachable
  `duplicateObject` refusal. The original-page fallback stays explicit.
- Added an actual-cell-count check after comrak parsing and before the document
  walk. The pre-scan still acts before allocation; the second check can refuse
  a tree exceeding the requested budget but cannot prevent its construction.
- The collected plane-16 scalar values use a preallocated zeroizing vector.
  Numeric-reference scanning yields values lazily from borrowed bytes, with no
  temporary values vector. Extra scans avoid growth of the collected vector;
  preview-path performance measurement remains integration work.
- The corpus README distinguishes the test HTML writer from the parser: five
  GFM mismatch entries describe its tagfilter, not AST-only parser differences.
- Retained TextProv prose attribution. A repository-wide attribution allowlist
  is deferred; checked executable examples and changed Rust/TOML/C-header files
  contain none of these prose markers. No existing attribution is removed.
- Narrowed the LF rule to Markdown crate JSON fixtures. The C header and a real
  FFI refusal test now describe the 65,534-placeholder ceiling and rejection of
  65,535 objects. JSON corpora remain reviewable rather than disabling their diffs.
- Preserved argument-validation error precedence and the current line scanner.
  The suggested ordering changes did not identify an observable defect.

Third-batch local validation passed: 84 Markdown tests, 11 Markdown FFI tests,
formatting, whitespace checks and clippy with warnings denied. The same five
upstream source-position goals remain ignored; none was silently removed.

### Automatic review round after `2cb6bdb5`

- CI and the automatic Claude review completed successfully on that exact head.
  Claude's updating comment was refreshed on 2026-10-27.
- The variation selectors in the new Markdown prose are TextProv attribution
  from the configured edit hook. They are retained. Executable fenced examples
  and inline code are checked separately; removing attribution is not a code fix.
- Tested and rejected the proposed `self.emitted[atom]` address guard. On the
  reported repeated-reference fixture it places object 0, whose source offset is
  7, after the first reference's label. Avoiding the error would preserve that
  incorrect placement. The new regression covers the known single-reference
  position and refusals for two and three references under CommonMark.
- The excess-header-cell scenario does not produce a table: comrak 0.57.0's
  `parser/table.rs` rejects a header/delimiter cell-count mismatch. GFM example
  203 already tests that paragraph result. Excess body cells retain their
  existing placement coverage.
- Comrak's required `memchr-n` dependency has no feature to remove its SIMD
  dependencies. The two `fearless_simd` versions remain: Betlang uses 0.4.0,
  while `memchr-n` uses 1.1.0. The exact older version now has an explained
  duplicate-version skip; advisory, source and license gates still apply.
- The lockfile adds 17 external package/version pairs plus the local Markdown
  crate compared with main: comrak, ten new runtime transitive packages, and six
  build/procedural-macro packages. The changelog's ten-runtime-transitives count
  remains accurate; `entities` belongs to the build group.
- An explicit fuzz sample size may now be any positive count. The default still
  runs 4,000 generated pages, while a 100-page run with seed 333 passed.
- JSON files use LF through `.gitattributes`, including the golden output fixture.

### Local validation by batch

The second implementation batch also pins tab-prefixed quote/list placement,
reference definitions, multibyte text and original UTF-16 offsets under LF and
CRLF. The FFI tests distinguish image address object parts from link stand-ins;
the Rust and C descriptions now match those tests. The dialect parameter stays
an integer, with unknown codes rejected by the existing argument tests.

Second-batch validation: 82 Markdown tests passed with 5 existing ignored;
9 Markdown FFI tests passed. Clippy, formatting, diff checks and all four
cargo-deny gates passed. The default suite completed its test execution in
1.14 seconds on this machine, including the 4,000-page generated sample.

First-batch checks:

- `cargo test --locked -p companion-markdown`: 80 passed, 5 existing ignored.
- `cargo test --locked -p companion-ffi markdown`: 8 passed.
- `cargo test --locked -p companion-ffi content_json`: 11 passed.
- The table generator also passed 8,000 pages with seed 333.
- `cargo clippy --locked -p companion-markdown -p companion-ffi --all-targets -- -D warnings`,
  `cargo fmt --all --check` and `git diff --check` passed.
- `cargo deny check` passed advisories, bans, licenses and sources; existing
  duplicate-version warnings remain.
- Remote checks and updated Claude feedback are assessed separately after push.
