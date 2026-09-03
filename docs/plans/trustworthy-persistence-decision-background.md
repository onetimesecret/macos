---
documentation_status: needs-review # draft | needs-review | reviewed | stale
---

# Persistence decision background

> Supporting historical analysis for [ADR-0016](../adr/0016-content-persists-across-restart.md). This document preserves implementation chronology, citations, and test planning. GitHub issues and the [recovery matrix](../qa/recovery-matrix.md) are authoritative for current execution and coverage status.

This background was written on 2026-08-20, alongside the decision it supports.
[ADR-0012](../adr/0012-framing-threat-boundary-and-persistence-model.md)'s
Supersession section is the single authority on what ADR-0016 replaced and what
was left standing; sections 3, 4 and 8 below carry the supporting detail. The
change rode the same one-time format break as
[ADR-0017](../adr/0017-durable-tabs-expiring-pages.md), "Durable tabs, expiring
pages"; see section 9.

## Context

Issue #44 asks for the durability and security contract for unexpired
pages. The maintainer's own report is what opened the milestone
(`docs/dogfood/ABERRATIONS.md`): "I lost a whole bunch of stuff b/c I
accepted a system update without considering onetime pad", followed in the same
note by "If we already have the TTL expiration, we don't gain much by
flushing everything upon restart. We just make it annoying to use."

What the tree did on 2026-08-20, when this decision was taken, verified
at file:line in `docs/plans/44-ground-truth.md`. That document is a
snapshot of that date and is deliberately not maintained, so read the
list below as the starting position rather than as the tree's present
state:

- The sealed state envelope is
  `OTSSEAL2 ‖ boot_uuid[16] ‖ wall_ms[8] ‖ mono_ns[8]`, and all 40 bytes
  are the AEAD associated data (`crates/ffi/src/persist.rs`).
- The content key is `HKDF-SHA256` with a temp-directory half as salt and
  a keychain half as input keying material (`crates/ffi/src/persist.rs`).
  The temp half's filename folds `kern.bootsessionuuid`
  (`crates/ffi/src/persist.rs`) and the file lives in
  `_CS_DARWIN_USER_TEMP_DIR` at mode 0600
  (`crates/ffi/src/persist.rs`).
- A file carrying another session's boot UUID opens as
  `Opened::BootMismatch`, which rotates both halves and erases the file
  (`crates/ffi/src/lib.rs`).
- Writes are `create_new` temp, `sync_all` (F_FULLFSYNC on Darwin),
  `rename(2)`, parent directory fsync
  (`crates/ffi/src/persist.rs`).

Two facts decide this ADR against keeping the boot bound.

First, the boot bound does not deliver what ADR-0012 sells.
`rotate_key_halves` has exactly one caller, the `BootMismatch` arm at
`crates/ffi/src/lib.rs`, reachable only when a parseable state file
exists. A user who empties the pad before shutdown erases that file and
the next boot session reuses the previous keychain half verbatim
(`crates/ffi/src/persist.rs`). ADR-0012 already concedes the
previous temp half's bytes may still be on disk if the directory was not
cleared. Combine the two and an extracted keychain item plus an uncleared
temp directory yields a live content key across reboots. So ADR-0012's
"rotated on first launch after a new boot session" is not what the code
does, and keeping the bound would mean correcting that claim downward
rather than preserving it.

Second, ADR-0011 sets the default rung at seven days and
ADR-0011 justifies the rungs by calendar reasoning ("will I still
need this next week at this time"). On a machine that reboots weekly,
a boot-bound 7d rung never means what its label says.

## Decision

Staged content survives every ordinary process and machine lifecycle
event. Once the one-time format break of section 9 is behind the user,
its TTL is the only mechanism that destroys it that the user did not ask
for; emptying the pad and an explicit Clear are the two the user does ask
for (section 6). The boot-session
bound is removed: the second key half moves out of the per-boot temp
directory into the app support state directory, the boot field leaves the
sealed header, and the countdown a running process cannot observe is
drained by the wall-clock gap between the last save and the next restore,
recorded per page as the span of life that is left, which no restore may
lengthen. Section 4 states exactly what that is worth and what it is not,
and records (amended 2026-08-23) why the `drained_ms` field this decision
first specified was not the encoding that shipped.

Everything below marked **Required work** was not implemented when this
decision was written. Everything stated without that marker carried a
file:line citation and was what the tree did on 2026-08-20.

**Amendment 2026-08-22.** The Required work landed in two pull requests:
#60 took the envelope break, the key half move, the two clocks, the
superseded envelope disposal and the rotation on drop; #62 took the
superseded ledger disposal (issue #61), the ADR-0017 shell stage with
the rotation on the no-page predicate (section 6), and the four hardware
procedures of section 10, authored and not yet run. Issue #49 landed
after them, in the same cycle: the withheld licence and the write
lifecycle are surfaced, the content-side discard exists, and the quit
path warns on a settled flush over a withheld licence (sections 2 and
7). Issue #46 landed next: ⌘S calls the same `saveState()` the debounce
timer and the quit path already called, so the status surface issue #49
built now answers a user gesture too (section 2). Citations below into
the pre-ADR tree (`BootMismatch`, `monotonic_away_ms`, the boot-UUID
salt and the boot-session tests) describe code that no longer exists and
are left as written; they record what was replaced, not where to look.

### 1. The lifecycle table

"Survives" means: unexpired pages and their chips come back on the next
launch and nothing else is destroyed. A running page comes back with its
countdown drained by the time that passed. A held page does not: the gap
shortens the hold first, and only the part of the gap beyond the hold
reaches the countdown, which section 4 states exactly and section 10's
case 3 tests. Every row assumes the state file is readable;
section 7 covers the cases where it is not.

| Event | Unexpired content survives | What the user sees |
|---|---|---|
| Clean quit (⌘Q) | Yes, in full | `applicationShouldTerminate` calls `saveState()` and stands down whatever the debounce still holds (`shell/Sources/OnetimePad/BackdropApp.swift`, `shell/Sources/CompanionKit/PageModel.swift`). If that write is refused, an alert offers Quit Anyway or Cancel; a settled flush over a withheld licence with work in the session warns the same way (which outcome tells which story lives in `shell/Sources/CompanionKit/QuitPrompt.swift`, and the reply it becomes). On relaunch the pages are there with less time on them. |
| Crash (process fault) | Yes, except the debounce window | The last burst of typing inside the window is gone. Everything sealed before it is intact, because each write lands whole or not at all (`crates/ffi/src/persist.rs`). Nothing tells the user which keystrokes were lost. Window quantified in section 2. |
| Force termination (`kill -9`, Force Quit) | Yes, except the debounce window | Identical to crash. SIGKILL runs no handler, so the sudden-termination latch (`shell/Sources/CompanionKit/PageModel.swift`) buys nothing here; the atomic write is what saves the rest. |
| macOS restart or shutdown | Yes. The discard arm this row was written against is gone | An orderly restart delivers a terminate while a write is owed, because the latch holds sudden termination off a dirty buffer (PageModel.swift, `shell/OnetimePad-Info.plist`), so the quit flush runs and the loss window is zero. A mutation that never reached `markDirty()` is not covered, and neither is a kill before the flush lands. The empty pad this ADR was written to remove is removed: the restart is asserted at `a_restart_leaves_the_pages_alive_and_drains_them_by_the_gap` (`crates/ffi/src/lib.rs`) and confirmed on hardware once, `docs/qa/verification-procedures/reboot.md`, 2026-08-22. |
| App update (same bundle id, same signing identity) | Yes, when the sealed format version is unchanged. The version-change case is section 9's one-time break, taken | Replacing the bundle changes nothing the file depends on. A build whose `FILE_MAGIC` differs refuses the file (`crates/ffi/src/persist.rs`), which is a one-time loss, announced the way the previous break was (`docs/dogfood/DOGFOOD.md`). |
| Development rebuild | Only while the bundle id and signing identity hold still | Keychain ACL identity is derived from the bundle id (ADR-0012), and a `.debug` suffix or a changed `CODESIGN_IDENTITY` strands the halves. That lands in section 7's unavailable-key case: no restore, no overwrite, no writes for the session. Separately, `swift build` re-signs the bundle in place and the running instance is SIGKILLed (observed in development; nothing in the tree enforces or prevents it), so a rebuild against a live app is a force termination carrying the section 2 window. |
| Logout | Yes | The process dies by sudden termination unless a write is owed. The latch is real and refcounted (PageModel.swift) and the shipping bundle declares `NSSupportsSuddenTermination` (`shell/OnetimePad-Info.plist`), so a dirty buffer blocks the fast path and the terminate flush runs. A mutation that never called `markDirty()` is not covered: pasteboard copy-out is exactly that case today and is filed as issue #52 (PageModel.swift). |
| Fast user switching | Yes | No process death, no window at all. The other account cannot read anything: the state directory sits under the user's own Application Support (`shell/Sources/CompanionKit/FormFactor.swift`), the key halves are written 0600 (`crates/ffi/src/persist.rs`), and the keychain half is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on an entitled build (`crates/credentials/src/lib.rs`). |
| Power loss | Yes, on the same footing as the restart row now that ending the boot session no longer discards the file | Same window as crash, plus one artifact: a death between `create_new` and `rename` strands a complete sealed generation as `state.sealed.<hex>.tmp` (`crates/ffi/src/persist.rs`). Launch sweeps those, and only those (`launch_sweeps_the_temp_generations_a_crash_stranded`, `crates/ffi/src/lib.rs`); what the sweep is allowed to touch is `the_sweep_takes_stranded_temp_generations_and_nothing_else` (`crates/ffi/src/persist.rs`). |

Content survives everything except the debounce window. That window is
not the debounce interval ADR-0012 names; after a refused write it is
five times longer and open-ended under a modal, as section 2 sets out.

### 2. The loss window, stated as a tradeoff

The nominal window is 2.0 seconds, measured from the **first** mutation
of a burst, not the last (`shell/Sources/CompanionKit/PageModel.swift`). That anchoring is deliberate and correct: a trailing debounce
restarted per keystroke makes the window unbounded for the one case
persistence exists for.

The window after a refused write is 10.0 seconds, not 2
(PageModel.swift). It is worse than a longer retry interval
suggests, for two reasons recorded in `docs/plans/44-ground-truth.md`
section 2:

- `SaveSchedule.arm()` returns nil while a write is pending
  (PageModel.swift), so every mutation during the retry interval
  is absorbed into the already-armed retry rather than arming a fresh
  2 second timer. One refusal silently changes the window for everything
  typed afterwards.
- The retry runs in `.default` run-loop mode (armed at
  PageModel.swift, through `scheduleSave`), deliberately,
  so it cannot fire underneath the quit alert's modal and make its text
  false. The cost is that the retry
  cannot fire while any tracked menu or modal is up, so the window is
  open-ended for as long as one is.

The user is now told all of this (issue #49). A withheld licence raises
a standing banner on the surface with the one recovery action
(`shell/Sources/CompanionKit/PageSurface.swift`,
`contentRestoreRefused` at PageModel.swift), the header carries
the write lifecycle as a word, saving, saved or save failed
(`SaveStatus` at PageModel.swift, moved in `markDirty` and
`saveState`), and the quit path warns on both loud outcomes: a refused
write, and a settled flush over a withheld licence with work in the
session (`quitOutcome` at PageModel.swift,
`QuitPrompt.forOutcome` at CompanionKit/QuitPrompt.swift,
BackdropApp.swift). `saveState()` still sets `saved = true` on
the withheld-licence leg (PageModel.swift), so `settled` stays
true there; the standing state is what carries the story, not the
write's return value.

The tradeoff is accepted as stated, and the number does not move.
Shortening the debounce multiplies on-disk ciphertext generations, and
each rename unlinks rather than erases the prior one (ADR-0012), which
matters more under this ADR than it did under ADR-0012 because reboot no
longer makes those generations undecryptable. The compensation is
visibility, not a smaller number.

**Required work, done.** Issue #49 (surface a withheld licence and a
refused write) landed first, as above. Issue #46 (⌘S force-save riding
the same status surface) rides `saveState()` directly
(`shell/Sources/CompanionKit/PageSurface.swift`), the same call
the debounce timer and the quit path make, so a press asks for nothing
the write lifecycle does not already do on its own, only for it now.
Under ADR-0012 a silently withheld save licence cost one boot session;
under this ADR it would have cost every page until the user noticed,
which is why #49 was a precondition of this ADR rather than a
follow-up.

### 3. Key availability across a restart

**Required work.** The second half stops folding `current_boot_uuid()`
into its filename (`crates/ffi/src/persist.rs`) and moves out of
`_CS_DARWIN_USER_TEMP_DIR` (`crates/ffi/src/persist.rs`) into the app support state directory beside `state.sealed`. That threads the state
path into `persist`, which derives its own directory today. Call it the
file half, not the boot half; nothing about it is per-boot any more. The
name stays an HKDF output under the keychain half, keyed by
`FILE_HALF_NAME_INFO` (`crates/ffi/src/persist.rs`) with
`FILE_HALF_NAME_SALT` as the salt. Only the appended
`current_boot_uuid()` leaves that salt; the info string and
the salt constant are unchanged, because that derivation is also what
keeps two form factors out of each other's half
(`crates/ffi/src/persist.rs`). In its new home it inherits the
directory's `.noindex` naming and `isExcludedFromBackup`
(`shell/Sources/CompanionKit/FormFactor.swift`) and
`write_private`'s 0600 mode and atomic replace
(`crates/ffi/src/persist.rs`).

**The keychain half's protection class does not change, and nothing in
`crates/credentials` changes.** What the half buys does change, and
smaller, so state it. ADR-0012 could say an extracted keychain item
was useless once its per-boot partner was gone; with both halves durable
the split bounds nothing in time. It still buys two things. The
ACL gate: a process running as the user that reads the 0600 file half
will derive nothing without passing the keychain. And separation of backup
domains: the state directory is excluded from Time Machine
(`shell/Sources/CompanionKit/FormFactor.swift`) and the keychain
database is not, so neither a backup nor a copy of the state directory
yields a key on its own.

The class itself stays `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
with `kSecUseDataProtectionKeychain` on an entitled build
(`crates/credentials/src/lib.rs`). On every build this tree
currently produces the half is instead a login keychain item with no
protection class at all: the `DefaultFile` add scope sets no
`kSecAttrAccessible` (`crates/credentials/src/lib.rs`), and no
build here carries the entitlement
(`scripts/package-app.sh`, `scripts/local.env`). The lock
gate today is therefore the login keychain's, and the reasoning below
describes the entitled build only.

The reason `WhenUnlocked` is enough is where the read happens. The only
caller of `loadStateIfNeeded()` is `BackdropModel.start()`
(`shell/Sources/OnetimePad/BackdropModel.swift`), and the key is
loaded from inside that restore
(`crates/ffi/src/lib.rs`,
`shell/Sources/CompanionKit/PageModel.swift`). `start()` runs when
the app launches, and the app launches either because the user opened it
or because `SMAppService.mainApp` started it as a login item
(`shell/Sources/CompanionKit/SettingsSections.swift`). Both are
after the user has logged in, which on macOS is after the device is
unlocked. A machine that has rebooted and not been unlocked is running no
instance of this app, so there is no read for a weaker accessibility
class to rescue. `WhenUnlocked` is satisfied at every point the app can
ask.

`ThisDeviceOnly` also stays, and matters more now than it did: it keeps a
half that is durable across boots out of iCloud Keychain.

### 4. Aging across a restart, on two clocks

**The invariant this decision establishes, all of it Required work: the
countdown never rewinds. No restore of the file the app itself last wrote
returns a page with more life than it held at that save. A file rolled
back by someone else sits outside this invariant and is priced in
section 8.**

**Required work.** Two clocks, each measuring only the interval it can
measure honestly.

1. **Within a running session, nothing changes.** Every interval the
   process observes is charged on the sleep-inclusive monotonic clock
   (`crates/core/src/clock.rs`), which the live timer already
   reads through `companion_next_event_ms`
   (`shell/Sources/CompanionKit/PageModel.swift`). That clock
   is not settable, so a clock step mid-session buys nothing. ADR-0012
   is therefore narrowed rather than replaced: monotonic stays
   authoritative for every interval the process observes.
2. **Wall clock measures only the gap the process did not observe,**
   which is the interval between the last save and the next restore:
   `away = wall_now.saturating_sub(sealed_wall_ms)`. Nothing else in the
   lifetime math reads the calendar clock. The content path holds two
   other wall-clock readers and neither ages a page: `created_wall_ms` at
   page birth (`crates/core/src/store.rs`), which names a page, and
   the block stamps written into the same sealed file as wall seconds
   (`crates/core/src/persist.rs`), from which nothing derives a
   deadline. `saturating_sub` is what makes a backward gap read as zero
   rather than as a credit (`crates/core/src/persist.rs`).
3. **Elapsed life crosses the file as the life that is left, plus the
   stamp that ages it.** *(Amended 2026-08-23, from a specified
   `drained_ms` field to the encoding that shipped; the paragraph after
   this one records why.)* Each page record writes the span it has left,
   the running one (`crates/core/src/persist.rs`) or, for a held
   clock, the hold's own span and the frozen remaining,
   because a held clock is a suspended drain and not a drained one. The
   file carries `sealed_wall_ms` in its authenticated header. Restore
   charges the gap against a live hold first: a gap shorter than the
   remaining hold shortens the hold and leaves the frozen life alone, and
   only the part beyond the hold reaches the countdown
   (`crates/core/src/persist.rs`). What reaches it is subtracted
   and never added: `deadline = now + remaining.saturating_sub(away)`,
   with `away` already floored at zero, so no restore hands life back and
   the never-rewind invariant this section opens with is a property of
   the arithmetic rather than of a rule about a field. Every span read
   back is bounded. Life is bounded by the rung of the tab that holds the
   page (`:859`, the rung threaded in), so a file
   cannot claim more life than the ladder allows however it was edited.
   A hold is bounded by the ceiling the pause gesture itself sets, one
   hour for a first hold and 24 for one already topped up (against `crates/core/src/store.rs` and), because a held
   countdown does not run: a hold believed at face value would keep a
   page's plaintext for as long as the file cared to claim, on any rung. The one exception is not
   a clock effect: a deliberate TTL rung click sets the deadline to the
   rung's full duration, which is the user's own instruction
   (`crates/core/src/ttl.rs`).

   **The `drained_ms` field this bullet used to specify is not built.**
   The two encodings are the same number read from opposite ends,
   `drained = rung - remaining`, and every guarantee section 10 asks for
   follows from either: the gap drains by the gap and by nothing else
   (`crates/core/src/persist.rs`, `time_away_drains_the_countdown`), a
   hold absorbs it first and only the excess is charged
   (`a_hold_absorbs_time_away_before_the_countdown_drains`), a backward
   clock neither drains nor credits
   (`a_backwards_wall_clock_grants_no_extra_life`), and the ladder's
   ceiling holds (`no_restored_page_comes_back_holding_more_life_than_its_rung`,
   `no_restored_hold_freezes_more_life_than_its_rung`). What the field
   would have cost is a third content format break on top of the two
   section 9 already spends, and every one of those breaks is a user
   losing staged pages. The single thing it bought that the stored span
   does not get for free is the rung ceiling as a structural property;
   that is bought instead by clamping the span against the rung on the
   way in, at the same cost as one `min`. Section 8's residual is priced
   against the span accordingly: the span is the number a replayed or
   hand-edited generation can move, and the rung is what bounds the
   move.

Where `sealed_wall_ms` is persisted: in the authenticated header of
`state.sealed`, in the field the header carried as `wall_ms` and now
carries under its own name (`sealed_wall_ms` at
`crates/ffi/src/persist.rs`, written, read),
handed back as `Opened::Plaintext { sealed_wall_ms }` (constructed), and therefore inside the AEAD associated data. It is not in `UserDefaults` and not in a third file: it
decides how long a secret lives, so it must be as hard to edit as the
ciphertext it ages, and it is needed at exactly one moment, the restore
of a file that exists. Being inside the file makes it unforgeable and
leaves it replayable, because a stamp cannot detect the rollback of the
file that carries it. Section 8 records that as accepted residual
exposure.

There is no missing-or-corrupt case that also authenticates.
`sealed_wall_ms` is a fixed-width field inside the associated data, so a
file with a damaged or absent stamp fails `StateHeader::parse` or fails
the AEAD and opens as `Opened::Refused`
(`crates/ffi/src/persist.rs`), which is section 7's
damaged snapshot: no restore, no overwrite. A stamp that authenticates
and sits far in the past, whether because the file is genuinely old or
because the clock read early at the save, drains everything, which costs
life and is therefore allowed to happen silently. A stamp ahead of the
current wall clock produces a zero gap under `saturating_sub`, so
nothing is taken off the span the page carries and it comes back holding
exactly the life it held at that save. Nothing is credited and nothing is charged.
That is the same accepted freeze the next paragraph prices, not a
separate failure, and it is allowed to happen silently for the same
reason.

**What this is worth, stated plainly.** The countdown never rewinds.
Within a session, elapsed time is charged on a clock the user cannot set.
Across a restart the gap is measured by wall clock, so a user who steps
the system clock back and then restarts can freeze the countdown for that
gap. That case is accepted, not defended, because a user who can set the
machine's clock is a user who already has the plaintext on screen. The
TTL is a hygiene bound on an honestly running machine, not a defense
against the machine's own operator.

The tree's existing direction was kept in half and dropped in half.
`monotonic_away_ms` charged the ceiling for a stamp that read later than
now; wall-clock aging charges zero for that same case, because
`saturating_sub` floors at zero, and the function it replaced it with is
`wall_away_ms` (`crates/ffi/src/lib.rs`). What survives is
the never-credit half: a restore only ever subtracts from the span a
page carries, so no restore hands life back. What is dropped is that
function's stated absolute, "Granting life past a page's TTL is the
one outcome that must be impossible", which the paragraph above prices.

### 5. The reboot trap in the restore path

State this separately so nobody reimplements it.

Removing the boot check was not sufficient. Restore used to hand the
core `saved_wall_ms.saturating_add(away_ms)` where
`away_ms = monotonic_away_ms(sleep_inclusive_ns(), saved_mono_ns)`, and
both readings came from a clock that restarts at reboot. After a
restart, `sleep_inclusive_ns()` was small and `saved_mono_ns` was large,
`checked_sub` returned `None`, `away_ms` became `u64::MAX`, and the core
drained every countdown the instant the surface opened.

The failure is silent and it presents as success. `persistRestore`
returns true, the save licence is granted, the ledger fills with
`expired` records, and the pad is empty. To the user it reads as "restore
worked, everything had expired." To a test that only asserts
`persistRestore == true` it reads as a pass.

**Required work, done.** The restore path no longer calls
`monotonic_away_ms`, which is gone from the tree along with
`saved_mono_ns`, dropped from the header in the same format break as the
boot field (section 9). Time away is
`wall_now.saturating_sub(sealed_wall_ms)` per section 4, computed by
`wall_away_ms` (`crates/ffi/src/lib.rs`) and applied on the restore
path. The test this section made mandatory is
`a_restart_leaves_the_pages_alive_and_drains_them_by_the_gap`
(`crates/ffi/src/lib.rs`), which seals a snapshot five minutes in
the past, restores it on a second handle, and asserts both that the
pages are still there and that they drained by the gap and by nothing
else.

### 6. Key rotation once `BootMismatch` is gone

`rotate_key_halves` had one caller, the `BootMismatch` arm, and this
decision deleted it. Rotation therefore needed a new trigger or it left
the design.

**Required work.** Both halves rotate on exactly two events:

1. **The pad empties, which means no tab holds a page.** None of the
   machinery below exists today.

   The definition is load-bearing because ADR-0017 rides the same break.
   The condition used to be `client.sheets().isEmpty`, the page vector's
   own emptiness, and meeting it dropped the content file rather than
   resealing it. It is now two predicates the core answers in one call,
   `holdsNoPage` and `hasNoTabs` (`crates/core/src/store.rs` and, read at `shell/Sources/CompanionKit/PageModel.swift` and
   used and), and only the second drops the file.
   Dropping on the first stopped being available:
   the same sealed file will carry the durable tab names, rungs and strip
   order, and a tab survives its page (ADR-0017), so an expiry that
   empties the pages would destroy the tabs along with them.

   So while no tab holds a page, the write of the sealed file rotates
   both halves and reseals the surviving tab metadata under the new
   ones. A rotate plus a reseal, not a drop. That is what keeps the
   forgetting claim true: every prior ciphertext generation, including
   the unlinked ones, becomes undecryptable at the moment the pad holds
   no content. As built, the sufficient deletion is the file half's:
   rotation erases every file half in the state directory with the same
   zero, truncate, sync and unlink the ciphertext gets, without reading
   the keychain, and the answer it reports rests on that erasure alone
   (`rotate_key_halves` and `erase_file_halves` in
   `crates/ffi/src/persist.rs`). The keychain half is then deleted for
   hygiene, announced but never decisive. Neither step does anything to
   a half an attacker copied earlier. Dropping the file while leaving
   both halves alive is what let the old design reuse a key across
   boots, which is why the rotation and not the deletion is the
   mechanism.

   **On the state, not the transition.** The shell asks "does the pad
   hold no page right now" on every save, never "did it just become
   so" (`PageModel.rotatesContentKey`). A latch that remembered whether
   the last write had already rotated would be a second source of truth
   about what is on disk, and it would be wrong in exactly the case
   that matters, a write that failed after the rotation landed. The
   price is per write rather than per emptying: every save that runs
   while the pad stays empty rotates again, so a persistently failing
   ledger write that rearms the ten second retry spends a keychain
   write and a generation of tab names on each attempt. Each repeat is
   another forgetting rather than a leak, which is why the price is
   accepted.

   The file is dropped outright, as today, only when no tabs remain at
   all.

   **The rejected alternative** was defining empty as "no tabs". It was
   rejected because a user who keeps tabs around would almost never fire
   the trigger, so the pad could hold one content key for the life of the
   install and this ADR's claim that an emptied pad is a forgetting would
   quietly stop being true.

   **The honest cost:** the reseal writes a new ciphertext generation
   under the new halves. It carries tab names only and no page content,
   but it is a generation, and the rename that installs it unlinks the
   previous one rather than erasing it (ADR-0012). The rotation has to
   complete before the reseal, so that the generation left behind is
   already undecryptable when it is unlinked.

2. **Explicit Clear.** The content side now has one, issue #49's
   discard (`clearUnreadableStateFile`,
   `shell/Sources/CompanionKit/PageModel.swift`, the licence
   re-grant through `licencesAfterContentClear`),
   mirroring the ledger's
   (`shell/Sources/CompanionKit/PageModel.swift`, the licence
   re-grant). Section 7 requires it for a second
   reason, and it is the same gesture.

The file half had to go with the state file, which was not so when the
half died with the boot session. It does, and the step sits in the
caller rather than inside `erase_state`: `companion_persist_erase` runs
`drop_takes_the_content_key` and then `rotate_key_halves`, which erases
every file half in the directory, before it unlinks anything
(`crates/ffi/src/lib.rs`, over `erase_state` at
`crates/ffi/src/persist.rs` and `erase_file_halves`), and
it refuses to unlink at all when the half survives. Pinned by
`dropping_the_content_file_rotates_the_halves_with_it`
(`crates/ffi/src/lib.rs`) and
`a_content_file_the_core_cannot_read_still_takes_the_key_with_it`.

**What is lost by rotating less often than once per boot.** An install
that always holds at least one page keeps one content key for the life of
the install, bounded only by the keychain ACL identity changing
(ADR-0012). Crypto-erasure stops being a scheduled event and becomes
the finishing step of a deletion the user or the TTL asked for. Concretely:
a ciphertext generation captured by a backup or an APFS local snapshot,
together with a captured pair of halves, stays decryptable until the user
empties the pad or clears it, where previously it stopped being
decryptable at the next reboot. Section 8 carries this into the
consequences.

### 7. Recovery guarantees

**The binding rule: a failed restore must never replace prior persisted
state with empty state.** Every case below satisfies it through the save
licence rather than through a second copy. All four hold, the third one
unconditionally now that the `BootMismatch` arm that used to rotate and
erase an earlier session's file before the key was ever asked for has
been deleted.

| Failure | What happens | Citation |
|---|---|---|
| Snapshot fails authentication (tampered, truncated, wrong key, superseded magic) | `Opened::Refused`, restore returns false. The file is still on disk when the probe runs, so `grantsSaveLicence(fileExists: true, restored: false)` is false and the session may not write over it. A working page opens; nothing is destroyed. | `crates/ffi/src/persist.rs`, `crates/ffi/src/lib.rs`, `shell/Sources/CompanionKit/PageModel.swift` |
| Snapshot authenticates but the core rejects the payload | `diag_fault` names it as the one refusal that survives a fresh keychain, restore returns false, same licence outcome, file untouched. | `crates/ffi/src/lib.rs` |
| Key unavailable (locked keychain, denied ACL, changed bundle id or signing identity) | `load_key_for` returns `None`, the file opens as refused, same licence outcome, file untouched. Rotation is not attempted, so nothing is deleted on the way past. This held only for a file the current boot session had sealed until the boot check ahead of the key closure was deleted; it is unconditional now, asserted end to end by `a_locked_keychain_refuses_the_restore_and_leaves_the_directory_alone`. | `crates/ffi/src/persist.rs`, `crates/ffi/src/lib.rs` |
| `sealed_wall_ms` missing or corrupt | Not separable from the first row: the stamp lives in the associated data. | section 4 |

The cost of that rule is the session: a refusal withholds the content
licence for the whole run, and the one thing that clears it is the
user's own discard on the banner the refusal raises
(`clearUnreadableStateFile`,
`shell/Sources/CompanionKit/PageModel.swift`). Under ADR-0012
that cost ended at the next reboot, because the boot mismatch arm
dropped the offending file. Under this ADR nothing ever drops it
unbidden, so the withholding lasts until the user acts, and issue #49's
surfacing is what makes sure they can.

**Decision on a last-known-good generation: not required, and not built.**
The app cannot produce a torn state file; every write lands whole or not
at all (`crates/ffi/src/persist.rs`). The realistic failures
above are key-shaped or format-shaped, and a retained previous generation
is sealed under the same key and the same format, so it fails identically.
A `.prev` copy would buy recovery only for external corruption of the
current file, and it would pay for that with a second named ciphertext
copy under a key that is now durable, which is precisely the exposure
section 8 is already conceding. Refusal is the guarantee; a second copy is
not.

**Required work,** in place of it, all landed:

- A content-side Clear that discards the unreadable file and re-grants
  the licence, mirroring the ledger's Clear-based re-grant: issue #49's
  discard (`clearUnreadableStateFile`,
  `shell/Sources/CompanionKit/PageModel.swift`,
  `licencesAfterContentClear`). Without it the
  withholding was permanent by construction, since nothing else removes
  the file.
- Issue #49's surfacing, so the user learns the session is not writing
  at the moment it stops writing rather than at the moment they lose a
  week: the standing banner with the discard action
  (`shell/Sources/CompanionKit/PageSurface.swift`), the header's
  write-lifecycle word, and the quit warning over a withheld licence
  with work in the session (`quitOutcome` at PageModel.swift,
  `shell/Sources/CompanionKit/QuitPrompt.swift`,
  `shell/Sources/OnetimePad/BackdropApp.swift`).
- The superseded-magic disposal path from section 9, so the one-time
  format break does not present as a permanently unwritable install.

### 8. What is honestly given up

The three redrafts below state ADR-0012's consequences as they read now
that this decision's Required work has landed; the citations in them
mark the code each claim rests on.

**Retracted.** ADR-0012, "Crypto-erasure at reboot is the primary
mechanism", is withdrawn. So is the public form of it in
`docs/dogfood/DOGFOOD.md`, "Staged content no longer survives a reboot,
by design." Under ADR-0007's rules that is a claim change, so the
wording was replaced rather than quietly dropped, and the retraction now
reads in place in that document's ADR-0012 reset section.

**The replacement claim.** Staged content is bounded by its TTL and by
policy, not by the boot session. Nothing outlives its TTL, the ceiling is
the ladder's top rung at seven days (`crates/core/src/ttl.rs`), and crypto-erasure is what finishes a deletion that the
TTL, an emptied pad, or an explicit Clear has already decided. Content
forgets on schedule, not at reboot.

**Redraft of ADR-0012.** A ciphertext artifact exists on disk
continuously from the first save until the last tab is closed. The pad
emptying of pages does not remove it, because the same file carries the
durable tabs: section 6 rotates both halves at that transition and
reseals the surviving tab metadata, so what sits on disk afterwards is a
fresh generation holding tab names and no page content, and every
generation that ever held content is undecryptable from that moment.
Alongside it are unlinked prior generations until APFS reclaims them,
plus any stranded `.tmp` generation from a death mid-write
(`crates/ffi/src/persist.rs`), and, now that the file half is
written through the same function into the same directory, any stranded
`.tmp` copy of a key half. `erase_state` removes neither, because it
unlinks only the exact path it is given
(`crates/ffi/src/persist.rs`), and unlike the temp directory this
one is never cleared at boot. Required work: sweep `*.tmp` in the state
directory at launch. Both key halves are durable across boot sessions:
one in the keychain under the app's ACL, one at 0600 in the state
directory. The file is unreadable without both halves. Both halves are
replaced on each of section 6's two triggers, the pad emptying of pages
and an explicit Clear, and the old pair is deleted when they are. A
change of keychain ACL identity removes nothing: the keychain item
survives and only stops being readable by the new code identity
(ADR-0012), and the file half in the state directory is untouched,
which is section 7's unavailable-key row. That event ends this install's
access without ending the material's readability for anyone holding both
halves.

**Redraft of ADR-0012.** The audit story is one small module that
writes secret ciphertext, one derivation of two key halves, and **one**
mechanical check rather than two: the TTL, measured against a per-page
span that no restore lengthens, bounded by the ceilings of section 4, and
a wall stamp inside the authenticated header. The boot session UUID check is gone. The ledger is
content-free by construction except the capped, user-visible title field,
unchanged.

**Redraft of ADR-0012, accepted residual exposure.** Everything
ADR-0012 listed, plus: durable ciphertext across boot sessions for up to
the seven day ceiling, and durable key halves for as long as the pad
holds at least one page, which section 6 bounds only by the user emptying
or clearing it and by the keychain ACL identity changing; and any copy of the
ciphertext taken together with a copy of both halves, by a backup, an
APFS local snapshot, or a forensic image, stays usable forever. Rotating
the live halves deletes the app's copies and does nothing to a pair
already captured, so the bound on a captured copy is the moment of
capture, not the life of the halves on this machine. The state directory
is excluded from Time Machine and Spotlight
(`shell/Sources/CompanionKit/FormFactor.swift`), which closes one
channel and not the volume-snapshot channel. **Reverting this decision
later does not retroactively kill a half that was durable while it was
captured.** That asymmetry is the reason this section exists.

**Rollback of the state file, accepted.** Removing the boot field removes
the only thing that ever made a previous generation of `state.sealed`
refuse to open, and it only ever refused one from an earlier boot
session: that file took the `BootMismatch` arm and was rotated and
erased. Within a single boot session the
replay below already works against the current tree. Nothing replaces the
check, so the exposure stops being bounded by the next reboot. Any
process running as the user can copy `state.sealed` aside, wait
for the pages inside to be discarded or to expire, and copy the older
generation back; it authenticates under the same durable key, and a stamp
stored inside the file it protects cannot detect the rollback of that
file. This is accepted, but not on the clock case's argument, which does
not apply here. The replay adversary is any process running as the
user, which is this paragraph's own phrasing above. Such a process can
swap the 0600 `state.sealed`
(`crates/ffi/src/persist.rs`), and it cannot read the
plaintext out of the running app for the asking: `task_for_pid` is gated
and screen capture is permissioned. It does not learn the key either,
which needs the keychain half from behind the ACL. What it gets is the
app resurrecting and displaying content the ledger recorded as dead.
That is accepted for two reasons. Defending it means an anti-rollback
counter in the ACL-gated keychain item, which costs one keychain write
per save on a debounce that fires every two seconds while someone types.
And the same process can copy `state.sealed` aside at any moment
regardless, so the rollback hands it no artifact it could not already
hold.

State the residual exposure next to ADR-0012's without ranking them.
ADR-0012 keeps content-derived titles, capped at eighty characters
(ADR-0012), under a long-lived never-rotated key for a rolling ninety
days, and calls that a bound an auditor can state in one sentence. This
decision keeps full page bodies under a long-lived key for the life of
the page, at most seven days, plus the unlinked and stranded generations
this section already says nothing sweeps. Larger per byte, shorter per
calendar, both behind the same keychain ACL. The reader can weigh that.

**Required work.** `docs/dogfood/DOGFOOD.md` is rewritten and `README.md` and
`SECURITY.md` are audited for erasure-at-reboot language before this
ships.

### 9. Migration: one format break, taken deliberately

`FILE_MAGIC` bumps from `OTSSEAL2` to `OTSSEAL3`
(`crates/ffi/src/persist.rs`). The header loses `boot_uuid[16]` (section 3) and `mono_ns[8]` (section 5),
leaving `magic[8] ‖ sealed_wall_ms[8]`. `STATE_HEADER_LEN` therefore
changes (`crates/ffi/src/persist.rs`), and since the whole header
is the AEAD associated data (`crates/ffi/src/persist.rs`), every
existing `state.sealed` fails authentication. The snapshot's own `MAGIC`
bumps from `OTSSNAP3` to `OTSSNAP4` (`crates/core/src/persist.rs`) in
the same break, and it carries one cause where this decision expected
two. Issue #54 gives every repeated record its own length prefix
(`crates/core/src/persist.rs`), and #54 landed first and took the
bump. The page record's clock was to have been the second cause, but the
`drained_ms` field section 4 specified was not built: the record still
writes the span that is left, running (`crates/core/src/persist.rs`)
or frozen behind a hold, so the clock encoding asked for no
version of its own. This decision rides #54's bump rather than spending a
second one.

**The ledger payload magic breaks in the same release, and it did not
have to.** `LEDGER_MAGIC` goes `OTSLEDR1` to `OTSLEDR2`
(`crates/core/src/persist.rs`), because the ledger record is framed
under the same rule as the content records. Nothing else
about the ledger changes: `LedgerRecord` is unchanged, the file keeps its
own envelope magic (`crates/ffi/src/persist.rs`) and its own
long-lived key (`crates/ffi/src/persist.rs`), and the `OTSSEAL3`
bump reaches neither. The ledger file would have sat out this break;
framing its records is what breaks it. The cost is the retained history:
the capped titles and the event records, back to the ninety day retention
window, destroyed once, in this release, alongside the staged content. It
is accepted so the module carries one encoding rule rather than two, and
so a later per-record field costs the ledger nothing. A superseded ledger
magic refuses as unknown format, tested alongside the content magics
(`crates/core/src/persist.rs`).

**There is no migration path and none is possible.** An `OTSSEAL2` file's
key derives from a half in the temp directory that the restart already
cleared, and even in-session the changed associated data makes the bytes
unauthenticatable. Users lose whatever is staged, once, and the retained
ledger history with it. This is the
second announced break (`docs/dogfood/DOGFOOD.md` announced the first, in which
the envelope and the snapshot each took a version byte at once) and it is
announced the same way.

**Required work.** A file whose magic is a *known superseded* version is
erased and the licence is granted, rather than left as a refusal. The
known superseded set at this break is exactly one entry, `OTSSEAL2`, and
it grows by one entry per future break. `OTSSEAL1` stays out of it: it is
refused outright today (`crates/ffi/src/persist.rs`) and this
break does not change that. "Erased" here is `erase_state`'s discipline,
zero the bytes, truncate, unlink, and confirm the absence
(`crates/ffi/src/persist.rs`), not a plain unlink, because the
file being discarded is a full ciphertext generation of staged content.
Without this, the first launch after the update presents as an install
that has permanently stopped saving, which is the exact failure Amendment
2026-08-10 was written about (ADR-0012). Nothing is written to the
ledger for the discarded pages: a superseded magic fails
`StateHeader::parse`, so the file is never decrypted and the UUIDs inside
it are unknowable (`crates/ffi/src/persist.rs`,
`crates/ffi/src/lib.rs`).

**Required work.** The same question exists one layer down, for a known
superseded *ledger payload* magic, and the paragraph above does not
answer it. The envelope's superseded magic never decrypts. An `OTSLEDR1`
file authenticates and opens under the unchanged envelope and the
unchanged key, and is then refused inside `restore_ledger`
(`crates/core/src/persist.rs`). The seam reports that as a failed
restore (`crates/ffi/src/lib.rs`), the file is still on disk
when the probe runs, so the ledger licence is withheld for the session
(`shell/Sources/CompanionKit/PageModel.swift`), and it is
withheld again on every later launch, because nothing removes that file
except the user's own Clear, which the log line already names as the only way out. Every install carrying a
ledger file meets this on first launch after the release. So a known
superseded ledger payload magic is disposed of and the ledger licence
granted, on the rule this section already sets for the envelope. The
known superseded set is exactly one entry, `OTSLEDR1`. The disposal is
layered the way the envelope's is, one level down (issue #61): the core
owns the magic, so it names the refusal, `RestoreError::Superseded` for
an entry of `SUPERSEDED_LEDGER_MAGICS` (`crates/core/src/persist.rs`), and the seam owns the file, so it erases it with
`erase_state`'s discipline and reports the restore as failed
(`crates/ffi/src/lib.rs`); the probe then finds no file and grants
the licence, exactly as after the envelope's `Superseded`. The ledger
key is not rotated: the file was authentic under it, the user's Clear
does not rotate it either, and a rotation at launch is the Keychain
prompt ADR-0004 forbids. Nothing is written to the ledger about the
records dropped. Salvage is not on the table: there is no reader for a
superseded version and no downgrade writer
(`crates/core/src/persist.rs`).

**[ADR-0017](../adr/0017-durable-tabs-expiring-pages.md), "Durable tabs,
expiring pages", rides this same break, deliberately.** The split
(`docs/dogfood/ABERRATIONS.md`) moves page metadata onto a Tab object
and therefore changes the persisted object graph, which no compatibility
rule absorbs. Taking it in a second break would cost users their staged
content twice, so it ships in this `FILE_MAGIC` bump or it waits for the
next one.

ADR-0013's interaction count is the other pending obligation on this
format, declared not derivable from the op log and implemented nowhere
today (`crates/core/src/persist.rs` writes `created_s`,
`modified_s` and `origin` and no count; recorded at
`docs/plans/44-ground-truth.md`). It is a trailing field, so the rule
immediately below releases it from this break: it can land whenever
ADR-0013 is implemented, at no cost to anyone's staged content.

**The snapshot's records are self-describing as of this break.** They
were positional, and
[issue #54](https://github.com/onetimesecret/macos/issues/54) gave each
repeated record its own byte length in front of its fields
(`crates/core/src/persist.rs`): the page record, the chip
records inside it, the materialized block record and the
ledger record. Four kinds, not the three #54 named. The chips
were taken in deliberately, so the rule has no exception inside the
module and a later per-chip field costs no break either. A reader
consumes the fields it knows and then reaches the next record by that
record's length rather than by where its own field walk stopped, so a file written by a build that added a trailing field
still reads here, minus the field this build has never heard of. One test
per record kind holds the rule (`:2021`). Full
tag-length-value encoding is rejected in #54, because it puts a parser
inside the one module ADR-0012 stakes the audit story on.

**What the rule does not buy.** A field that moved, changed width or
changed meaning is not a trailing field and still costs a new magic, and
so does anything outside a record: the magics, the counts, and the
sections that trail a record list. A new magic still refuses every
existing file, and a tail after the last record is still damage, because
it sits outside every frame and nothing states how long it is
(`crates/core/src/persist.rs`).

The envelope does not follow. Its header is associated data in full
(`crates/ffi/src/persist.rs`), so anything added there changes what
authenticates, and an unknown envelope magic must keep failing closed. Extensibility belongs in the payload.

### 10. Required test coverage

Mapped to the seven cases in issue #48. This was written as work owed
and now reads as work done: every case's automated half landed, and what
each case has rather than what it owed is inventoried in
`docs/qa/recovery-matrix.md`, which cites tests by name so a rename is
found with `grep` instead of by a reader trusting a line number. The
table below keeps the reasoning, the deletions this decision required,
and the hardware column, which is the part no test reaches.
`docs/qa/verification-procedures/` holds the six procedures below plus
one about drag tracking; whether any of them has been run is recorded in
that file's own Status line and Results table.

| # | Case | CI | Hardware procedure |
|---|---|---|---|
| 1 | Clean quit | Covered end to end. The Rust round trip is `persist_round_trips_over_the_seam` (`crates/ffi/src/lib.rs`) over `round_trip_preserves_pages_chips_and_titles` (`crates/core/src/persist.rs`). The Swift test this row asked for landed once issue #53 gave `PageModel` its seams: `testTheQuitFlushWritesWhatTheDebounceStillHolds` (`shell/Tests/CompanionKitTests/PersistenceRoundTripTests.swift`) puts a mutation behind a debounce long enough that the timer cannot fire, flushes, and asserts the bytes moved in that same synchronous call and that the deferred body then stood down; the terminate delegate's own reply is pinned at `testTheReplyIsTakenFromTheModelsOwnFlush` (`shell/Tests/CompanionKitTests/QuitPromptTests.swift`). A regression removing the quit flush no longer passes CI green. | None |
| 2 | Crash or force termination | Covered, apart from the death itself. Atomic replace is `write_private_replaces_whole_and_cleans_up` (`crates/ffi/src/persist.rs`) and `concurrent_saves_never_land_a_torn_file`, and the stranded temporary generations a death mid-write leaves are swept at launch (`launch_sweeps_the_temp_generations_a_crash_stranded`, `crates/ffi/src/lib.rs`). The window and the latch remain value types, under `SaveScheduleTests` (`shell/Tests/CompanionKitTests/StateLicenceTests.swift`) and `SuddenTerminationLatchTests`. All three additions landed: every mutation site reaches `markDirty()` (`testEveryMutationSiteArmsAWrite`, `shell/Tests/CompanionKitTests/MutationArmingTests.swift`, over `testEveryLedgerAppendingMutationArmsAWrite`, `LedgerAppendArmingTests.swift`); the shipped plist still declares `NSSupportsSuddenTermination` (`testTheShippedPlistDeclaresSuddenTermination`, `shell/Tests/CompanionKitTests/BundleDeclarationTests.swift`, over `shell/OnetimePad-Info.plist`, with the same key read off the assembled bundle in CI); and the post-refusal window absorbs what follows (`testARefusedWriteOpensAWindowThatAbsorbsWhatFollows`, `shell/Tests/CompanionKitTests/RestoreFailureTests.swift`, with the arithmetic at `StateLicenceTests.swift`). | `force-termination.md`: `kill -9` mid-burst and again after a settled write, then relaunch and confirm what survived. Hardware only, because a process cannot watch itself be killed |
| 3 | macOS restart | Done, and the deletions this row required were taken. No `BootMismatch` arm, boot UUID or `sysctlbyname` call remains in `crates/`, so the discard and refusal assertions, the plumbing under them and the retry seam went with them. What stands in their place is the inverse guarantee, `a_file_that_will_not_open_is_left_exactly_where_it_is` (`crates/ffi/src/lib.rs`), which bends every header byte and asserts the file is left byte-identical and the key unrotated. The two half tests that rested on the same plumbing were rewritten as `a_missing_file_half_is_never_minted_on_restore` (`crates/ffi/src/persist.rs`) and `the_file_half_is_owner_only_and_sits_in_the_state_directory`. The rotation tests survived and gained section 6's two triggers: `rotate_key_halves_makes_a_sealed_file_unopenable`, `rotation_leaves_the_ledger_key_intact`, `resealing_an_emptied_pad_rotates_the_halves_and_keeps_the_strip` (`crates/ffi/src/lib.rs`) and `dropping_the_content_file_rotates_the_halves_with_it`. The mandatory section 5 test is `a_restart_leaves_the_pages_alive_and_drains_them_by_the_gap`, with the over-run leg at `a_gap_past_the_rung_expires_the_page_into_the_ledger`. The hold and the ceilings are `a_hold_absorbs_time_away_before_the_countdown_drains` (`crates/core/src/persist.rs`), `a_restored_hold_remembers_which_press_comes_next`, `no_restored_page_comes_back_holding_more_life_than_its_rung`, `no_restored_hold_freezes_more_life_than_its_rung` and `no_restored_hold_outlasts_the_ceiling_the_pause_gesture_sets`. | `reboot.md`: a real reboot with a live pad, a reboot with the pad emptied first confirming rotation ran, and a reboot with a page paused confirming it returns paused. Case 1 passed 2026-08-22; the other two are open |
| 4 | App update or dev rebuild | Covered. Format-version refusal is `a_v1_file_is_refused` (`crates/ffi/src/persist.rs`) and the disposal of a known superseded envelope `a_superseded_file_is_disposed_of_rather_than_refused`. At the seam: `a_superseded_state_file_is_dropped_so_the_session_can_write` (`crates/ffi/src/lib.rs`), `a_superseded_ledger_payload_is_dropped_so_the_session_can_record`, and the half this row never named, `an_unknown_envelope_is_refused_and_kept`, which is what keeps the disposal from becoming a licence to delete anything unreadable. The shell's reading of both is `testADroppedSupersededFileEarnsTheLicence` and `testAFileThatGenuinelyRefusedIsStillThereWhenTheProbeRuns` (`shell/Tests/CompanionKitTests/StateLicenceTests.swift`), and the dev-versus-release separation that keeps a rebuild off the installed copy's state is `testOnlyTheAppsOwnIdentifierAndOneDotFreeSuffixAreAdopted` (`shell/Tests/CompanionKitTests/FormFactorTests.swift`). | `re-signed-bundle.md`: re-signing with a different identity refuses without erasing, and the `.debug` bundle id keeps its own state directory. Hardware only, because CI cannot reach a real Keychain ACL |
| 5 | Damaged snapshot | Covered on both sides. Rust: `tampering_anywhere_fails_authentication` (`crates/ffi/src/persist.rs`), `header_fields_are_authenticated` and `the_wrong_key_opens_nothing`, with the core's own refusals at `wrong_magic_is_unknown_format_and_damage_is_malformed` (`crates/core/src/persist.rs`), `truncation_at_every_offset_rejects_without_panicking` and `a_hostile_length_is_rejected_before_it_allocates`. The Swift half landed with #53's seams: `testADamagedSnapshotWithholdsTheLicenceWithoutDroppingTheFile` (`shell/Tests/CompanionKitTests/RestoreFailureTests.swift`) bends a byte inside the ciphertext and leaves the magic intact, so the superseded-magic drop is deliberately not what fires, then asserts the licence is withheld, the file is unchanged across a mutation and a full debounce, and the user's own discard re-grants. | None |
| 6 | Unavailable encryption key | Covered as far as a test can reach. `a_missing_file_half_is_never_minted_on_restore` (`crates/ffi/src/persist.rs`) and `ensure_is_stable_and_load_never_mints` hold the never-mint line; the keychain doubles are `a_rotation_the_keychain_refused_still_forgot_the_content` and `a_rotation_against_a_keychain_that_answers_nothing_still_erases_the_half`; the end-to-end refusal is `a_locked_keychain_refuses_the_restore_and_leaves_the_directory_alone` (`crates/ffi/src/lib.rs`), and from the shell `testAForeignCredentialScopeCannotOpenTheFile` (`shell/Tests/CompanionKitTests/PersistenceRoundTripTests.swift`). All of it runs against `InMemoryCredentialStore` (`crates/credentials/src/lib.rs`) or a double, and the one real-keychain test is still `#[ignore]`d (`crates/credentials/src/lib.rs`). CI cannot lock a keychain. | `locked-keychain.md`: a locked keychain at load and a denied ACL prompt, each refusing with no erase and no overwrite. Hardware only, with the round trip at `docs/qa/hardware-verification.md` section C |
| 7 | TTL expiry | Covered, and the removals this row anticipated happened. `monotonic_away_ms` is gone from `crates/` along with the restore path that called it; two of its three seam tests were rewritten around `wall_away_ms` as `hours_of_wall_time_away_drain_hours_of_life` (`crates/ffi/src/lib.rs`) and `a_stamp_from_the_future_reads_as_no_time_away`, and the third, `time_away_is_measured_by_the_monotonic_stamp_not_the_calendar`, was deleted outright with no replacement, because its claim is now false. The stepped-back clock is `a_backwards_wall_clock_grants_no_extra_life` (`crates/core/src/persist.rs`); the stamp from the future is `a_stamp_from_the_future_freezes_the_countdown_rather_than_draining_it` (`crates/ffi/src/lib.rs`), asserted end to end through `companion_persist_restore` rather than in the arithmetic alone; the ceiling is held by case 3's rung clamps. Both original legs stand: `time_away_drains_the_countdown` (`crates/core/src/persist.rs`), `pages_due_while_away_expire_into_the_ledger_on_restore`, `expiry_is_scheduled_not_polled` (`crates/core/src/store.rs`) and `a_held_page_expires_only_after_hold_plus_frozen_life`. | `clock-step-back.md`: the machine clock stepped back a day with a live pad. Belt and braces rather than the only cover, since the arithmetic is pinned above; what it adds is the real system clock |

The hardware procedures this required now exist under
`docs/qa/verification-procedures/`, one for every hardware column of the
table above: `force-termination.md` (case 2), `reboot.md` (case 3),
`re-signed-bundle.md` (case 4), `locked-keychain.md` (case 6) and
`clock-step-back.md` (case 7), joined by `power-loss.md` for the
stranded temporary files of section 1. Each names delano as its owner
and carries a dated Results table; `reboot.md` records the only run so
far, of its first case. Every one of them starts from a rebuild and
reinstall through `scripts/install.sh`, because both format breaks in
section 9 landed and an older installed copy cannot read the files this
build writes. `docs/qa/hardware-verification.md` indexes all six, names an owner on each of its own sections, and carries a
Results table of its own, so a run is written down once, in
the document that holds the check it belongs to.
`docs/qa/recovery-matrix.md` maps each procedure back to the case it
closes and to the tests that cover the rest of that case, and it is the
file to edit when a test is renamed or a procedure is run.

## Consequences

- The failure that opened this milestone stops happening. Accepting a
  system update no longer costs the user their staged work.
- ADR-0011's ladder means what it says for the first time. The 3d and 7d
  rungs are reachable on a machine that reboots weekly, so no rung needs
  relabelling and the ladder does not change.
- Two live defects were deleted rather than fixed. A transient
  `sysctlbyname` failure used to substitute a per-process sentinel that
  turned the live session's own valid file into `BootMismatch` and
  destroyed it, which is issue #51; neither the sentinel nor the arm
  survives, and what holds the line in their place is
  `a_file_that_will_not_open_is_left_exactly_where_it_is`
  (`crates/ffi/src/lib.rs`), which requires a file that refuses to
  open to be left byte-identical with its key unrotated. Reboot deaths
  that left no ledger record stopped occurring because nothing dies
  undecryptable.
- Five exposures are accepted rather than engineered against, priced in
  sections 3, 4 and 8. Both key halves become durable across boot
  sessions, so an install that always holds a page keeps one content key
  for the life of the install. A ciphertext copied together with both
  halves stays decryptable forever, and rotating the live halves does
  nothing to a pair already captured. A change of keychain ACL identity
  deletes no key material; it ends this install's access and nothing
  else. A system clock stepped back across a restart freezes the
  countdown for that gap, and that adversary is the machine's own
  operator, who already has the plaintext on screen. An older
  `state.sealed` generation can be replayed by any process running as the
  user; that adversary gets neither the key nor the app's memory, it gets
  the app resurrecting content the ledger recorded as dead, and it is
  accepted on cost rather than on harmlessness (section 8).
- The keychain half stops bounding anything in time. With both halves
  durable it buys an ACL gate and separation of backup domains, and
  nothing more (section 3).
- Three preconditions were load-bearing and shipped with or before this,
  all now done: issue #49 (visible refusals), issue #46 (force save with
  status), and the content-side Clear from section 7. A silent withholding
  that cost one boot session under ADR-0012 costs seven days of work
  under this ADR.
- Issues #51, #52 and #53 are filed and are deliberately not fixed in this
  branch.
- The single-module audit story survives and gets shorter by one check
  (section 8), but the module grows a two-clock rule that a reader has to
  reason about rather than a UUID comparison they can read in a line.
  That is the complexity this decision buys the durability with.
- Going back to monotonic aging for content later requires another format
  break and another user-visible loss.

## Eject triggers

- A written threat model appears that requires crypto-erasure of staged
  content on a schedule shorter than the TTL. ADR-0012 asserted the
  requirement without one; if a real one arrives, durability follows the
  TTL rung rather than applying uniformly.
- A state file is observed in dogfood or in the field that authenticates
  and is then rejected by the core (`crates/ffi/src/lib.rs`).
  That is the one failure a last-known-good generation would have caught,
  and section 7's decision against it gets revisited on the first
  occurrence.
- The threat model grows an adversary who is not the logged in user and
  who can still set the clock. The stepped clock is priced entirely on
  that adversary not existing. The rolled back state file is priced
  differently, on the anti-rollback counter costing a keychain write per
  save, so a counter that stops costing that reprices it.
- The TTL ceiling rises above seven days. The residual exposure in
  section 8 is priced at seven days; a longer ceiling reprices it.
- Any measurement shows the debounce window costing real work despite
  #46 and #49. The 2 second number is a tradeoff, not a constant, and the
  ciphertext-generation cost it trades against is now larger than it was.
