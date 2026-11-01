---
documentation_status: needs-review
---

# ADR-0055: Menus and buttons use the platform's wording

- **Status:** accepted
- **Date:** 2026-10-14

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The 2026-10-13 audit of two screenshots against Apple's Human Interface
Guidelines found menu items and buttons in sentence case, an ellipsis on
items that edit in place, three nouns for the sealed object (`SEALED
CONTENT`, *protected content*, *decrypted contents*) and two verbs for
the link (the menu's *Create*, the sheet's *conceal*). The accepted
words came from the 2026-0915 records (D-09, D-41, D-42) and ADR-0042.

The platform's convention is title case for menu items and buttons; an
ellipsis where more input follows in another window, panel, sheet or
popover; and none on a command that edits where the thing is shown
(Finder's Rename). On 2026-10-14 the maintainer chose title case with no
ellipsis on in-place renames, and *sealed* as the one noun with the
menu's *create* as the sheet's verb.

## Decision

Menus and buttons are worded as the platform words them.

1. Menu items and buttons are title case: every word capitalised but
   articles, coordinating conjunctions and prepositions of four letters
   or fewer, unless first or last. Status lines, notices, captions,
   tooltips and the conceal sheet's title keep D-15's lower case
   sentences.
2. An ellipsis marks an item or button after which more input follows in
   another window, panel, sheet or popover: *Create One-Time Link…*,
   *Note…*, *New Pad…*, *Save As…*. An item that opens a field in the
   name's own seat carries none: *Name*, *Rename*, *Rename Tab*,
   *Rename Page*.
3. The object is *sealed content*: *Remove Sealed Content*, the removal
   line `sealed content removed.`, the sheet's title `create a one-time
   link from this sealed content`. *Copy Decrypted Contents* keeps
   *decrypted*, which names what leaves (D-29). The sheet's verb is the
   menu's, *create*; *conceal* stays the code's and the server's verb
   ([ADR-0007](0007-terminology.md), Amendment 3).

## Consequences

- D-41's menu reads *Copy Name*, *Copy Decrypted Contents*, *Copy
  Name=Value, Decrypted*, *Create One-Time Link…*, *Name* or *Rename*,
  *Note…* or *Edit Note…*, *Remove Sealed Content*. The strip's, the
  gutter's and the file row's items, the conceal sheet's buttons, the
  status lines' buttons and the Settings buttons follow rule 1.
- Law 0007 quotes the maintainer's "Rename… edits it in place" as said;
  its own lists of ways in drop the ellipsis.
- The 2026-0915 records keep their words with dated notes pointing here.
  Tests pin the new titles (`DocumentOpsTests`, `SealedCapsuleTests`,
  `TabLifetimeTests`, `SyncSurfaceTests`, `DayScrollTests`).
- A sentence that names a button names it as titled: a refused save
  reads `Choose Keep Mine, Take Theirs, or Save As… before saving.`
- `Name=Value` reads oddly in title case; it is kept as written because
  the rule has no exception for a literal.

## Eject triggers

- A localization whose own convention for menu case differs, which would
  move case into the strings rather than the code.
- A hand check where a reader takes *Rename* for an item that renames at
  once without a field, which would ask for the ellipsis back or for a
  different verb.

## Decision history

- 2026-10-14: Accepted from the maintainer's choice on the HIG audit
  (fix/ui-guidelines). The stream navigator record carries dated notes at
  D-41 and D-42, the 2026-0915 UI/UX record at D-09, and Laws 0001 and
  0007 amendments cite this record.
- 2026-10-15: The ADR-0042 this record superseded in part, *Sealed
  names, copy zones and rename seats*
  (`0042-sealed-names-copy-zones-and-rename-seats.md`, last at
  `8a10020f`), was a draft withdrawn without ratification
  (feature/editing-seals), so the relation is dropped. The proposed
  ADR-0042 now in this directory is a different record. The menu it
  amended is Law 0001's menu block and the
  [sealed row spec](../spec/feature/sealed-content/sealed-row-note-and-handles.md)'s
  The object's menu, both in this record's words.
- 2026-10-21: Rule 3 applied to the captions, tooltips and spoken labels
  that still said *conceal* as a noun or a UI verb (issue #295): the
  Connection and Sync settings, the conceal sheet's server tooltip and
  error line, and the strip's ↗ page tab. The API token is named as such.
- 2026-10-31: The [sealed-interface revision](../spec/design/2026-1031-sealed-content-ux-revision.md)
  replaces the sealed menu and sharing labels, and records scoped exceptions
  for compact sentence-case controls, instructional guidance and the ellipsis
  on Set/Edit Variable Name…. Other interfaces retain this ADR's wording rules.
