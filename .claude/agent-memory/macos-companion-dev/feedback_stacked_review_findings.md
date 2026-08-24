---
name: stacked-review-findings
description: Verify each adversarial-review finding against the branch that owns the code before fixing it; on a stacked chain, findings get assigned to the wrong branch
metadata:
  type: feedback
---

When a reviewer hands over findings for a stacked branch chain, check
each claim on the branch it is filed against before acting on it. A
claim can be false on that branch and true two branches up.

**Why:** on the #75/#76/#77/#78 chain (2026-08-24) a finding filed
against `feature/77-cmd-n` said a doc line carried a stale ⌘0. It did
not: `cmd-0` was still bound in the default keymap on 77 and only went
away on `feature/78-hide-ui`. Fixing it where it was filed would have
made the doc wrong for that branch and for anyone reviewing 77 alone.
A second finding overstated its consequence: Escape survives an empty
keymap inside a page because `NSTextView.cancelOperation` is AppKit's
own route, not the map's, so only Escape on the surface chrome is lost.

**How to apply:** before each fix, `git checkout` the owning branch and
grep the actual artefact (the keymap JSON, the source line) rather than
trusting the finding's file:line, which was probably read at the tip.
Report refutations with the trace rather than silently doing the fix
somewhere else. See [[adversarial-review-for-agent-written-security-code]]
for the companion rule about verifying the top findings yourself.
