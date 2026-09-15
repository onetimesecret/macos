# docs/spec/design/03-design-principles.md
---

# Design Principles

Six principles, each earning its place by settling real design arguments.
Every one traces back to the problem restatement (doc 01) or an overlooked
opportunity (doc 02). When two principles conflict, the earlier-numbered
one wins.

Still binding as of interaction-model revision C (doc 04), with four
narrow, argued amendments recorded at the end of this document rather
than silently edited into the principles: the ledger (amending §1),
markdown headings, fenced code color, and visible-page preview rendering
(the latter three amending §3).

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
by B, C, and D below: heading structure and fenced-code color are
markup-preserving display; the visible-page scope is selected by the
preview-rendering preference.)* "Expandable preview?" — At
most a quick-look-style peek; never an editor. "Show full text on
hover?" — No; hover reveals actions, not content (shoulder-surfing
surface).

## 4. Frugal

In resources: native code, memory-only store, tens of MB resident,
near-zero idle CPU (expiry is scheduled, never polled), no network in the
core loop, single-digit MB download. In attention: principle 2. In scope:
the anti-goals of doc 01 are load-bearing; features that add retention,
organization, or engagement are declined by default.

*Settles:* "Electron/Chromium bundle?" — No. "Auto-update daemon always
resident?" — No; check on launch. "Analytics to guide the roadmap?" — No
telemetry, period. "iCloud sync of sheets?" No: Apple's containers are
not somewhere this content goes. Whether a first-party relay may carry a
page between a user's own enrolled devices is a separate question,
decided in ADR-0021 (issue #93).

## 5. Trust through legibility

The user can always answer, at a glance and without a manual: what does it
hold, when does each item die, and does anything ever leave this machine
(only on an explicit conceal, or to a device the user enrolled, and the
UI makes that boundary visible).
No hidden state, no background capture, no surprise persistence. The
codebase is open source so every one of these claims is auditable; the
security posture (doc 05) exists to make them true, not merely plausible.

*Settles:* "Capture clipboard automatically for convenience?" — Never;
deliberate placement is the privacy model. "Cache concealed-secret
metadata for a history view?" — No local record beyond the active sheet.
"Phone home for feature flags?" — No.

## 6. Escalate deliberately

Local first; remote by explicit choice. The conceal-to-link CTA is
subtle: discoverable on every chip and page, prominent on none. Every
destination is one the user enrolled and can see. Concealing to a link is
an explicit action. Replication between a user's own enrolled devices is
opt-in per page, visibly live while it is live, and carries only what that
page's TTL still permits. What this forbids is not automatic traffic, it
is *unaccounted* traffic: no destination the user did not enroll, no
payload the app would not show them, no retention on a relay beyond the
page's own expiry. It composes with the lifecycle: remaining local TTL
seeds the secret TTL, and a successful conceal offers to burn the local
copy.

*Settles:* "Auto-create a link for large content?" — No. "Preemptively
upload so concealing is instant?" Absolutely not. "Require an account at
install?" — No; the core loop works forever without one.

## Amendments (interaction-model revision C, 12 Jul 2026)

Four places where lived experience with the prototype overruled a
principle's absolutism. All are recorded here deliberately, because an
amended law argued in the open is stronger than a quietly rewritten one.
A and B arrived with revision C; the third followed in August 2026, once
dogfooding put real code on the page; the fourth followed when the time
roll made several readable pages visible together.

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

### C. Fenced code color (amends §3, "Content plays second fiddle")

§3 also settled "no syntax highlighting" with a flat no. ADR-0024 amends
this for one surface only: **syntax coloring inside fenced code blocks on
the editable page**, as display-only styling under amendment B's
contract. Color is the only attribute that changes; the font, the
metrics and the fence's wash are untouched, the bytes of the page never
change, and select-all-copy returns exactly what was typed. §3 keeps its
force where it was aimed: chips, the ledger and the roll's quiet
renderings stay uncolored, and nothing outside a fence region is colored
at all. The resting glance is not one of those surfaces. It mounts the
editable page itself, read only (ADR-0006), and has carried heading
weight and link color since amendment B; a page at rest is already
legible in full, so color there shows nothing the glance did not. ADR-0013's editable-surface rule is the
license, stated there plainly: a text file with syntax highlighting is
still a text file. A page the user deliberately fenced code into is
allowed to show that it is code. The language comes only from the fence's
own info string; an unknown or absent language renders exactly as it does
today.

### D. Visible-page preview rendering (amends §3 and amendment C)

ADR-0030 reopens amendment C's surface boundary for the time roll. A quiet
region shows a readable page, not an excerpt or concealed-content handle,
so its display no longer changes merely because the editor moves away.
The Preview rendering preference chooses the reach: **All pages**, the
default, gives the mounted page and visible quiet pages the same
markup-preserving Markdown structure, fence wash and token color;
**Focused page only** keeps quiet pages flat; **Never** makes every page
plain ink. The existing Syntax highlighting setting remains the narrower
color-only control.

This does not turn quiet pages into editors or previews that consume the
content. They remain noninteractive until clicked, chips remain non-secret
faces, the ledger stays dim and uncolored, and the minimap stays geometric.
Block created/modified labels remain with the mounted editor and quiet
renderings reserve no space for them. A manually accepted or inferred
language follows its page as display-only session state under **All pages**;
it never rewrites a bare fence. The byte-preservation contract of B and C
stands.

## Tone

Follows from the principles: quiet, precise, slightly warm, never cute
about deletion and never guilt-tripping ("3 items expiring soon!" is
banned). Empty state is a single calm sentence, not an illustration
campaign. The app speaks when spoken to.
