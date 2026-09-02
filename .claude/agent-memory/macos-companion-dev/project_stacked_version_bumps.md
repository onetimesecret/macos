---
name: stacked-version-bumps
description: Stacking two feature branches that each bumped the same crate leaves a silent version undercount; git reports no conflict, so fix it in a follow-up commit
metadata:
  type: project
---

When two feature branches off the same `origin/main` each bump a crate's
minor by one (say `companion-ffi` 0.17.0 to 0.18.0), merging one into the
other produces **no textual conflict**: both parents hold the identical
number derived from the identical ancestor, so git has nothing to resolve
and `git status` will not even list `crates/ffi/Cargo.toml` as modified.
The stacked branch then ships two minor features under one bump.

**Why:** this repo bumps crate versions as features land (pre 1.0 semver),
so the number is a count of features in the seam, not a release tag. A
merge that silently keeps 0.18.0 understates what the C header declares.
Observed concretely on 2026-09-01 stacking feature/98-account-auth and
feature/132-undo-manager, both of which had taken the seam to 0.18.0; the
stack had to reach 0.19.0.

**How to apply:** after any stack merge, diff each parent's
`crates/*/Cargo.toml` against the merge base rather than trusting the
conflict list. If both moved the same crate, bump again in a **follow up
commit** after the merge commit, run `cargo update -w`, and add a
CHANGELOG line under the unreleased `### Changed`. Crates that moved on
only one branch (there, `companion-core` and `companion-sync`) have
already counted themselves and must stay put.

`crates/ffi/include/companion_ffi.h` is still hand maintained, so it does
textually conflict when both sides add seams; that one merges by keeping
every declaration from both. See [[project_adr0018_gated_seams]] and
[[project_two_version_numbers]] (the shell plist version is separate and
does not follow the crate).
