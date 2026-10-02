# PR #232 review follow-up

This checklist tracks the observations in [Claude's review](https://github.com/onetimesecret/macos/pull/232#issuecomment-5945850036). It records implementation changes and verification, not accepted product guarantees. ADR-0039 remains proposed; the manual runbook remains owed on a signed native build.

| Observation | Resolution |
| --- | --- |
| 1. Missing FFI UUID contract | Document stable tab identity, restore-reminted numeric handles, newly minted UUIDv7 and unchanged legacy UUIDv4 values in the C header. |
| 2. Wall-clock panic | Clamp pre-epoch and overflowing timestamps in both generators; retain secure random bits. Test timestamp bounds and non-finite Swift dates. |
| 3. Growing catalog and repeated writes | Reconcile against complete live rosters after restoration, prune closed-item references and expired-date sorting, bound recency, and suppress no-op mutations. Preserve catalog ownership when content restoration refuses. |
| 4. Permanent pad names/entries | Add rename and remove controls within each named pad cell. Removal drops associations and moves existing pages/files to implicit Scratch ownership. Scratch cannot be removed. Reject invalid names visibly rather than silently truncate. |
| 5. Forgotten file selection | Remember each pad's selected open file alongside its tab; follow path transfers even while the experiment is off, and discard closed-file references. |
| 6. Directory aliases | Compare explicitly supplied roots using symlink resolution and available physical identity; resolve existing prefixes for missing file leaves and use volume case sensitivity for matching. Unavailable metadata retains a documented fallback limitation. |
| 7. Magic recency limit | Name the nine-pad recent-set constant and document its provisional policy separately from numbered shortcuts. |
| Implicit Scratch ownership during file transfer | Transfer recorded ownership only; Scratch stays implicit. |
| Extra roster fetch for new tabs | Assign queued ownership from the next normal refresh's decoded summaries. |
| Duplicate creation activation / silent invalid names | Create activates once. Name editor shows empty/overlong-name validation and a failure message. |
| Callback reassignment | Use an explicit catalog-change reentrancy guard. |
| Undiscoverable experimental rail width | Expose legacy and experimental widths through one width query used by the view and settings caption. |
| Opaque clock-backwards date key | Explain Today grouping and the persisted creation-date preference key in the model. |
| Sort VoiceOver ambiguity | Separate current order (accessibility value) from the next action (hint and help). |
| Mutable defaulted UUID property | Explain memberwise initializer compatibility next to the declaration. |
| Hard-coded user-facing copy | Route new picker, association, disclosure, error and sorting copy through the localization bundle. |
| Missing `--shadows` usage option | Include it in every usage branch; icon script tests and shell syntax check cover the script. |
| Xcode 27 preview runner | Verified existing packaging job passed on this PR. GitHub's main branch protection endpoint returned “Branch not protected”; the repository's sole ruleset was disabled and contained no required status-check rule. No workflow change made. This is a point-in-time observation, not an availability promise. |
| Greptile missing-label notice | Add the available `greptile-review` label. This notice is not a code defect. |

The preview label is documented by [GitHub's runner-images announcement](https://github.com/actions/runner-images/issues/14404), which also calls out possible queueing issues. The successful [packaging run](https://github.com/onetimesecret/macos/actions/runs/36966679988/job/110711840501) predates these follow-up changes.

## Verification

On 2026-10-01 the final follow-up gate passed on the development host:

- 1,518 Swift tests: 296 executable-target and 1,222 shared-target tests.
- 771 Rust workspace tests with `test-util`; one existing ignored test.
- Workspace/all-target Clippy with `test-util` and warnings denied, Rust formatting,
  39 ADR structural checks, localization resource lint and shell syntax checking.
- Eight icon-script tests.

Independent read-only reviews covered identity/FFI separately from catalog/model/UI.
QA's disabled-Save-As ownership finding was fixed and covered before the final gate.
Regression coverage also exercises separate refused content/draft restores,
closed-file pruning, symlinked roots with missing leaves, renaming/removal and
selected-file restoration. Native VoiceOver, chooser, activation and signed-app
checks remain in [the manual runbook](pad-context-experiment.md).
