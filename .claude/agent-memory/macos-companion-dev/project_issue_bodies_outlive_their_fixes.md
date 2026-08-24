---
name: project-issue-bodies-outlive-their-fixes
description: Open issues #22 and #23 quoted PR-review findings that had already been fixed on main; verify every finding against current code before implementing
metadata:
  type: project
---

Issue bodies in this repo can describe code that no longer exists. Issues
#22 and #23 (both quoting the max-effort review of focus-law PR #21) were
still open on 2026-08-24, but five of their six findings had been fixed
months earlier and never closed the issue: #22 by PR #27 (2026-07-15,
commits d6e7fe0 and e615723), #23's undo/IME/catcher findings by b128226
(2026-07-15) and bf38b48 (2026-08-22). The file paths quoted in those
bodies (`shell/Sources/CompanionApp/...`) predate the module rename too.

**Why:** the team fixes fast and closes issues slowly, and several fixes
landed in other worktrees. Implementing from the issue body alone would
mean re-fixing fixed code or, worse, undoing a better later fix (the
"align on DispatchQueue.main.async" finding was superseded by a bounded
poll that is strictly more robust; taking the finding literally would
have removed the poll).

**How to apply:** for each finding, `git log --all -S '<a distinctive
string from the fix>'` across all paths before touching anything, then
construct the failure scenario against today's code. What survives is
usually the finding's *invariant* rather than its site: #22's "a new page
must mount focused" was stale at `newPage()` but live on the ADR-0017
mint paths (`select`/`step` into an empty slot), which did not exist when
the review was written. Report stale findings explicitly rather than
silently skipping them.

Related: [[claims-that-outran-the-code]], [[adr-citations-drift-on-every-edit]].
