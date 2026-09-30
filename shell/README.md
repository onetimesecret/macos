# shell/ — the Swift/AppKit shell

One executable target over the one core: `Sources/OnetimePad`
is OnetimePad, the background surface
(docs/spec/feature/background-surface). `Sources/CompanionKit` holds
everything above the window: the page model, the views, and the seam
wrapper. The menu-bar panel that carried the project through v0.1
(`CompanionApp`) was archived once the surface reached parity
(ADR-0014); its sources live in git history, and ADR-0010's sibling
mechanism remains the path for any future form factor.

The shell itself is the one selected by ADR-0002 (accepted
2026-07-13): Swift/AppKit over the Rust core, driven end-to-end
through the C-ABI seam (`crates/ffi`, mechanism: ADR-0003).

## Build (macOS only)

```sh
./scripts/build-core.sh   # cargo → universal libcompanion_ffi.a → bindings/CompanionCore.xcframework
cd shell
swift build && swift test
swift run OnetimePad
```

`swift run` is the edit-compile loop, but the bare binary has no
`CFBundleIdentifier`, so macOS can't address it: TCC grants don't
stick, and per-app screen-capture pickers can't list it. When the app
needs to be a citizen of the permission system, use the entry points:

```sh
../scripts/dev.sh       # debug bundle as dev.onetimesecret.pad, launched from dist/
../scripts/install.sh   # release bundle, signed, installed to /Applications
```

The bundle id is `com.onetimesecret.pad`; the version
users see is `CFBundleShortVersionString` in `OnetimePad-Info.plist`,
which is the product's own number, edited there by hand when work a
user can touch lands. The packaging script reads it and stamps
`CFBundleVersion` from it plus the short commit. About leads with that
app/build pair and labels the independently versioned Rust artifacts as
`FFI` and `Core`. The menu-bar menu omits those technical versions by
default; General → Show versions in menu adds the build, FFI, and core
versions for diagnostics. `companion_ffi_version()` and
`companion_core_version()` report the two Rust versions. Ad-hoc
signing changes the code identity on every rebuild, so
TCC grants reset and the Keychain re-confirms access to stored items
(the API token, the state key). Configure the matching `DEV_*` or
`LOCAL_*` identity in `scripts/local.env` for an identity that persists;
App Store signing uses its separate `APP_STORE_*` values.

The rev C surfaces make dev scaffolding unnecessary: type a line and
⌘↩ seals it. The old dev-seed shim is gone from the packaged core, so
no shipped library exports an entry point that carries plaintext into
the seam.

## Honest status

- **These are the rev C surfaces** (issue #12, docs/spec/04), shared
  through CompanionKit: one page of ink and sealed chips in an
  `NSTextView`-backed editor; bottom-edge tabs with a gauge under each
  title (the full width gauge along the page's bottom edge read as a
  scroll bar and came out in dogfood phase 4, the per tab gauge stays,
  docs/dogfood/ABERRATIONS.md), pause on double-click,
  drag-to-reorder, ✕ to close; the keyboard map
  (⌃⌥Space, ⌘1 to 9, ⌘N or ⌘T, ⌥⌘←/→, ⇧⌘V, ⌘↩, Esc). Which chord does what is
  the keymap file's business and not this file's, so read
  `docs/development/keymap-format-and-dispatch.md` for the list that is actually
  installed. Markdown headings render styled with their markup kept
  visible; the bytes of the page never change.
- The ledger still records every event and is still readable by an
  override keymap, but its dashed ◌ tab, its ⌘0 and its Settings entry
  are hidden (issue #78) while the audit story is settled. Nothing was
  deleted, so nothing has to be rebuilt to bring it back.
- Every gesture route is boundary-lawful: sealed paste reads
  `NSPasteboard.general` core-side; **drop-to-seal reads the drag
  pasteboard core-side** (`companion_sheet_seal_from_drag`) — no
  dropped byte transits Swift; copy-out writes the board core-side. The
  editor mirrors its document over `sync_document`, which is
  authoritative for chip liveness (⌫ on a chip zeroizes in the core).
- The focus law holds: the window accepts the keyboard by deliberate
  act only (click into the page, or ⌥Space), shows an ember border
  while it holds keys, and Esc hands them back. Opening it never
  deactivates the frontmost app.
- Expiry is scheduled (one timer at the core's next event — page expiry
  or pause-hold lapse), and the 1 Hz countdown redraw runs only while
  the window is visible — keep it that way; the frugality budget
  (< 25 MB idle, near-zero idle CPU) is a review bar, not a wish. 22 MB
  at 0 cells is the baseline to regress against.
- VoiceOver operability awaits the hardware runbook
  (docs/qa/hardware-verification.md §B); its failure modes are ADR-0002
  eject triggers. The conceal path (↗ link / ↗ page) and the Settings window
  are the remaining slices.

## The boundary law (hard form, rev C)

Sealed bytes never reach this package — they have no display form at
all. This package sees ids, titles, mechanical excerpts, and booleans;
the sealed paste *and* copy-out happen inside the core. The one
plaintext-in call is `sealText` (⌘↩): its argument is visible ink the
editor already holds, and after the call the editor deletes its copy.
If a change here needs sealed bytes, the change is wrong.
