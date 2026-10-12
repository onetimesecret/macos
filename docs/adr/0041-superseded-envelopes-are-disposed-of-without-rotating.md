---
documentation_status: draft # needs-review | reviewed | stale
---

# ADR-0041: Superseded state envelopes are disposed of without rotating the key

- **Status:** proposed
- **Date:** 2026-10-12
- **Depends on:** [ADR-0004](0004-keychain-prompt-timing.md) and [ADR-0016](0016-content-persists-across-restart.md)

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

The reasoning below was recovered from code comments at commit `087d682`
(`crates/ffi/src/persist.rs`, `SUPERSEDED_MAGICS`, and the `Superseded` arm of
`companion_persist_restore` in `crates/ffi/src/lib.rs`). Those comments are
non-authoritative provenance; this record proposes the decision they describe.

[ADR-0016](0016-content-persists-across-restart.md) (accepted) decides that
"Known superseded formats are securely discarded so they do not leave an
install permanently unable to save; unknown or damaged formats continue to fail
closed." It does not say whether that disposal also rotates the key halves.

[ADR-0004](0004-keychain-prompt-timing.md) (accepted) sets the constraint that
"a security prompt should appear at the moment the user can attribute it to
something they did. "The app started" is not that moment." Its Decision is
worded for reads: "The Keychain ACL prompt is allowed to appear only when a
secret is actually used, a conceal reading the token, never for a presence
check." Applying it to a keychain write at launch is an interpretation, not
ADR-0004's wording.

Section 9 of the
[persistence decision background](../plans/trustworthy-persistence-decision-background.md#9-migration-one-format-break-taken-deliberately),
which ADR-0016's Context names as the home of its numbered sections, makes the
same choice for the ledger only: "The ledger key is not rotated: the file was
authentic under it, the user's Clear does not rotate it either, and a rotation
at launch is the Keychain prompt ADR-0004 forbids." It says of the content
envelope that "An `OTSSEAL2` file's key derives from a half in the temp
directory that the restart already cleared".

The only superseded envelope is `OTSSEAL2`. The recovered comment states that
its key was derived from a keychain half under the same account and HKDF info
string the current build uses, and a second half in the per-user temp
directory; this record has not verified that against the `OTSSEAL2` build. [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)
(proposed) concedes about that temp half: "It does not guarantee the previous
half's bytes are unreachable on disk if the temp directory was not cleared."

## Decision

Disposing of a state file whose envelope is in `SUPERSEDED_MAGICS` erases the
file and grants the save licence without rotating either key half.

This holds only while every entry in `SUPERSEDED_MAGICS` predates ADR-0016's
move of the file half into the state directory. Adding an entry sealed after
that move requires deciding again whether disposal must rotate; the test
`the_superseded_set_predates_the_key_half_move` (`crates/ffi/src/persist.rs`)
fails on any change to the set so the question comes up with the entry.

## Consequences

- The first launch after the format break makes no keychain write before the
  user has asked the app for anything.
- The `OTSSEAL2` keychain half stays in the keychain, readable by the app, and
  `ensure_state_key` reuses it as the keychain half of the first `OTSSEAL3` key
  until the next rotation (pad emptied or Clear).
- A captured `OTSSEAL2` ciphertext stays decryptable by anyone who also kept its
  temp-directory half and can read the keychain half. Dropping the file does not
  change that either way; rotating would have removed the keychain half from
  the live keychain but not from any copy already taken.
- Nothing is written to the ledger for the discarded pages, because the file is
  never decrypted.

## Eject triggers

- A format break whose superseded envelope was sealed with a file half in the
  state directory, which would leave a whole working key behind on disposal.
- A hardware session shows that a keychain delete and add at launch raises no
  ACL prompt, which removes the cost this decision avoids.
- Evidence that macOS does not clear the per-user temp directory on the
  installs that carried `OTSSEAL2` files.
