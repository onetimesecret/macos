# docs/development/about-the-keymap.md
---

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
      "cmd-alt-n": "page::New",
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
  as a macOS menu key equivalent. Only `app::Settings` takes one up
  today. A menu equivalent is an app-wide claim, live even while a
  Settings field holds the keyboard, so it has to be asked for. Once
  granted, it stays with that chord and command: a later section that
  restates the same line without asking for equivalents leaves the
  equivalent standing, because a file repeating a default line to keep
  it in sight must not quietly take something away. To withdraw one,
  set the chord to `null` and bind it again in a later section.
- **`bindings`** maps a keystroke to a command id, or to `null` to take
  the chord away.

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
| your override | `~/Library/Application Support/com.onetimesecret.companion.backdrop/keymap.json` |

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
log show --predicate 'subsystem BEGINSWITH "com.onetimesecret"' --last 1h --style compact
```

## How it is put together

| layer | file | what it knows |
| --- | --- | --- |
| parser | `Keymap/Keystroke.swift` | text to chord, and chord to canonical text. Pure. |
| file | `Keymap/KeymapFile.swift` | JSON5 tolerance and the file's shape. Pure. |
| validator | `Keymap/Keymap.swift` | merging, refusing, falling back, reporting. Pure. |
| registry | `Keymap/KeymapRegistry.swift` | `PageModel.perform(_:)`, one exhaustive switch. |
| frameworks | `Keymap/KeystrokeBridge.swift` | `KeyboardShortcut`, menu equivalents, matching an `NSEvent`. |

Two dispatch routes, and which one a command takes is a property of the
command rather than of the file. Surface commands are carried by the
hidden buttons `PageKeyboardMap` mounts while the card is raised. Editor
commands are answered by the page's own text view, which sees a
keystroke before those buttons do and which owns the caret and the
selection the seal gestures act on.

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
