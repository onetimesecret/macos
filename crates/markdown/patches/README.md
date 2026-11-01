# Vendored comrak reference-position fixes

`companion-markdown` uses the runtime library subset of crates.io `comrak` 0.57.0
in `vendor/comrak`, with default features disabled. The research lab and the
former C parsers are separate from this source tree.

The source archive is
<https://static.crates.io/crates/comrak/comrak-0.57.0.crate>, SHA-256
`b5ef59c72b988dfc7c73ec58ec0dc50f95dd87d7f1f39f428902bc379cea8507`.
Its `.cargo_vcs_info.json` identifies upstream revision
`a39f26a0b0f63db2cb5aaa172f0de5eeb51c8b6c`.

## Local patches

- `comrak-0.57.0-reference-sourcepos.patch` advances surviving paragraph/heading
  source positions and their inline line-offset table after consuming reference
  definitions. It clears the title when a next-line title is rejected and the
  scanner rewinds. This also corrects comrak link-title/HTML output for that
  rejected-title case. It adds four direct AST regression tests.
- `comrak-0.57.0-runtime-manifest.patch` removes unused CLI, example and benchmark
  targets and upstream development dependencies. Library unit tests and doctests
  are disabled, and the dependency-local release profile is omitted; the source
  subset omits upstream test modules and fixtures. The four
  direct regressions run through the explicit `comrak_reference_sourcepos` test
  target in `crates/markdown/Cargo.toml`.

The inventory `comrak-0.57.0-vendor.json` records both patch hashes and every
vendored file hash. It also lists all 102 excluded upstream files. The official
archive has 134 files: 32 are retained, 102 are excluded, and the patch adds one
regression file. Reproduction checks the exact exclusion set before applying
the patches. Apart from the parser and manifest patches and the new test
file, retained files match the published archive byte for byte. `COPYING` is
retained in full; its exact text is also in `THIRD_PARTY_NOTICES.md`.

## Reproduce and check

```sh
# Check the local file inventory, patches, dependency declaration and lock entry.
scripts/verify-vendored-comrak.py

# Reproduce the selected files from the official archive plus both patches.
scripts/verify-vendored-comrak.py --upstream

# An explicit archive can be used without downloading it.
scripts/verify-vendored-comrak.py --archive /path/to/comrak-0.57.0.crate

# Both parser tests and the direct dependency regressions run here.
cargo test -p companion-markdown --locked
cargo test -p companion-ffi markdown --locked
cargo fmt --check
```

The default verification uses the pinned inventory without network access.
`--upstream` uses the Cargo cache when present, otherwise downloads the official
archive and checks its pinned digest before reading it. CI runs this reproduction
and the verifier mutation tests. The core build runs the local check, including
when its build cache is current, and source-staleness detection includes the
vendored Rust files and manifest.

The vendor crate is excluded from workspace membership. `cargo fmt --check`
formats the virtual workspace; `cargo fmt --all` additionally traverses local
path dependencies and would try to format third-party source. Workspace Clippy
and tests target the application crates and the explicit dependency regression
harness.

## Validation

The same four direct AST tests give one pass and three failures against stock
0.57.0, and four passes with the patch. They cover LF, CRLF and CR; top-level,
list and nested-quote paragraphs/setext headings; multiple/multiline definitions;
EOF-only definitions; and rejected next-line titles.

All five issue-332 source-position goals are enabled in
`src/tests/definitions.rs`. The six tests that expected the old misplaced-object
or stale-title behavior were removed. The parser suite passes 96 tests, with only
the manual synthetic profile skipped, and the four direct AST tests pass. The
CommonMark/GFM corpus comparisons pass. The real FFI regression checks the full
repeated-reference document: one definition object before the subsequent text,
and two reference destinations containing its inert stand-in. The FFI Markdown
subset passes 13 tests, with its manual profile skipped.

## Registry-origin policy coverage

Cargo-deny 0.19.9's [`Report::generate`](https://github.com/EmbarkStudios/cargo-deny/blob/0.19.9/src/advisories/helpers/db.rs#L315)
uses this expression while matching advisories:

```rust
let ksrc = km.krate.source.as_ref()?;
```

A local path package has no registry source, so that version of the tool skips
its advisory matching. In a controlled local test with a synthetic comrak
advisory affecting 0.57.0, the workspace path-package check exited successfully;
the registry-origin probe failed with that advisory. The synthetic record was
local test data, not a real advisory or a published report.

CI therefore also checks the official registry origin at the exact version from
the verified archive. Its temporary workspace starts with comrak's dependency
closure from the application lockfile. Cargo normalizes feature-specific lock
edges there; the script compares package versions, sources and checksums before
and after normalization and refuses changed pins. The workspace and registry-origin checks both use the
repository `deny.toml`. The registry-origin check runs all four categories:
advisories, bans, licenses and sources. Its unpublished probe package uses
the workspace MIT license metadata. CI pins cargo-deny-action commit
`3c6349835b2b7b196a839186cb8b78e02f7b5f25`, whose container uses cargo-deny
0.20.2. In that version `--config` is a global option before `check`; 0.19.9
used a check-local option. The command below uses the CI version. See the
[pinned Action Dockerfile](https://github.com/EmbarkStudios/cargo-deny-action/blob/3c6349835b2b7b196a839186cb8b78e02f7b5f25/Dockerfile)
and [0.20.2 graph options](https://github.com/EmbarkStudios/cargo-deny/blob/0.20.2/src/cargo-deny/main.rs#L107-L126).

```sh
scripts/verify-vendored-comrak.py --advisory-workspace target/comrak-advisories-new
cargo deny --manifest-path target/comrak-advisories-new/Cargo.toml --locked \
  --config deny.toml check
```

Use a new destination directory for each preparation. Cargo may download the
pinned registry package when it is not cached. The application dependency stays
on the vendored source. This check applies the repository policy to the upstream registry package
and matches published advisories for that version; it does not analyze the
local patch for new defects.

## Separate full-source library test run

Upstream test modules are absent from the shipped subset and normal workspace
unit-test targets. A separate temporary copy of the verified full archive, with
only the parser patch, passed all 556 library tests under
`cargo test --no-default-features --locked --lib`. The tested parser file matches
`vendor/comrak/src/parser/mod.rs` byte for byte. Optional-feature tests and
doctests are not covered by that command. The application corpus and four
direct AST regressions remain the normal in-repository checks.
