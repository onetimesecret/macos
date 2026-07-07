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
  `companion-pasteboard` (and later the shell glue). New dependencies
  arrive with the code that needs them and must pass `cargo deny check`.
- **Local gate** before pushing:
  `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`

By contributing you agree your work is licensed under the MIT license.
