# docs/spec/design/03-design-principles.md
---

# Design Principles

Six principles, each earning its place by settling real design arguments.
Every one traces back to the problem restatement (doc 01) or an overlooked
opportunity (doc 02). When two principles conflict, the earlier-numbered
one wins.

Still binding as of interaction-model revision C (doc 04), with two
narrow, argued amendments recorded at the end of this document rather
than silently edited into the principles: the ledger (amending §1) and
markdown headings (amending §3).

## 1. Comfortable being temporary

Expiry is the promise, not a limitation to soften. The app never
apologizes for deleting things, never adds a safety net that quietly
becomes an archive, never grows a "recently expired" bin beyond (at most)
a brief, capped undo window for misclicks.

*Settles:* "Should we warn before expiry?" — No notification by default; the
draining cue *is* the warning, and the user chose the TTL. "Should
expired items be recoverable?" — No; recoverable expiry is retention with
extra steps. "Trash can?" — No. *(Amended by rev C: see the ledger,
amendment A below — a bounded residue view, not recovery.)*

## 2. Present, not centre stage

The app is furniture. It occupies peripheral vision (menu bar + a small
summoned window), never steals focus, never interrupts, and is at its
best when the user forgets it exists between uses. Attention consumed per
transfer is the metric, minimized.

*Settles:* "Badge with sheet count?" — No. "Bounce/notify when a drop
succeeds?" — No; the chip appearing is the confirmation. "Should the
window take keyboard focus on drop?" — No; the user's work stays
frontmost. "Dock icon?" — No; menu bar only.

## 3. Content plays second fiddle

Sealed chips are handles for content in motion, not a display of the
content. A chip shows the minimum needed for recognition — a mechanical
excerpt, a count, the clipboard's own metadata — and the sheet shows the
time remaining. Visible ink is different only because the user chose to
keep it readable. No rich previews, no syntax highlighting, no image
zoom. Recognition, not consumption.

*Settles:* "Markdown rendering?" — No rich text, no rewriting. *(Amended
by rev C: heading lines are styled display-only with the markup kept
visible — see amendment B below.)* "Expandable preview?" — At most a
quick-look-style peek; never an editor. "Show full text on hover?" — No;
hover reveals actions, not content (shoulder-surfing surface).

## 4. Frugal

In resources: native code, memory-only store, tens of MB resident,
near-zero idle CPU (expiry is scheduled, never polled), no network in the
core loop, single-digit MB download. In attention: principle 2. In scope:
the anti-goals of doc 01 are load-bearing; features that add retention,
organization, or engagement are declined by default.

*Settles:* "Electron/Chromium bundle?" — No. "Auto-update daemon always
resident?" — No; check on launch. "Analytics to guide the roadmap?" — No
telemetry, period. "iCloud sync of sheets?" — No.

## 5. Trust through legibility

The user can always answer, at a glance and without a manual: what does it
hold, when does each item die, and does anything ever leave this machine
(only on explicit promotion, and the UI makes that boundary visible).
No hidden state, no background capture, no surprise persistence. The
codebase is open source so every one of these claims is auditable; the
security posture (doc 05) exists to make them true, not merely plausible.

*Settles:* "Capture clipboard automatically for convenience?" — Never;
deliberate placement is the privacy model. "Cache promoted-secret
metadata for a history view?" — No local record beyond the active sheet.
"Phone home for feature flags?" — No.

## 6. Escalate deliberately

Local first; remote by explicit choice. The promote-to-link CTA is
subtle — discoverable on every chip and page, prominent on none. Promotion is the
only network operation, it is unmistakably an action (never a side
effect), and it composes with the lifecycle: remaining local TTL seeds the
secret TTL, and a successful promotion offers to burn the local copy.

*Settles:* "Auto-create a link for large content?" — No. "Preemptively
upload so promotion is instant?" — Absolutely not. "Require an account at
install?" — No; the core loop works forever without one.

## Amendments (interaction-model revision C, 12 Jul 2026)

Two places where lived experience with the prototype overruled a
principle's absolutism. Both are recorded here deliberately — an amended
law argued in the open is stronger than a quietly rewritten one.

### A. The ledger (amends §1, "Comfortable being temporary")

§1 banned any "recently expired" bin. The ledger (doc 04) is the narrow
exception: a page that expires mid-thought takes typed context with it —
the errand list around the secret, not just the secret. The ledger keeps
the **dimmed ink of dead pages**, read-only, in memory, for the session
only, capped at the newest dozen. The boundary §1 exists to protect
holds: sealed bytes are zeroized at death without exception (a chip
appears struck through as "zeroized"), nothing touches disk, nothing can
be edited or resurrected, and quit is still total amnesia. Residue, not
retention; a record, not a trash can.

### B. Markdown headings (amends §3, "Content plays second fiddle")

§3 settled "Markdown rendering?" with "No". Rev C amends this to
**display-only, markup-preserving heading styling**: a line beginning
`### ` renders at heading weight with the `### ` kept visible and dimmed;
the bytes of the page never change; select-all-copy returns exactly what
was typed. The principle's substance — no rich previews, no in-place
reformatting, recognition over consumption — stands; a sheet the user
deliberately typed structure into is allowed to show that structure.
Inline emphasis stays out (doc 06).

## Tone

Follows from the principles: quiet, precise, slightly warm, never cute
about deletion and never guilt-tripping ("3 items expiring soon!" is
banned). Empty state is a single calm sentence, not an illustration
campaign. The app speaks when spoken to.
