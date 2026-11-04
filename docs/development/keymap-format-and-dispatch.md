---
# docs/development/keymap-format-and-dispatch.md
---

> Shortcut scope, 2026-10-03: [ADR-0039](../adr/0039-pad-selection-and-associations.md) supersedes the
> numbered page/slot/day shortcut assignments below when multiple pads are
> enabled. Scratch uses ⌘0; the first nine other pads use ⌘1–⌘9. The
> existing single-pad map remains when pads are disabled. Page neighbour
> navigation uses ⌥⌘←/→; direct page-selection commands remain configurable
> through the keymap. Historical ledger ⌘0 checks require an explicit
> nonconflicting binding in the multi-pad context. This notice records the
> decision and does not assert that the native checks have passed.


# Keymap format and command dispatch

The keyboard map is a file, not code (issue #76). What each chord does
is decided by `shell/Sources/CompanionKit/Resources/default-keymap.json`,
which the app reads at launch, validates, and installs. Moving a
binding is an edit to that file.

## The format

Zed's keymap format, read with two JSON5 tolerances: comments and
trailing commas. Nothing else from JSON5 is implemented. The file is an
array of sections:

```json5
[
  { "schema_version": 1 },
  {
    "context": "Editor",
    "use_key_equivalents": true,
    "bindings": {
      "cmd-n": "page::New",
      "cmd-shift-v": "clipboard::Seal",
    },
  },
]
```

- **`schema_version`** is optional and belongs to the first entry. A
  file that says nothing is read as version 1. A version this build
  does not know gets the file refused whole, which is what the field is
  for. It has to be a whole number: `"1"` and `true` are refused as text
  and as a boolean rather than coerced into a version.
- **`context`** is the surface: `Editor`, `TabStrip` or `Ledger`. Only
  `Editor` is consulted today; a binding in either of the others is
  read, reported as inert, and does nothing until some surface starts
  asking. A section with no context applies to all three, as it does in
  Zed. Context matching is a plain identifier, deliberately: no `&&`,
  no `!`, until something real needs one.
- **`use_key_equivalents`** lets a chord in that section be advertised
  as a macOS menu key equivalent. The menu items that show a chord
  take it this way: Settings (`app::Settings`), the File menu's items,
  Undo, Redo and the seal item in Edit, the Window menu's Close Window
  (`window::Close`) and the Help menu's product help item (`app::Help`, issue
  #294). A menu equivalent is an app-wide claim, live even while a
  Settings field holds the keyboard, so it has to be asked for. Once
  granted, it stays with that chord and command: a later section that
  restates the same line without asking for equivalents leaves the
  equivalent standing, because a file repeating a default line to keep
  it in sight must not quietly take something away. To withdraw one,
  set the chord to `null` and bind it again in a later section.
- **`bindings`** maps a keystroke to a command id, or to `null` to take
  the chord away.
- Two chords may name one command. Each is its own line, so neither is
  a duplicate of the other, nothing is reported, and both fire. The
  bundled default does this once: `cmd-n` and `cmd-t` both open a new
  tab, because a tab is what the pad opens and ⌘T is where every
  tabbed app puts one. Where the app spells a chord out, in a tooltip
  or beside a menu item, it names the first in canonical order, so ⌘N;
  set that one to `null` in your own keymap and the other takes its
  place.

Keystrokes are `cmd`, `ctrl`, `alt` (`opt`, `option`) and `shift` in any
order, then one key: a single character, or one of `escape`, `enter`,
`tab`, `space`, `backspace`, `delete`, `up`, `down`, `left`, `right`,
`home`, `end`, `pageup`, `pagedown`. Shift is a modifier and never a
capital letter. Function keys and `fn` are refused, because SwiftUI has
no way to install them and a binding that validates and then never
fires is the failure this layer exists to prevent.

Shift is refused over anything but a letter, for that same reason.
`cmd-shift-v` is fine; `cmd-shift-1` and `cmd-shift-,` are not. A key
event reports its unmodified characters with shift already applied, so
the page would see `!` where the file wrote `1` and never match, while
the surface's hidden buttons would install the chord and fire it: one
spelling, two surfaces, two answers. The chord is still bindable, by the
glyph the shift produces: `cmd-!` is ⇧⌘1, and `cmd-<` is the shifted
comma. Both fire on both routes, because the glyph carries the shift and
the file does not have to name it twice. Shift over a named key
(`cmd-shift-left`) is fine,
because named keys are matched by their place on the board.

Command ids are the enum in `Keymap/CommandID.swift`. Only commands
this build implements are bindable; an id nothing implements is
reported and dropped. `page::Select1` through `page::Select9` jump by
visible tab order, and the rest name themselves.

## Where the files are

| | |
| --- | --- |
| bundled default | inside the app, `Contents/Resources/default-keymap.json` |
| your override | `~/Library/Application Support/dev.onetimesecret.pad/keymap.json` for the installed copy (a dev build reads `dev.onetimesecret.pad.debug/keymap.json`, and an App Store build `com.onetimesecret.pad/keymap.json`) |

The override is optional and its absence is not an error. Note the
directory: it is the plain bundle id, beside the `.noindex` state
directory and not inside it. Sealed state is kept out of Spotlight and
out of Time Machine on purpose, and a file you wrote yourself wants the
opposite of both. The app never creates this directory, so making it is
the first step of writing an override.

Override sections are applied after the bundled ones, so a chord you
name wins, a chord you set to `null` goes away, and everything you say
nothing about keeps its default.

## Validation, and what a bad file costs

Two levels, and the difference matters:

- **Wrong about one line**: an unparseable keystroke, an unknown
  command id, a context that does not exist, or two spellings of one
  chord in a single section, whether the second one binds it or is a
  `null` taking it away. That line is dropped, the rest of the file
  stands, and the complaint goes to the unified log under the `keymap`
  category.
- **Wrong about the file**: not JSON, not an array, a section that is
  not an object, or a schema version this build does not read. The
  whole file is refused.

A refused override leaves the bundled default standing, so a typo in
your keymap costs you your customisation and not your app. A refused or
missing bundled default falls back to the last map that resolved
cleanly, and at launch there is none, so it falls back to no bindings
at all. That is deliberate: no chord ends up pointed somewhere
unintended, and almost every gesture the map carries also has a button
or a menu item, so the app stays usable with no keymap whatsoever.

Two are worth naming, because they are the exceptions:

- `surface::HandBackKeys` has no control. Esc still hands the keyboard
  back from inside a page, because the text view answers AppKit's own
  cancel action and that is installed by the framework rather than by
  the map, and it still works in the pageless empty state, which has its
  own catcher. What an empty map costs is Esc while the focus sits on
  the surface chrome rather than in a page.
- `state::SaveNow` has no control either. The save indicator is a label,
  not a button. With no keymap there is no way to force the write, and
  the debounced save that runs on its own is what carries the session.

Both are shortcomings of the empty map rather than of the file format,
and both are cheap to live with next to the alternative, which is
guessing at bindings the file did not give.

To read the complaints:

```bash
log show --predicate 'subsystem IN {"com.onetimesecret.pad", "dev.onetimesecret.pad", "dev.onetimesecret.pad.debug"}' --last 1h --style compact
```

## How it is put together

| layer | file | what it knows |
| --- | --- | --- |
| parser | `Keymap/Keystroke.swift` | text to chord, and chord to canonical text. Pure. |
| file | `Keymap/KeymapFile.swift` | JSON5 tolerance and the file's shape. Pure. |
| validator | `Keymap/Keymap.swift` | merging, refusing, falling back, reporting. Pure. |
| registry | `Keymap/KeymapRegistry.swift` | `PageModel.perform(_:)`, one exhaustive switch. |
| frameworks | `Keymap/KeystrokeBridge.swift` | `KeyboardShortcut`, menu equivalents, matching an `NSEvent`. |

Three dispatch c󠄁a󠄁t󠄁e󠄁g󠄁o󠄁r󠄁i󠄁e󠄁s󠄁 (󠄁`CommandID.Dispatch`)󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁'󠄁s󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁.󠄁
`PageKeyboardMap` i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁s󠄁 s󠄁u󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 b󠄁i󠄁n󠄁d󠄁i󠄁n󠄁g󠄁s󠄁 o󠄁n󠄁l󠄁y󠄁 i󠄁n󠄁 t󠄁h󠄁e󠄁 w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 t󠄁h󠄁a󠄁t󠄁 o󠄁w󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁
p󠄁r󠄁e󠄁s󠄁e󠄁n󠄁t󠄁a󠄁t󠄁i󠄁o󠄁n󠄁.󠄁 C󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁-󠄁b󠄁e󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁d󠄁 b󠄁a󠄁r󠄁e󠄁 s󠄁u󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 b󠄁i󠄁n󠄁d󠄁i󠄁n󠄁g󠄁s󠄁 u󠄁s󠄁e󠄁 S󠄁w󠄁i󠄁f󠄁t󠄁U󠄁I󠄁 h󠄁i󠄁d󠄁d󠄁e󠄁n󠄁
b󠄁u󠄁t󠄁t󠄁o󠄁n󠄁s󠄁.󠄁 C󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁/󠄁O󠄁p󠄁t󠄁i󠄁o󠄁n󠄁 b󠄁i󠄁n󠄁d󠄁i󠄁n󠄁g󠄁s󠄁 w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁 C󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁 u󠄁s󠄁e󠄁 a󠄁 t󠄁e󠄁x󠄁t󠄁-󠄁a󠄁w󠄁a󠄁r󠄁e󠄁 A󠄁p󠄁p󠄁K󠄁i󠄁t󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁:󠄁
`InkTextView.keyDown` d󠄁i󠄁s󠄁p󠄁a󠄁t󠄁c󠄁h󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁m󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁g󠄁e󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁 h󠄁a󠄁s󠄁 f󠄁o󠄁c󠄁u󠄁s󠄁,󠄁 a󠄁f󠄁t󠄁e󠄁r󠄁
r󠄁e󠄁f󠄁u󠄁s󠄁i󠄁n󠄁g󠄁 a󠄁c󠄁t󠄁i󠄁v󠄁e󠄁 c󠄁o󠄁m󠄁p󠄁o󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁;󠄁 a󠄁 m󠄁o󠄁u󠄁n󠄁t󠄁e󠄁d󠄁 `SurfaceShortcutFallbackView` a󠄁n󠄁s󠄁w󠄁e󠄁r󠄁s󠄁
t󠄁h󠄁e󠄁m󠄁 f󠄁r󠄁o󠄁m󠄁 e󠄁m󠄁p󠄁t󠄁y󠄁-󠄁s󠄁t󠄁a󠄁t󠄁e󠄁 a󠄁n󠄁d󠄁 o󠄁t󠄁h󠄁e󠄁r󠄁 n󠄁o󠄁n󠄁t󠄁e󠄁x󠄁t󠄁 r󠄁e󠄁s󠄁p󠄁o󠄁n󠄁d󠄁e󠄁r󠄁s󠄁.󠄁 T󠄁h󠄁e󠄁 f󠄁a󠄁l󠄁l󠄁b󠄁a󠄁c󠄁k󠄁 s󠄁k󠄁i󠄁p󠄁s󠄁 e󠄁v󠄁e󠄁r󠄁y󠄁
`NSTextView`,󠄁 i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁i󠄁n󠄁g󠄁 n󠄁a󠄁t󠄁i󠄁v󠄁e󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 e󠄁d󠄁i󠄁t󠄁o󠄁r󠄁s󠄁,󠄁 s󠄁o󠄁 s󠄁e󠄁a󠄁r󠄁c󠄁h󠄁,󠄁 n󠄁a󠄁m󠄁i󠄁n󠄁g󠄁,󠄁 n󠄁o󠄁t󠄁e󠄁 a󠄁n󠄁d󠄁 o󠄁t󠄁h󠄁e󠄁r󠄁
t󠄁e󠄁x󠄁t󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁s󠄁 k󠄁e󠄁e󠄁p󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 e󠄁d󠄁i󠄁t󠄁i󠄁n󠄁g󠄁 k󠄁e󠄁y󠄁s󠄁.󠄁 S󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 m󠄁o󠄁u󠄁n󠄁t󠄁 a󠄁 s󠄁u󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 m󠄁a󠄁p󠄁.󠄁

E󠄁d󠄁i󠄁t󠄁o󠄁r󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁s󠄁 r󠄁u󠄁n󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 t󠄁h󠄁e󠄁 p󠄁a󠄁g󠄁e󠄁 t󠄁e󠄁x󠄁t󠄁 v󠄁i󠄁e󠄁w󠄁,󠄁 w󠄁h󠄁i󠄁c󠄁h󠄁 o󠄁w󠄁n󠄁s󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 c󠄁a󠄁r󠄁e󠄁t󠄁 a󠄁n󠄁d󠄁
s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁.󠄁 W󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁s󠄁 (󠄁`window::Close`,󠄁 `app::Help` a󠄁n󠄁d󠄁
`app::CommandPalette`)󠄁 u󠄁s󠄁e󠄁 m󠄁a󠄁i󠄁n󠄁-󠄁m󠄁e󠄁n󠄁u󠄁 e󠄁q󠄁u󠄁i󠄁v󠄁a󠄁l󠄁e󠄁n󠄁t󠄁s󠄁.󠄁 T󠄁h󠄁e󠄁 v󠄁a󠄁l󠄁i󠄁d󠄁a󠄁t󠄁o󠄁r󠄁 r󠄁e󠄁p󠄁o󠄁r󠄁t󠄁s󠄁 a󠄁
w󠄁i󠄁n󠄁d󠄁o󠄁w󠄁 c󠄁o󠄁m󠄁m󠄁a󠄁n󠄁d󠄁 b󠄁o󠄁u󠄁n󠄁d󠄁 o󠄁u󠄁t󠄁s󠄁i󠄁d󠄁e󠄁 a󠄁 `use_key_equivalents` s󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁s󠄁
`windowCommandWithoutKeyEquivalents`.󠄁

## What is not in the map

- **⌃⌥Space**, the summon. A system-wide Carbon hotkey, registered
  outside the responder chain and against another app's claim, so it is
  not a key equivalent and cannot be expressed here.
- **⌘Q, ⌘F, ⌘G, ⇧⌘G, ⌥⌘F, ⌘E, ⌘V, ⌘Z**. AppKit's own, arriving through
  `TextEditingCommands` and the standard responder chain. Routing them
  through the map would mean reimplementing them.
- **Return and Esc in the empty state**, which are the third and fourth
  focus grants (ADR-0005). They belong to a view that exists precisely
  to accept the first keystroke, and they are focus law rather than
  shortcuts.
