---
name: conceal-vocabulary
description: "Promotion" is banned vocabulary; the exit ramp is conceal (with reveal as corollary), and the "only network action" claim is retired
metadata:
  type: feedback
---

Never write "promote"/"promotion" for turning staged content into a
one-time link. The word is **conceal**, with **reveal** as its
corollary. Applies to identifiers, wire keys, UI strings and prose.

**Why:** "promotion" was invented by an agent and drifted through the
whole tree above `crates/ots-client`, which had always named the real
API route `POST /api/v3/secret/conceal`. Issue #92 renamed it out of the
code (2026-08-24), including two exported C symbols
(`companion_chip_conceal`, `companion_sheet_conceal`) and the chip face's
JSON key (`promoted` becomes `concealed`).

**How to apply:**

- Two meanings of "concealed" exist. The OTS action is the unqualified
  one. The nspasteboard.org clipboard-manager marker keeps its Apple and
  community names (`CONCEALED_TYPE`, `org.nspasteboard.ConcealedType`)
  but every struct field carrying it is `nspasteboard_concealed`. Do not
  reintroduce a bare `concealed: bool` in `crates/pasteboard`.
- The claim that conceal is "the app's only network action" is retired
  (issue #92, multi device sync). Say "an explicit user action". The
  separate "one outbound destination" claims in `crates/transport`,
  `crates/ots-client` and Settings were left standing: they describe the
  TLS network boundary, not the frequency of network calls.
- `PageModel` holds `concealDraft`, not `conceal`, so the noun does not
  read as a verb next to `beginConceal`/`confirmConceal`.

Related: [[verifiably-forgets-is-retired]], [[no-price-metaphor]].
