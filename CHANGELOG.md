# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository skeleton per the spec's initialization prescription
  (docs/spec/07): Cargo workspace, CI lanes, ADR practice, governance
  files.
- `companion-core`: zeroizing cell store, TTL ladder
  (1h → 3h → 8h → 24h → 3d → 7d, default 8h), scheduled expiry (no
  polling), cap-refusal at twelve cells, conservative secret-shape
  heuristics, lifecycle states.
- `ots-client`: sans-IO client for the Onetime Secret v3 API — conceal
  (authenticated + guest routes), auth as a swappable strategy (HTTP
  Basic now, PASETO later), downward TTL snapping, share-link assembly.
- `companion-pasteboard`: the pasteboard hygiene contract
  (`ConcealedType`, transient marking, change-count-guarded
  clear-after-copy) with an in-memory implementation; the `NSPasteboard`
  adapter follows in milestone 2.
- A headless demo of the SleeperCell lifecycle:
  `cargo run -p companion-core --example demo`.
