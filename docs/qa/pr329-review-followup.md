# PR 329 review follow-up

This is a delivery record for [PR 329](https://github.com/onetimesecret/macos/pull/329), based on head `396ac6b3`. It is not a specification. ADR-0058 remains proposed.

Feedback sources: [Claude review](https://github.com/onetimesecret/macos/pull/329#issuecomment-6376335994) and [Greptile review](https://github.com/onetimesecret/macos/pull/329#issuecomment-6392502460). Copilot feedback was absent from the API results during this pass.

| Feedback | Disposition | Evidence or reason |
| --- | --- | --- |
| Greptile 1 / Claude 1: note updates miss other records | Addressed | Direct and pending note updates visit every readable record; tests include a named record that refuses unrelated history. |
| Greptile 2: removal discards a detached note | Addressed | `follow_sentinels` folds the departing note into the surviving value record; regression checks the shared-history edit. |
| Greptile 3: move inserts a duplicate sentinel | Addressed | Transfer settlement waits for the destination edit, and the plan omits identities already standing there. Tests cover mixed ink, snapshot restore and a refused destination write. |
| Greptile 4: paste overlooks a local value | Addressed | `live_object` prefers a readable local record; tests cover peer-first tab order and an expired value page. |
| Greptile 5: open note misses received edits | Addressed | The open editor refreshes through the existing projection merge; tests check selection movement, the next edit and input-method composition. |
| Claude 2: burn leaves pending entries | Addressed | Burn purges note and metadata entries by identity; late batches for a terminal identity are ignored. |
| Claude 3: detached fallback duplicates a record | Addressed | `stand_in` searches detached records as well as standing records; a regression exercises the fallback. |
| Claude 4: same-name rename skips other records | Addressed | The no-op check compares every readable matching record; a regression starts with inconsistent names. |
| Claude 5: zero-writer provenance | Deferred | The record does not distinguish a local pre-sync version from a received zero-writer version. Changing stamping without persistent provenance could change existing name convergence. A separate provenance design is needed. |
| Claude 6: absent availability defaults to true | Addressed | Availability is required during face decoding; tests reject missing, null and non-boolean values. |
| Claude 7: deadline top-up revives a due page | Rejected premise | The regression checks that pause, rung change and peer hold cannot revive the due page. |
| Claude 7: frame rejoin succeeds without adoption | Addressed | `absorb_frame` refuses a due target before recording a rejoin; regression checks the original page identity and channel map. |
| Claude 8: repeated membership scans | Partly addressed | Document duplicate detection and note-cursor pruning use sets. Per-envelope metadata indexing is deferred: it would add a separate routing structure; no performance measurement was supplied. Pending metadata scans remain bounded at 256 entries. |
| Claude 9: descending removal offsets | Already documented; tested | `take_out_standings` already says “Returns the positions taken, last first.” A regression now checks three removals and original offsets. |
| Claude 10: agent memory in the branch | Retained | These files follow the repository's existing tracked agent-memory layout. This pass adds no agent memory and leaves the existing branch material intact. |

Validation: core library 716 tests, FFI library 383 tests, FFI with test-util 396 tests, and focused Swift lane 67 tests passed. Core/FFI clippy with all targets and warnings denied, Rust formatting, and diff whitespace checks passed. Swift tests used temporary state and ephemeral credentials; no installed app was launched. An independent final code review found no additional actionable defect.

## CI follow-up at 59f631f5

The [shell job](https://github.com/onetimesecret/macos/actions/runs/40161462621/job/121073738743) ran 2298 tests with four skips and one failure: `CompanionClientTests.testChipInfoDecoding` omitted the now-required `available` field. The fixture is updated with an explicit local availability value and an assertion for a peer face.

All five original review threads are resolved. The other five code-validation jobs passed. The [Claude review job](https://github.com/onetimesecret/macos/actions/runs/40161462667) stopped at the service spending cap before publishing a new review; the Greptile summary still refers to the earlier reviewed commit. No new Copilot feedback appeared in the API results.

After reproducing the decoder failure, `scripts/test-shell.sh --disable-sandbox` passed all 2298 XCTest tests with zero failures. The fixture update changes no production code. Diff whitespace checks passed.
