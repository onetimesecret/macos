---
name: issue332-spec-corpus
description: Issue 332 PR A unit 2, the spec corpus in crates/markdown; where the data came from, why the README cites a branch commit, and which GFM mismatches are comrak's versus the harness's
metadata:
  type: project
---

The spec corpus comparison moved from the shell to `crates/markdown/src/tests/corpus.rs` and `html.rs` (2026-10-24, uncommitted at write). CommonMark is 652 of 652; GFM is 664 of 677.

- The data is in `crates/markdown/tests/` (JSON plus README). The GFM file is the lab's extracted `gfm-official-examples.json`, not the 496 KB page, so the Swift page extractor was not ported; both files are pinned by SHA-256 through a `ring` dev dependency.
- **Why the README cites commit 41266668 on feat/markdown-dialects:** the plan skips the lab commits, so `tools/markdown-preview-lab` never reaches main.
- The five tagfilter mismatches (140 to 147) come from the harness's own cmark-gfm tagfilter emulation, not comrak. The other eight are comrak's own output (checked against `comrak::markdown_to_html`).
- Compared with the cmark-gfm table: 324 and 615 now match (comrak runs autolinks per text node before it joins a backslash escape), and 634 differs for another reason (`email_match` gives up at a second `@`).

**How to apply:** a later unit that removes the Swift corpus test or the lab must keep the README provenance true. Root THIRD_PARTY_NOTICES.md lists only shipped components; non shipping third party material gets a notice beside it (see docs/mockups/multiple-pads).
