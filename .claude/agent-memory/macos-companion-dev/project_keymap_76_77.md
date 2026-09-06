---
name: keymap-76-77
description: Issues #76/#77 keymap decisions (2026-08-24) — contexts declared but unconsulted, cmd-opt-n retired, override lives outside the .noindex dir
metadata:
  type: project
---

The keyboard is data now: a bundled Zed-format JSON5 keymap
(`shell/Sources/CompanionKit/Resources/default-keymap.json`) is the
authoritative list of chords. Landed on `feature/76-keymap`, with
`feature/77-cmd-n` stacked on it, both pushed green 2026-08-24.

**Why:** dogfood aberrations triage of 2026-08-19 asked for a
project-owned keymap so bindings change by editing data; #77 was its
first consumer.

**How to apply:**

- Four decisions that are not derivable from reading the code, because
  they are about what was deliberately left out:
  - `TabStrip` and `Ledger` are legal contexts that **no surface
    consults**. A binding placed there validates, reports
    `contextNotConsulted`, and does nothing. Wiring one up means
    flipping `KeymapContext.isConsulted` in the same change that
    teaches a surface to ask.
  - **⌥⌘N was retired, not aliased** (issue #77). Rationale recorded in
    the changelog: one command with two default chords turns the file
    into a pile of accommodations. If the user asks for it back, the
    answer is their own override file, not a second default.
    Dogfood phase 4 (2026-09-05) drew the line more finely: `cmd-t`
    joined `cmd-n` on `page::New` as a bundled default. The test is
    who the second chord is for. A chord for hands trained by this
    app's own past is an accommodation and stays an override; a chord
    the rest of the platform already taught (cmd-t on a new tab) is a
    default. Two chords on one command are two lines in the validator's
    table; the tooltip and menu name the first in canonical order, and
    "moving" New in an override now means nulling both.
  - The user override is
    `Application Support/<bundle id>/keymap.json`, deliberately **beside
    and not inside** the `.noindex` state directory: no Spotlight and no
    backup are right for ciphertext and wrong for a file the user wrote.
  - Function keys and `fn` are refused at the parser because SwiftUI
    cannot install them. Do not "add support" without a route that
    actually fires.
- `PageModel.Seams.keymapOverride` reads inverted from its neighbours:
  under injected seams, nil means *no override*, never the shipping
  path. That is what keeps a suite off the tester's own keymap. See
  [[tests-with-default-seams-hit-installed-state]].
- Shell-only work does not bump `crates/ffi/Cargo.toml`. The version
  prices the core and the seam, and neither moved here; check
  [[bump-version-with-features]] before assuming a bump is owed.
