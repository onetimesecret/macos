# Milestone 1 — The Problem Space

**Status:** Draft for discussion · **Milestone:** 1 of a series · **Date:** 2026-07

> This is a design document, not an implementation plan. Its job is to state the
> problem clearly enough that the right product falls out of it — and to name the
> opportunities that comparable applications leave on the table. It deliberately
> stops short of choosing a GUI framework, a persistence engine, or a colour
> value. Those are later milestones. Getting the problem wrong is the only
> mistake we cannot refactor our way out of.

---

## 1. What this document is for

The temptation with a "clipboard app" is to start listing features: history,
search, pinning, sync, snippets, rich previews. That path has been walked many
times and it always arrives at the same place — a growing archive that the user
must eventually curate, trust, and clean up.

We are going somewhere else. So before any of that, we restate the problem in
its own terms and ask what the existing tools, good as they are, were never
trying to do.

Everything downstream — the framework, the data model, the visual language —
should be traceable back to a claim in this document.

---

## 2. The problem, restated

### 2.1 The clipboard is a single register

The macOS pasteboard is, in computing terms, a **single volatile register**. It
holds one item. The instant you copy something else, the previous contents are
overwritten and unrecoverable. This is fine for the overwhelmingly common case —
copy, paste, done — and it is deliberately forgetful, which is a virtue.

It breaks the moment your working set is larger than one:

- You copy a password, then realise you also need the username — copying it
  destroys the password.
- You are assembling a message from three fragments scattered across two
  documents.
- You grab a one-time code from a Messages notification, switch apps, and it is
  gone before the form loads.
- You screenshot a diagram to send, then need to grab a second one first.

The content in these moments is **in transit**. It has left its origin and has
not yet reached its destination. It does not belong anywhere yet. It is not
worth *saving* — you will paste it in a minute and never think about it again —
but for that minute it is precious, and the single register cannot hold it.

### 2.2 The market's answer, and its cost

The established answer is the **clipboard-history manager**: Maccy, Paste,
Raycast's clipboard, Alfred, Pastebot, CopyClip, and friends. They solve the
"one register is not enough" problem by keeping **everything, effectively
forever**, in a searchable archive.

This trades one problem for a heavier one. A clipboard history is one of the
quietest privacy liabilities on a personal machine: a plaintext, long-lived,
often iCloud-synced log of every password, API token, recovery code, address,
and private message the user has ever copied. The feature that makes it useful —
never forgetting — is exactly what makes it a standing risk. The user is now
responsible for an archive they never chose to curate.

And it answers a question we are not asking. History optimises for **recall**:
*what did I copy last Tuesday?* Our user is not asking that. They are asking:
*where can I put these two or three things for the next few minutes without
losing them and without leaving a trail?*

### 2.3 The reframing: an L1/L2 cache for content in transit

The clarifying metaphor is the CPU memory hierarchy.

- The **pasteboard is the register file**: one (or a few) slots, volatile,
  overwritten constantly, zero persistence, the fastest thing there is.
- A durable store — a note, a file, a password vault, a shared link — is **main
  memory / disk**: the source of truth, addressable, kept on purpose.
- What sits *between* them, and what almost nobody builds, is the **cache**: a
  small, bounded, fast pool that holds the **working set** — the handful of
  things you are actively moving around right now — under an **eviction policy**
  so it clears itself without being asked.

That in-between layer is this product.

The cache metaphor is not decoration; it is a source of design law. Everything
true of a good cache is true of us:

| CPU cache property | What it means here |
|---|---|
| **Bounded capacity is a feature** | A small, fixed number of slots. You never scroll. Fullness forces a decision, which keeps the set small and legible. |
| **Automatic eviction (TTL)** | Entries expire on their own. The resting state is *empty*. No housekeeping. |
| **Temporal locality** | You reuse what you touched recently. Recent-on-top ordering matches how the working set actually behaves. |
| **Never the source of truth** | A cache line can vanish and nothing breaks — you re-copy from the origin, which still exists. This is *why* aggressive expiry is safe. |
| **Low latency above all** | Park and retrieve must be instant and frictionless, or people stay with the single register. |
| **Cheap to build, cheap to run** | Small footprint is intrinsic to the idea, not an optimisation bolted on later. |

The last two rows in that table are also the reason the app is **safe** to make
ephemeral: because a SleeperCell is *never* the only copy of anything important,
losing it costs nothing. That is the permission slip for forgetting.

---

## 3. What everyone else builds — and what they overlook

Four adjacent categories, and the specific gap each one leaves.

**Clipboard-history managers** (Maccy, Paste, Raycast, Alfred, Pastebot).
Optimised for recall and permanence. Growing, searchable, frequently synced.
They persist sensitive content by design. *Overlooked:* the user who wants to
*forget* on purpose, and for whom the archive is a liability rather than an
asset. We are the anti-archive.

**Drag-and-drop shelves** (Yoink, Dropover). The closest cousins *in spirit*: a
temporary shelf and a drag target that gets out of the way. But they are built
for **files** in a drag operation, they carry **no notion of expiry**, and they
have **no security framing**. *Overlooked:* time as a first-class dimension, and
the fact that the thing on the shelf is often sensitive. We borrow their "quiet
shelf" interaction and add a clock and a conscience.

**Password managers** (1Password, etc.). Durable, encrypted vaults — the
*opposite* end of the hierarchy. They are the source of truth you copy *from*.
*Overlooked (intentionally, by them):* the transit layer. Nobody wants a vault
entry for a value they will discard in ninety seconds. We are the scratch space
between the vault and the destination.

**Universal Clipboard / Handoff.** A single volatile slot shared across devices.
No dwell, no capacity, no control over lifetime. *Overlooked:* everything about
holding more than one thing, for a controlled duration, on purpose.

**The empty quadrant.** Put those on two axes — *permanence* (forgetful ↔
archival) and *content sensitivity as a design concern* (ignored ↔ central) —
and the corner that is **forgetful by default AND treats sensitivity as the
point** is empty. That corner is:

> A bounded, self-clearing, ambient buffer for sensitive content in transit,
> with a one-gesture bridge to secure one-time sharing.

No existing tool sits there. That is the opportunity.

---

## 4. Primary and secondary jobs

The order matters, and it is unusual, so it is stated plainly.

**Primary job — the local ephemeral buffer.** Park clipboard text or an image in
a SleeperCell; glance at how long it has left; retrieve it; watch it clear
itself. This is the whole reason to launch the app. **It requires no account, no
network, and no configuration.** It works on first run, offline, forever. This
inverts the usual "sign in to begin" funnel — the tool is useful before it asks
for anything.

**Secondary job — promote to a secure link.** Any cell offers a *subtle* call to
action: turn this content into a [Onetime Secret](https://onetimesecret.com)
link — a URL that self-destructs after a single view. This is where the local
scratch space and the network product reinforce each other: transient local
buffer → optional durable, shareable, one-time secret. This job needs
authentication (see §12) and is never in the user's way when they don't want it.

**Tertiary, later.** A fuller Onetime Secret client surface — recent receipts,
burn-before-read, status — may follow. It is explicitly *not* Milestone 1's
concern and must never crowd the primary job.

The discipline: **the secondary job may never degrade the primary one.** If
signing in, network state, or API errors ever make the local buffer feel heavier
or less trustworthy, we have failed at the thing that matters most.

---

## 5. Design principles (the ethos)

These are the tie-breakers. When two designs are otherwise reasonable, the one
that honours more of these wins.

1. **Ephemeral by default.** Expiry is the resting state; permanence is the
   exception that must be requested. Corollary — **forgetting is free; keeping
   costs a click.** Letting a cell die requires nothing. Extending its life is a
   deliberate act. Friction sits on permanence, never on forgetting.

2. **No baggage.** Nothing to name, tag, organise, foldering, or clean up. The
   app never asks the user to maintain it. If a feature creates something the
   user later has to tend, it is suspect.

3. **Content plays second fiddle.** The foreground is the *state* — time
   remaining, security, transit status. Content is **previewed, not edited**.
   You come here to *park* and *retrieve*, not to read or author. This restraint
   is the core discipline, and it is what keeps the app small.

4. **Present, not central.** An ambient surface, closer to a dock or a
   notification shelf than to an application window. There when you glance, gone
   when you don't. **It must never steal keyboard focus** when it appears — an
   ambient tool that grabs the cursor is a broken ambient tool (this is an
   accessibility rule as much as an etiquette one).

5. **Frugal, on every axis.** Small in memory and disk (it is a menu-bar
   resident — idle footprint is the number that matters), small in CPU and
   battery (a visible countdown must not wake the GPU every frame), small in
   pixels (generous whitespace, one accent, truncated previews), and small in
   cognition (sensible defaults, nothing to configure to get value). Native Rust
   is chosen in service of this, not for its own sake.

6. **Accessible from the first commit.** Not a later pass. See §10.

7. **Local-first and private.** Sensitive transit content does not silently
   touch disk or the network. Persistence, if offered at all, is encrypted and
   opt-in. Sharing is always an explicit, visible act.

8. **Comfortable being temporary.** The app itself carries this attitude. It
   does not try to become sticky, indispensable, or the centre of a workflow. It
   is happy to be closed, happy to be empty, happy to be forgotten between uses.

---

## 6. Anatomy of the experience

A concrete sketch, so the words above have a shape. Details (exact metrics,
colours, the framework that draws it) belong to later milestones; this conveys
*intent*.

### 6.1 The two surfaces

- **Menu-bar item.** The app's resident presence. A glanceable indicator; a
  click reveals the panel. This is home base — the app is *always* here and
  *only* here until summoned.
- **Edge-docked panel.** A slim vertical strip that slides in against a chosen
  side of the screen. A drop target at the top, a stack of SleeperCells below,
  most recent on top. It is a *surface*, not a window: no title bar theatre, no
  focus theft, dismissed as easily as it appeared.

```
  ┌───────────────────────────┐
  │  ⌁  drop or paste here     │   ← drag target / paste zone
  ├───────────────────────────┤
  │ ▉▉▉▉▉▉▉▉·····   ⧗ 8h   ↗ │   ← SleeperCell: countdown · TTL label · share
  │ "sk-live_4f9c… (text)"    │      preview only — never the full value
  ├───────────────────────────┤
  │ ▉▉▉▉·········   ⧗ 3h   ↗ │
  │ [▧ image · 1440×900]      │
  ├───────────────────────────┤
  │ ▉·············   ⧗ 1h   ↗ │
  │ "https://example.com/…"   │
  └───────────────────────────┘
   present, not central — it never grabs focus
```

### 6.2 The SleeperCell

The atomic unit. Named for what it does: it lies **dormant**, holds one thing
for a **bounded lifetime**, and then **clears itself** — no instruction, no
residue. A cell carries exactly four things, in priority order:

1. **A time-remaining cue.** A glanceable visual countdown (a draining
   ring/bar). This is the most prominent element on the cell — *state over
   content*.
2. **An interactive natural-time label.** `7d · 3d · 24h · 8h · 3h · 1h`.
   Reads the remaining life in human units; **click to cycle** the ladder and
   reset/extend the TTL. Time is not a buried setting — it is right there, on
   every cell, one click from adjustment.
3. **A content preview.** A truncated line of text or an image thumbnail with
   dimensions. Enough to recognise, never enough to be a viewer or an editor.
   Sensitive-looking values are visually de-emphasised by default.
4. **A subtle share CTA.** The one-gesture bridge to a Onetime Secret link
   (§4, §12). Present, quiet, never competing with the content or the clock.

Implicit, keyboard-first actions round it out: **retrieve** (copy back to the
pasteboard), **dismiss** (evict now), and focus/navigation — all without a
mouse (§10).

### 6.3 Two clocks, kept distinct

There are two different lifetimes and conflating them would confuse users:

- **The cell's local TTL** — how long the content lingers in the *local buffer*
  before eviction. This is the `7d…1h` ladder above. It governs local
  forgetting and touches no server.
- **A shared secret's server-side lifespan** — if a cell is promoted to a
  Onetime Secret link, *that link* has its own independent TTL enforced by the
  API and the account's plan. Cycling the cell's local label does **not** change
  a link that has already been minted.

The spec and the UI must keep these visually and conceptually separate.

---

## 7. Time as the primary interface

Most tools bury expiry in a preferences pane. Here it is the main event, and the
principle from §5.1 gives it teeth:

> **Forgetting is free; keeping costs a click.**

- **The default rests short.** The resting TTL should sit in *hours*, not days,
  so the honest, common case — a value you will paste in a minute — evaporates
  on its own without anyone touching it. (The exact default is an open question,
  §13; the *direction* is settled: short.)
- **Extending is deliberate.** The rare item you need for the afternoon or the
  week is promoted *up* the ladder by clicking — one gesture per step. Longevity
  is always a choice the user makes on purpose.
- **You feel content age.** The draining cue makes time visceral. A cell that is
  nearly gone *looks* nearly gone. This is the opposite of an archive, where
  everything looks equally permanent and nothing feels urgent.

The ladder the user proposed — `7d · 3d · 24h · 8h · 3h · 1h` — spans "genuinely
transient" to "short-lived working set." Whether 7 days belongs in something that
calls itself a cache is a fair question (§13); the ladder's *shape* — discrete,
human, cyclable — is right.

---

## 8. Accessibility as a first-order constraint

Accessibility is a design input here, not a compliance pass — and in one place
it is even a **framework-selection** constraint (§13), because native macOS
accessibility support varies widely across Rust GUI toolkits.

- **The countdown must never depend on colour or motion alone.** The natural-time
  label (`8h`, `3h`, `1h`) is the text-equivalent of the visual cue, always
  present. VoiceOver announces remaining life in words ("about 3 hours
  remaining"). This is why the label is core furniture, not an add-on.
- **Full keyboard operability.** Focus a cell, cycle its TTL, retrieve it, share
  it, dismiss it — all from the keyboard. This is a paste tool; the keyboard is
  the native input, so keyboard-first is also just *correct*.
- **Never steal focus.** The ambient panel must not grab the keyboard when it
  appears (§5.4). For assistive-technology users, unexpected focus changes are
  disorienting and destructive; for everyone they are rude. Same rule, two
  reasons.
- **Honour the system accessibility settings.** *Reduce Motion* (no perpetual
  pulsing countdown — degrade to a static, readable state), *Increase Contrast*
  and *Reduce Transparency* (the frosted-glass aesthetic must degrade to solid,
  legible surfaces), and *Dynamic Type* (the panel and cells reflow at larger
  text sizes rather than clipping).
- **Speak state changes, sparingly.** A cell expiring is a live event; assistive
  tech should be able to surface it without the app becoming a chatterbox. The
  right granularity is an open design question, but the requirement — legible,
  non-spammy live semantics — is not.

---

## 9. Frugality as a first-order constraint

"Frugal design" is measurable, and we will hold ourselves to it.

- **Idle footprint is the headline number.** This app is resident all day. Its
  memory and CPU while doing nothing matter more than its performance while
  busy. A native Rust binary with no bundled browser runtime is the means; a
  low idle footprint is the end.
- **The countdown must not be a battery leak.** A visible timer is the classic
  way a menu-bar app quietly drains a laptop. Ticking is coalesced and lazy —
  redraw on state change or at a coarse cadence, not every frame; do less (or
  nothing) when the panel is hidden or the machine is on battery.
- **Visual frugality.** Minimal chrome, generous whitespace, a single accent
  colour (the brand flame, used sparingly, per the existing design system),
  previews rather than full renders.
- **Cognitive frugality.** Valuable with zero configuration. Defaults are
  opinionated and good. There is nothing to set up, and therefore nothing to
  get wrong.
- **Bounded by construction.** Fixed slot count and image memory ceilings are
  chosen up front, so the app cannot grow unbounded no matter how it is used.

---

## 10. Security and privacy posture

This is a security company's tool for handling sensitive content. The posture is
part of the product, not an afterthought.

- **Ephemerality is a security control.** The reason a plaintext value is safe to
  hold is that it does not persist and does not linger. Expiry is not just UX; it
  shrinks the window in which sensitive data exists at all.
- **No silent persistence.** The safe default is memory-only, cleared on quit.
  If persistence across restarts is offered, it is **opt-in and encrypted at
  rest** (Keychain-backed keys), never plaintext on disk, never a surprise.
- **No silent sync.** Nothing leaves the machine unless the user explicitly
  promotes a cell to a shared link. There is no background cloud, no telemetry
  of content.
- **Capture is a decision, not a default.** *Watching* the system clipboard
  automatically would re-introduce the exact "capture everything sensitive"
  problem we are defining ourselves against. The default is explicit — paste or
  drag *into* the app. Any automatic capture is opt-in, off by default, and
  clearly indicated when on.
- **Previews respect sensitivity.** Values that look like secrets are truncated
  and de-emphasised so the panel is not a shoulder-surfing hazard sitting open
  on a screen edge.

---

## 11. Anti-goals — what this is *not*

Naming these protects the ethos from feature drift.

- **Not a clipboard history or archive.** No infinite scrollback, no
  "everything you ever copied." Forgetting is the point.
- **Not a notes app or scratchpad that accrues.** Cells are not documents; they
  are not meant to be kept, titled, or revisited days later.
- **Not a password manager.** No durable vault, no source-of-truth storage of
  credentials. We are the transit layer, not the destination.
- **Not a sync service.** No cross-device replication of the local buffer.
  (Sharing a *single* secret via a link is a different, explicit act.)
- **Not a full Onetime Secret client — yet.** Link creation is a bridge, not the
  centre of gravity. A richer client surface is a later, subordinate milestone.
- **Not sticky.** It does not try to maximise engagement, retention, or
  time-in-app. Success looks like the user reaching for it exactly when useful
  and forgetting it exists the rest of the time.

---

## 12. Integration with Onetime Secret

Grounded in the actual v3 API in the `onetimesecret` repository, so later
milestones start from fact.

**Creating a secret.** A cell is promoted by calling
`POST /api/v3/secret/conceal`. The v3 payload nests the content under a `secret`
key, for example:

```jsonc
POST /api/v3/secret/conceal
{
  "secret": {
    "kind": "conceal",
    "secret": "<the cell's text>",
    "ttl": 3600,                     // server-side lifespan, in seconds
    "share_domain": "<share domain>",
    "passphrase": "<optional>",
    "recipient": "<optional>"
  }
}
```

The response returns the share link (for the recipient) and a receipt (for the
creator); the secret can be revealed exactly once before it is destroyed. Note
the `ttl` here is the **link's** server-side lifespan (§6.3) — a different clock
from the cell's local TTL.

**Authentication — the staged path.**

- **Now: HTTP Basic auth.** The API's `basicauth` strategy authenticates with
  the customer's **external id (`extid`)** as the username and an **API token**
  as the password; the server loads the associated **organization** context from
  those credentials. This is what the desktop app will use first, because it
  exists today. Credentials live in the macOS Keychain, never in plaintext
  config.
- **Later: PASETO.** The intended modern auth path is PASETO-based tokens. It is
  not built yet on the API side, so it is a forward-looking target, not a
  Milestone 1 dependency. The client's auth layer should be designed so that
  swapping Basic for PASETO is a contained change.

**A known gap to resolve.** The `conceal` endpoint takes a **text** `secret`. An
**image** cell therefore has no direct mapping to a one-time link today — it
would need encoding, or link-creation may be offered for text cells first and
images later. Flagged here so it is a conscious decision, not a surprise (§13).

---

## 13. Open questions (deferred to later milestones)

Named, not answered. Each is a real fork, and pretending otherwise now would be
the wrong kind of confidence.

1. **Rust GUI framework.** The candidates (e.g. GPUI, Iced, Slint, Dioxus, and
   the webview-based Tauri) trade off very differently on **native macOS
   accessibility maturity**, menu-bar / edge-dock support, binary size, and
   rendering cost. Accessibility maturity is likely the *deciding* constraint,
   given §8 — this is a Milestone 2 evaluation with a11y as a gate, not a
   nice-to-have.
2. **Persistence model.** Pure in-memory (zero disk, cleared on quit) versus
   opt-in encrypted-at-rest with Keychain-managed keys. Security default leans
   in-memory; the question is whether persistence is offered at all.
3. **Default TTL and the ladder.** Direction is settled (short — hours, not
   days, §7). The exact default, and whether `7d` belongs on something called a
   cache, are open.
4. **Global capacity and eviction when full.** How many slots, and what happens
   at capacity — evict oldest, evict nearest-expiry, or require a manual
   decision (which pressures the set to stay small, per §2.3).
5. **Image handling.** Memory ceilings for image cells, thumbnailing strategy,
   and their path (if any) to link-creation given the text-only `conceal`
   endpoint (§12).
6. **Clipboard capture model.** Confirm explicit paste/drag as the default;
   decide whether an opt-in clipboard *watch* mode exists at all, and how it is
   made obvious when active (§10).
7. **Multi-monitor and edge-dock behaviour.** Which edge, which display, how it
   behaves across a display configuration change.
8. **Product name.** `OTS Cache` is a placeholder. The cache metaphor and the
   `SleeperCell` unit are load-bearing; the app's public name is not yet chosen.

---

## 14. Roadmap

Milestone 1 is the foundation the rest stands on.

| # | Milestone | Focus |
|---|---|---|
| **1** | **Problem space** *(this document)* | Restate the problem; find the overlooked opportunity; fix the ethos and anti-goals. |
| 2 | Framework & architecture | Evaluate Rust GUI frameworks with **accessibility as a gate**; choose persistence and data model; project skeleton. |
| 3 | Interaction & visual design | The panel, the SleeperCell, the countdown, and the TTL ladder, drawn against the existing brand system. |
| 4 | The local buffer (primary job) | Menu bar, edge-dock, drag/paste, SleeperCells, TTL, eviction — the whole no-account core. |
| 5 | The share bridge (secondary job) | v3 `conceal` integration, Keychain-backed Basic auth, the subtle CTA; PASETO-ready seam. |
| 6 | Hardening | Accessibility audit, energy/footprint budget verification, security review, packaging and signing. |

---

## 15. Glossary

- **SleeperCell** — the atomic unit of the buffer: one piece of content that lies
  dormant, holds for a bounded lifetime, and clears itself on expiry. Carries a
  time cue, a cyclable TTL label, a preview, and a share CTA.
- **The pasteboard / register** — the macOS system clipboard; a single volatile
  slot. The thing we sit *above*.
- **Working set** — the small handful of items a user is actively moving between
  contexts right now. What the cache is sized to hold.
- **TTL (time-to-live)** — an item's remaining local lifetime before eviction.
  Distinct from a shared link's server-side lifespan.
- **The ladder** — the discrete, cyclable set of natural-time values
  (`7d · 3d · 24h · 8h · 3h · 1h`) a cell's label steps through.
- **Eviction** — automatic removal of a cell when its TTL expires (or, possibly,
  when the buffer is at capacity).
- **Promote / the share bridge** — turning a cell's content into a Onetime Secret
  one-time link via the v3 API.
- **Register / cache / main memory** — the CPU-hierarchy metaphor: pasteboard =
  register, this app = cache, durable stores and shared links = main memory.

---

*Milestone 1 is deliberately words, not code. If the problem is framed right,
the product it implies is nearly obvious — and stays small.*
