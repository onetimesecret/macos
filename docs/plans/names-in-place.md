# Names in place

**GitHub milestone:** [Names in place](https://github.com/onetimesecret/macos/milestone/5)  
**Status:** Open. The epic's build tickets all closed by 2026-10-17; #256 and #257 remain, and the epic closes with them.  
**Source of execution status:** GitHub issues, not this document. The plan proper is the epic, [#252](https://github.com/onetimesecret/macos/issues/252), with the gap table, the invariants and the dependency graph; this page is the index to it.

## Goal

Bring the build up to [Law 0007](../law/0007-edit-in-place.md) (edit in place, accepted 2026-10-13) and to [Law 0001](../law/0001-sealed-object.md)'s 2026-10-13 amendment: a sealed object has a name and a note, and every name is edited in its own seat.

## Completion criteria

As the epic states it: every row of its gap table has a closed ticket, and every row of the laws' contract tables passes against the build.

## Tracks

- **Decision.** [#240](https://github.com/onetimesecret/macos/issues/240) settled the name, zone and seat details the laws leave open. Closed 2026-10-16; the choices are [ADR-0042](../adr/0042-a-sealed-name-is-a-shell-identifier.md) to [ADR-0047](../adr/0047-name-value-copies-the-value-unquoted.md), accepted 2026-10-16.
- **Track A, Law 0007 seats.** Shell only: the gutter ([#248](https://github.com/onetimesecret/macos/issues/248)), the strip ([#250](https://github.com/onetimesecret/macos/issues/250)) and the pad list ([#249](https://github.com/onetimesecret/macos/issues/249)). Closed 2026-10-16.
- **Track B, the sealed name and note.** Core first, then shell: the typed name ([#241](https://github.com/onetimesecret/macos/issues/241)), copy name=value from the core ([#242](https://github.com/onetimesecret/macos/issues/242)), the note with its own undo ([#243](https://github.com/onetimesecret/macos/issues/243)), the NAME=excerpt row and copy zones ([#244](https://github.com/onetimesecret/macos/issues/244)), the name field ([#245](https://github.com/onetimesecret/macos/issues/245)), the note popover ([#246](https://github.com/onetimesecret/macos/issues/246)), and the fragment with both on it ([#247](https://github.com/onetimesecret/macos/issues/247), after #170). Closed 2026-10-16. Delivered in [PR 259](https://github.com/onetimesecret/macos/pull/259), with ADR-0042 to ADR-0047 accepted in [PR 265](https://github.com/onetimesecret/macos/pull/265).
- **Follow ons the review raised.** A drop onto a time tab ([#254](https://github.com/onetimesecret/macos/issues/254), [PR 264](https://github.com/onetimesecret/macos/pull/264)) and a move handle distinct from the decrypted drag handle ([#255](https://github.com/onetimesecret/macos/issues/255), [PR 263](https://github.com/onetimesecret/macos/pull/263)), both closed 2026-10-16. [#267](https://github.com/onetimesecret/macos/issues/267), drops on the Timeline's page nodes, closed 2026-10-21 with [PR 269](https://github.com/onetimesecret/macos/pull/269).
- **Documents.** Law 0001's body brought in line with its amendment ([#251](https://github.com/onetimesecret/macos/issues/251)), closed 2026-10-17.

## Still open

- [#256](https://github.com/onetimesecret/macos/issues/256): JSON handed to Swift and the sync outbox follow the app's security model. [PR 270](https://github.com/onetimesecret/macos/pull/270) delivered wiping ownership on content buffers and the JSON boundary; the resident owners, the fragment parsing and the retained Swift content are owed.
- [#257](https://github.com/onetimesecret/macos/issues/257): a sealed object never stalls a page's sync. [ADR-0058](../adr/0058-a-sealed-object-never-stalls-a-pages-sync.md) is proposed for it.
- [#170](https://github.com/onetimesecret/macos/issues/170): the sealed object pasteboard model, built and tested across PRs 259 to 269 and open for the maintainer's hand checks. It is not in the milestone.

## Explicitly unchanged

The epic lists what this milestone leaves alone: the create pad sheet, the strip's double click as the hold, the ledger record's shape, and the plain text placeholder. No envelope takes a sealed object to a peer, as the client protocol stands (row 10.31, which ADR-0058 proposes to replace; `crates/core/src/store.rs` `sync_carries_no_object_so_a_move_between_pages_stands_none_on_a_peer` and `sync_carries_no_object_so_a_cut_reattached_on_another_page_stands_none_on_a_peer`), so names and notes do not sync either, which is what #257 reopens.
