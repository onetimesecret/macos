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

T󠄁h󠄁e󠄁 s󠄁e󠄁a󠄁l󠄁e󠄁d󠄁-󠄁i󠄁n󠄁t󠄁e󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 p󠄁o󠄁r󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 o󠄁f󠄁 p󠄁o󠄁i󠄁n󠄁t󠄁s󠄁 1󠄁–󠄁3󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 m󠄁e󠄁n󠄁u󠄁 e󠄁x󠄁a󠄁m󠄁p󠄁l󠄁e󠄁s󠄁 a󠄁r󠄁e󠄁
a󠄁m󠄁e󠄁n󠄁d󠄁e󠄁d󠄁 b󠄁y󠄁 t󠄁h󠄁e󠄁 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁0󠄁-󠄁3󠄁1󠄁 s󠄁c󠄁o󠄁p󠄁e󠄁d󠄁 r󠄁e󠄁v󠄁i󠄁s󠄁i󠄁o󠄁n󠄁 b󠄁e󠄁l󠄁o󠄁w󠄁.󠄁 O󠄁t󠄁h󠄁e󠄁r󠄁 i󠄁n󠄁t󠄁e󠄁r󠄁f󠄁a󠄁c󠄁e󠄁s󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁
t󠄁h󠄁e󠄁s󠄁e󠄁 r󠄁u󠄁l󠄁e󠄁s󠄁.󠄁

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

## Sealed-interface amendment, 2026-10-31

T󠄁h󠄁e󠄁 m󠄁a󠄁i󠄁n󠄁t󠄁a󠄁i󠄁n󠄁e󠄁r󠄁 a󠄁u󠄁t󠄁h󠄁o󠄁r󠄁i󠄁z󠄁e󠄁d󠄁 t󠄁h󠄁e󠄁 2󠄁8󠄁-󠄁i󠄁t󠄁e󠄁m󠄁 s󠄁e󠄁a󠄁l󠄁e󠄁d󠄁-󠄁c󠄁o󠄁n󠄁t󠄁e󠄁n󠄁t󠄁 U󠄁X󠄁 r󠄁e󠄁v󠄁i󠄁s󠄁i󠄁o󠄁n󠄁 i󠄁n󠄁 t󠄁h󠄁e󠄁
i󠄁n󠄁s󠄁t󠄁r󠄁u󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 q󠄁u󠄁o󠄁t󠄁e󠄁d󠄁 b󠄁y󠄁 t󠄁h󠄁e󠄁 [d󠄁a󠄁t󠄁e󠄁d󠄁 s󠄁u󠄁c󠄁c󠄁e󠄁s󠄁s󠄁o󠄁r󠄁](../spec/design/2026-1031-sealed-content-ux-revision.md).󠄁
T󠄁h󠄁a󠄁t󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 s󠄁e󠄁a󠄁l󠄁e󠄁d󠄁 m󠄁e󠄁n󠄁u󠄁 a󠄁n󠄁d󠄁 s󠄁h󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁 a󠄁b󠄁o󠄁v󠄁e󠄁.󠄁 I󠄁t󠄁 s󠄁p󠄁e󠄁c󠄁i󠄁f󠄁i󠄁e󠄁s󠄁
S󠄁e󠄁t󠄁/󠄁E󠄁d󠄁i󠄁t󠄁 V󠄁a󠄁r󠄁i󠄁a󠄁b󠄁l󠄁e󠄁 N󠄁a󠄁m󠄁e󠄁…󠄁,󠄁 C󠄁o󠄁p󠄁y󠄁 V󠄁a󠄁r󠄁i󠄁a󠄁b󠄁l󠄁e󠄁 N󠄁a󠄁m󠄁e󠄁,󠄁 C󠄁o󠄁p󠄁y󠄁 N󠄁A󠄁M󠄁E󠄁=󠄁V󠄁a󠄁l󠄁u󠄁e󠄁 (󠄁U󠄁n󠄁q󠄁u󠄁o󠄁t󠄁e󠄁d󠄁)󠄁,󠄁
A󠄁d󠄁d󠄁/󠄁E󠄁d󠄁i󠄁t󠄁 N󠄁o󠄁t󠄁e󠄁…󠄁,󠄁 a󠄁n󠄁d󠄁 R󠄁e󠄁m󠄁o󠄁v󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 D󠄁o󠄁c󠄁u󠄁m󠄁e󠄁n󠄁t󠄁.󠄁 S󠄁h󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁i󠄁o󠄁n󠄁 u󠄁s󠄁e󠄁s󠄁 C󠄁o󠄁p󠄁y󠄁 L󠄁i󠄁n󠄁k󠄁
A󠄁g󠄁a󠄁i󠄁n󠄁,󠄁 D󠄁o󠄁n󠄁e󠄁,󠄁 D󠄁e󠄁l󠄁e󠄁t󠄁e󠄁 L󠄁o󠄁c󠄁a󠄁l󠄁 S󠄁e󠄁a󠄁l󠄁e󠄁d󠄁 C󠄁o󠄁n󠄁t󠄁e󠄁n󠄁t󠄁 a󠄁n󠄁d󠄁 D󠄁i󠄁s󠄁c󠄁a󠄁r󠄁d󠄁 L󠄁o󠄁c󠄁a󠄁l󠄁 P󠄁a󠄁g󠄁e󠄁.󠄁

M󠄁e󠄁n󠄁u󠄁s󠄁 a󠄁n󠄁d󠄁 o󠄁r󠄁d󠄁i󠄁n󠄁a󠄁r󠄁y󠄁 b󠄁u󠄁t󠄁t󠄁o󠄁n󠄁s󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁i󠄁t󠄁l󠄁e󠄁 c󠄁a󠄁s󠄁e󠄁.󠄁 T󠄁h󠄁e󠄁 c󠄁o󠄁m󠄁p󠄁a󠄁c󠄁t󠄁 b󠄁l󠄁o󠄁c󠄁k󠄁 u󠄁s󠄁e󠄁s󠄁 s󠄁e󠄁n󠄁t󠄁e󠄁n󠄁c󠄁e󠄁
c󠄁a󠄁s󠄁e󠄁 f󠄁o󠄁r󠄁 S󠄁e󠄁a󠄁l󠄁e󠄁d󠄁 t󠄁e󠄁x󠄁t󠄁,󠄁 S󠄁e󠄁a󠄁l󠄁e󠄁d󠄁 i󠄁m󠄁a󠄁g󠄁e󠄁,󠄁 C󠄁o󠄁p󠄁y󠄁 d󠄁e󠄁c󠄁r󠄁y󠄁p󠄁t󠄁e󠄁d󠄁 a󠄁n󠄁d󠄁 C󠄁o󠄁p󠄁i󠄁e󠄁d󠄁.󠄁 F󠄁i󠄁e󠄁l󠄁d󠄁 g󠄁u󠄁i󠄁d󠄁a󠄁n󠄁c󠄁e󠄁,󠄁
v󠄁a󠄁l󠄁i󠄁d󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 v󠄁i󠄁s󠄁i󠄁b󠄁l󠄁e󠄁 p󠄁r󠄁e󠄁-󠄁s󠄁e󠄁a󠄁l󠄁 e󠄁x󠄁p󠄁l󠄁a󠄁n󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 u󠄁s󠄁e󠄁 o󠄁r󠄁d󠄁i󠄁n󠄁a󠄁r󠄁y󠄁 s󠄁e󠄁n󠄁t󠄁e󠄁n󠄁c󠄁e󠄁 c󠄁a󠄁s󠄁e󠄁
a󠄁n󠄁d󠄁 m󠄁a󠄁y󠄁 i󠄁n󠄁s󠄁t󠄁r󠄁u󠄁c󠄁t󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁a󠄁d󠄁e󠄁r󠄁 d󠄁i󠄁r󠄁e󠄁c󠄁t󠄁l󠄁y󠄁.󠄁 T󠄁h󠄁e󠄁 e󠄁l󠄁l󠄁i󠄁p󠄁s󠄁i󠄁s󠄁 o󠄁n󠄁 S󠄁e󠄁t󠄁/󠄁E󠄁d󠄁i󠄁t󠄁 V󠄁a󠄁r󠄁i󠄁a󠄁b󠄁l󠄁e󠄁 N󠄁a󠄁m󠄁e󠄁…󠄁
i󠄁s󠄁 a󠄁n󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁 e󠄁x󠄁c󠄁e󠄁p󠄁t󠄁i󠄁o󠄁n󠄁 f󠄁o󠄁r󠄁 t󠄁h󠄁a󠄁t󠄁 f󠄁i󠄁e󠄁l󠄁d󠄁 a󠄁n󠄁d󠄁 i󠄁t󠄁s󠄁 a󠄁n󠄁c󠄁h󠄁o󠄁r󠄁e󠄁d󠄁 a󠄁u󠄁x󠄁i󠄁l󠄁i󠄁a󠄁r󠄁y󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁s󠄁.󠄁
P󠄁a󠄁g󠄁e󠄁,󠄁 t󠄁a󠄁b󠄁 a󠄁n󠄁d󠄁 p󠄁a󠄁d󠄁 r󠄁e󠄁n󠄁a󠄁m󠄁i󠄁n󠄁g󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁.󠄁 E󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 f󠄁o󠄁o󠄁t󠄁e󠄁r󠄁
n󠄁o󠄁t󠄁i󠄁c󠄁e󠄁s󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 D󠄁-󠄁1󠄁5󠄁'󠄁s󠄁 l󠄁o󠄁w󠄁e󠄁r󠄁-󠄁c󠄁a󠄁s󠄁e󠄁 s󠄁t󠄁a󠄁t󠄁u󠄁s󠄁 r󠄁e󠄁g󠄁i󠄁s󠄁t󠄁e󠄁r󠄁.󠄁 T󠄁h󠄁e󠄁 f󠄁o󠄁r󠄁m󠄁e󠄁r󠄁 s󠄁e󠄁a󠄁l󠄁e󠄁d󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁
a󠄁b󠄁o󠄁v󠄁e󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁 h󠄁i󠄁s󠄁t󠄁o󠄁r󠄁i󠄁c󠄁a󠄁l󠄁 b󠄁a󠄁s󠄁i󠄁s󠄁 o󠄁f󠄁 t󠄁h󠄁i󠄁s󠄁 A󠄁D󠄁R󠄁,󠄁 r󠄁a󠄁t󠄁h󠄁e󠄁r󠄁 t󠄁h󠄁a󠄁n󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁v󠄁i󠄁s󠄁e󠄁d󠄁 m󠄁e󠄁n󠄁u󠄁.󠄁

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
- 2󠄁0󠄁2󠄁6󠄁-󠄁1󠄁0󠄁-󠄁3󠄁1󠄁:󠄁 S󠄁c󠄁o󠄁p󠄁e󠄁d󠄁 s󠄁e󠄁a󠄁l󠄁e󠄁d󠄁-󠄁i󠄁n󠄁t󠄁e󠄁r󠄁f󠄁a󠄁c󠄁e󠄁 a󠄁m󠄁e󠄁n󠄁d󠄁m󠄁e󠄁n󠄁t󠄁.󠄁 T󠄁h󠄁e󠄁 d󠄁a󠄁t󠄁e󠄁d󠄁 s󠄁u󠄁c󠄁c󠄁e󠄁s󠄁s󠄁o󠄁r󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁s󠄁
  t󠄁h󠄁e󠄁 r󠄁e󠄁v󠄁i󠄁s󠄁e󠄁d󠄁 m󠄁e󠄁n󠄁u󠄁,󠄁 c󠄁o󠄁m󠄁p󠄁a󠄁c󠄁t󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁,󠄁 l󠄁o󠄁c󠄁a󠄁l󠄁 g󠄁u󠄁i󠄁d󠄁a󠄁n󠄁c󠄁e󠄁 a󠄁n󠄁d󠄁 s󠄁h󠄁a󠄁r󠄁i󠄁n󠄁g󠄁 a󠄁c󠄁t󠄁i󠄁o󠄁n󠄁s󠄁;󠄁
  o󠄁t󠄁h󠄁e󠄁r󠄁 i󠄁n󠄁t󠄁e󠄁r󠄁f󠄁a󠄁c󠄁e󠄁s󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 w󠄁o󠄁r󠄁d󠄁i󠄁n󠄁g󠄁 r󠄁u󠄁l󠄁e󠄁s󠄁.󠄁
