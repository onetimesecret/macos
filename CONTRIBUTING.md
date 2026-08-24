# Contributing

Short version: this is a spec-first project.

- **Behaviour changes start in `docs/spec/`.** If a PR changes what the
  app does, the spec diff comes first (or with it), not after.
- **Decisions land as ADRs** (`docs/adr/`), using the template — context,
  decision, consequences, and eject triggers.
- **The anti-goals are the review bar.** Doc 01's anti-goals and doc 03's
  principles are how feature PRs get evaluated. Features that add
  retention, organization, or engagement are declined by default
  (principle 4); "no" is the expected answer to most scope additions.
- **Keep the crates honest.** `companion-core` and `ots-client` stay free
  of UI and platform dependencies; `unsafe` lives only in
  `companion-core`'s `secret`/`harden` modules (page locking, core-dump
  hardening), `companion-ffi` (the C seam), and `companion-pasteboard`
  adapters — each occurrence with a SAFETY note. New dependencies arrive
  with the code that needs them and must pass `cargo deny check`.
- **Local gate** before pushing. `.github/workflows/ci.yml` is the
  source of truth; this is the same set, in one line, on a Mac:

  ```sh
  cargo fmt --all --check \
    && cargo clippy --workspace --all-targets -- -D warnings \
    && cargo test --workspace \
    && cargo test --workspace --features test-util \
    && ./scripts/build-core.sh --test-util \
    && swift build --package-path shell \
    && swift test --package-path shell
  ```

  The last three are not optional extras. `cargo test` enables no
  features of its own (cargo issue 2911), so the run without
  `--features test-util` never touches the gated seams (ADR-0018); and
  `swift test` links `companion_new_ephemeral`, which only a
  `--test-util` core exports, so it fails at link rather than skipping
  if the xcframework is the release shape. Without those steps a
  contributor who changes `PageModel`'s persistence can pass the gate
  having run none of the tests that cover it.

By contributing you agree your work is licensed under the MIT license.
