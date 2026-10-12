---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0041: Every keychain call names its keychain

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0016](0016-content-persists-across-restart.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/credentials/src/lib.rs`, the doc comment on
`impl CredentialStore for KeychainStore` and the `secitem` module header).
Those comments are non-authoritative provenance; this record proposes the
decision they describe.

A legacy `SecItem` query that names no keychain is resolved against the user's
keychain search list. That list is user-editable and can hold keychains on
backup volumes or disks that are gone. According to the recovered comment, a
search-list entry the process cannot open makes `SecItemDelete` fail with that
entry's error, for an item that sits in the default keychain. Sandboxing and
TCC make this per process, so the same call can succeed from a terminal and
fail inside the app.

The recovered comment records that this wedged persistence: a key-half delete
that failed made the rotation report refusal, and the refusal withheld the save
licence. [ADR-0016](0016-content-persists-across-restart.md) (accepted) depends
on deletes working: "Rotate them when no tab holds a page and when the user
explicitly clears state." Section 6 of the
[persistence decision background](../plans/trustworthy-persistence-decision-background.md#6-key-rotation-once-bootmismatch-is-gone)
now makes the rotation rest on the file half: "The keychain half is then
deleted for hygiene, announced but never decisive." A failed keychain delete
therefore no longer refuses a rotation by itself
([Law 0005](../law/0005-content-key-rotation.md)), but it still leaves the old
keychain half behind and still fails other deletes, such as removing the API
token.

`security-framework` 2.11, the crate the store used, cannot name a keychain in
its password helpers or `ItemSearchOptions`, and does not set the data
protection keychain flag.

## Decision

Every credential store call names the keychain it acts on and never falls back
to the search list. The data protection tier sets
`kSecUseDataProtectionKeychain`. The fallback tier names the user's default
keychain: `kSecMatchSearchList` holding only that keychain for queries, updates
and deletes, and `kSecUseKeychain` for adds.

The calls are raw `SecItem` FFI, confined to one `secitem` module in
`crates/credentials`, because the wrapper crate cannot express either scope.

## Consequences

- An unopenable keychain elsewhere in the search list no longer fails this
  app's deletes, loads or adds.
- An item in a keychain other than the default one is invisible to the
  fallback tier. If the user changes the default keychain, items written under
  the old default are not found.
- The credentials crate carries `unsafe` FFI, kept to one module so it can be
  audited by module.
- A machine with no default keychain (a headless CI runner) cannot use the
  fallback tier; its tests skip that leg.
- `each_tier_names_a_different_keychain` and
  `adding_names_the_keychain_a_second_way` pin the scoping; no CI test exercises
  a real search list with an unopenable entry.

## Eject triggers

- `security-framework` gains a way to name a keychain and set the data
  protection flag, which would let the raw module go.
- The legacy file-based keychain tier is removed, leaving only the data
  protection keychain, which has no search list.
- Users report items lost after changing their default keychain.
