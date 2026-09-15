# Betlang transitive-license review — 2026-09-14

Status: **reviewed with an unresolved provenance question**

This is an inspection record, not legal advice or release approval. The authoritative proposed release requirement is ADR-0029, License and redistribution:

> “preserve Betlang's MIT license/copyright notice, include the quoted Magika attribution and Apache-2.0 license text in shipped third-party notices, and review any applicable upstream NOTICE material and transitive dependency licenses.”

## Resolved runtime dependency

`cargo tree -p companion-core --edges normal` resolves Betlang's runtime path as:

```text
betlang v0.1.1
└── fearless_simd v0.4.0
```

`Cargo.lock` records `fearless_simd 0.4.0` from crates.io with package checksum `76258897e51fd156ee03b6246ea53f3e0eb395d0b327e9961c4fc4c8b2fa151a`.

The published `fearless_simd 0.4.0` package was inspected in Cargo's registry cache. Its normalized manifest declares `Apache-2.0 OR MIT`; `.cargo_vcs_info.json` records revision `c3632abfdbe3357ddb68496f9c4dd001ff13e218`. The archive contains `LICENSE-MIT` and `LICENSE-APACHE` and no file named `NOTICE`. The MIT text is reproduced in `THIRD_PARTY_NOTICES.md` with the dependency path and package identity.

`cargo deny check licenses` accepts the resolved workspace licenses under `deny.toml`. This is tool output against the configured allowlist, not a legal determination.

## Unresolved provenance question

The published package's runtime source `src/impl_macros.rs` says exactly:

> “Adapted from similar macro in pulp”

The package does not identify a `pulp` version or include separate `pulp` attribution. `pulp` is not a resolved runtime dependency of this workspace. Local inspection does not establish how much material was adapted or whether another redistribution notice is required. Obtain upstream clarification or legal review before treating this provenance question as closed.

The separate embedded-model licensing blocker recorded in `THIRD_PARTY_NOTICES.md` also remains unresolved.
