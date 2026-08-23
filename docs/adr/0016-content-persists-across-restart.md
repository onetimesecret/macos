# ADR-0016: Staged content persists across restart

- **Status:** accepted
- **Date:** 2026-08-20
- **Supersedes in part:**
  [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md).
  Superseded: lines 34 to 51 except 47 and 49, which is the **Staged
  content, bounded to the boot session** subsection minus its keychain
  tiering paragraphs. That covers the two-half derivation as stated at
  36 to 39, the crypto-erasure claim at 41, the
  deterministic boot-UUID backstop and its fail-closed clause at 43, the
  does-not-claim paragraph at 45, and the boot-versus-user-session
  paragraph at 51. Also line 63, the monotonic rule, **for staged
  content only**, which section 4 below narrows rather than replaces;
  line 63's live-timer requirement and its load-path backstop stand.
  Also consequences 98, 100 and 101, redrafted in section 8.
- **Left standing in ADR-0012, unamended:** framing at 22 to 27; item
  identity at 32; keychain tiering and its Amendment 2026-08-10 at 47
  and 49, carried forward and leaned on in section 3; the write policy
  at 53 to 59; titles at 66 to 74, unamended by this ADR (ADR-0017
  moves the user-set title at 72 and the placeholder stamp at 71 onto
  the Tab); the whole ledger subsection at 76 to
  85, whose wall-clock retention exception at 83 now agrees with
  content; supporting decisions at 88 to 93, including the
  bundle-id-derived keychain ACL identity note at 90.
- **Rides the same format break:**
  [ADR-0017](0017-durable-tabs-expiring-pages.md), "Durable tabs,
  expiring pages"; see section 9.

## Context

Issue #44 asks for the durability and security contract for unexpired
pages. The maintainer's own report is what opened the milestone
(`docs/dogfood/ABERRATIONS.md:74`): "I lost a whole bunch of stuff b/c I
accepted a system update without considering onetime pad", followed at
line 75 by "If we already have the TTL expiration, we don't gain much by
flushing everything upon restart. We just make it annoying to use."

What the tree does today, verified at file:line in
`docs/plans/44-ground-truth.md`:

- The sealed state envelope is
  `OTSSEAL2 ‖ boot_uuid[16] ‖ wall_ms[8] ‖ mono_ns[8]`, and all 40 bytes
  are the AEAD associated data (`crates/ffi/src/persist.rs:154`, `:234-236`,
  `:582-587`, `:660-699`).
- The content key is `HKDF-SHA256` with a temp-directory half as salt and
  a keychain half as input keying material (`crates/ffi/src/persist.rs:419-426`).
  The temp half's filename folds `kern.bootsessionuuid`
  (`crates/ffi/src/persist.rs:451-464`) and the file lives in
  `_CS_DARWIN_USER_TEMP_DIR` at mode 0600
  (`crates/ffi/src/persist.rs:461-466`, `:483-490`, `:1139-1153`).
- A file carrying another session's boot UUID opens as
  `Opened::BootMismatch`, which rotates both halves and erases the file
  (`crates/ffi/src/lib.rs:1289-1312`).
- Writes are `create_new` temp, `sync_all` (F_FULLFSYNC on Darwin),
  `rename(2)`, parent directory fsync
  (`crates/ffi/src/persist.rs:1139-1198`).

Two facts decide this ADR against keeping the boot bound.

First, the boot bound does not deliver what ADR-0012 sells.
`rotate_key_halves` has exactly one caller, the `BootMismatch` arm at
`crates/ffi/src/lib.rs:1300`, reachable only when a parseable state file
exists. A user who empties the pad before shutdown erases that file and
the next boot session reuses the previous keychain half verbatim
(`crates/ffi/src/persist.rs:244-257`). ADR-0012:45 already concedes the
previous temp half's bytes may still be on disk if the directory was not
cleared. Combine the two and an extracted keychain item plus an uncleared
temp directory yields a live content key across reboots. So ADR-0012:38's
"rotated on first launch after a new boot session" is not what the code
does, and keeping the bound would mean correcting that claim downward
rather than preserving it.

Second, ADR-0011:6 sets the default TTL at seven days and ADR-0011:8
justifies the rungs by calendar reasoning ("Will i need this next
week"). On a machine that reboots weekly, a boot-bound 7d rung never
means what its label says.

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
recorded in a per-page `drained_ms` that no restore may reduce. Section 4
states exactly what that is worth and what it is not.

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
| Clean quit (⌘Q) | Yes, in full | `applicationShouldTerminate` calls `saveState()` and stands down whatever the debounce still holds (`shell/Sources/OnetimePad/BackdropApp.swift:121-151`, `shell/Sources/CompanionKit/PageModel.swift:962-1065`). If that write is refused, an alert offers Quit Anyway or Cancel; a settled flush over a withheld licence with work in the session warns the same way (BackdropApp.swift:122-150). On relaunch the pages are there with less time on them. |
| Crash (process fault) | Yes, except the debounce window | The last burst of typing inside the window is gone. Everything sealed before it is intact, because each write lands whole or not at all (`crates/ffi/src/persist.rs:1139-1198`). Nothing tells the user which keystrokes were lost. Window quantified in section 2. |
| Force termination (`kill -9`, Force Quit) | Yes, except the debounce window | Identical to crash. SIGKILL runs no handler, so the sudden-termination latch (`shell/Sources/CompanionKit/PageModel.swift:101-141`) buys nothing here; the atomic write is what saves the rest. |
| macOS restart or shutdown | Yes. **Required work**; today the file is discarded at `crates/ffi/src/lib.rs:1289-1312` | An orderly restart delivers a terminate while a write is owed, because the latch holds sudden termination off a dirty buffer (PageModel.swift:101-141, `shell/OnetimePad-Info.plist:56`), so the quit flush runs and the loss window is zero. A mutation that never reached `markDirty()` is not covered, and neither is a kill before the flush lands. Today the user sees an empty pad, which is the defect this ADR exists to remove. |
| App update (same bundle id, same signing identity) | Yes, when the sealed format version is unchanged. **Required work** for the version-change case; see section 9 | Replacing the bundle changes nothing the file depends on. A build whose `FILE_MAGIC` differs refuses the file (`crates/ffi/src/persist.rs:594-605`, `:664-678`), which is a one-time loss, announced the way the previous break was (the repo-root `DOGFOOD.md:50-56`). |
| Development rebuild | Only while the bundle id and signing identity hold still | Keychain ACL identity is derived from the bundle id (ADR-0012:90), and a `.debug` suffix or a changed `CODESIGN_IDENTITY` strands the halves. That lands in section 7's unavailable-key case: no restore, no overwrite, no writes for the session. Separately, `swift build` re-signs the bundle in place and the running instance is SIGKILLed (observed in development; nothing in the tree enforces or prevents it), so a rebuild against a live app is a force termination carrying the section 2 window. |
| Logout | Yes | The process dies by sudden termination unless a write is owed. The latch is real and refcounted (PageModel.swift:101-141) and the shipping bundle declares `NSSupportsSuddenTermination` (`shell/OnetimePad-Info.plist:56`), so a dirty buffer blocks the fast path and the terminate flush runs. A mutation that never called `markDirty()` is not covered: pasteboard copy-out is exactly that case today and is filed as issue #52 (PageModel.swift:1847-1854). |
| Fast user switching | Yes | No process death, no window at all. The other account cannot read anything: the state directory sits under the user's own Application Support (`shell/Sources/CompanionKit/FormFactor.swift:59-64`), the key halves are written 0600 (`crates/ffi/src/persist.rs:1139-1153`), and the keychain half is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on an entitled build (`crates/credentials/src/lib.rs:637-646`). |
| Power loss | Yes. **Required work**, on the same footing as the restart row: power loss ends the boot session, so today the file is discarded at `crates/ffi/src/lib.rs:1289-1312` | Same window as crash, plus one artifact: a death between `create_new` and `rename` strands a complete sealed generation as `state.sealed.<hex>.tmp`, and nothing sweeps it (`crates/ffi/src/persist.rs:1144-1163`). |

Content survives everything except the debounce window. That window is
not the debounce interval ADR-0012:99 names; after a refused write it is
five times longer and open-ended under a modal, as section 2 sets out.

### 2. The loss window, stated as a tradeoff

The nominal window is 2.0 seconds, measured from the **first** mutation
of a burst, not the last (`shell/Sources/CompanionKit/PageModel.swift:472`,
`:174-192`). That anchoring is deliberate and correct: a trailing debounce
restarted per keystroke makes the window unbounded for the one case
persistence exists for.

The window after a refused write is 10.0 seconds, not 2
(PageModel.swift:490-492). It is worse than a longer retry interval
suggests, for two reasons recorded in `docs/plans/44-ground-truth.md`
section 2:

- `SaveSchedule.arm()` returns nil while a write is pending
  (PageModel.swift:174-179), so every mutation during the retry interval
  is absorbed into the already-armed retry rather than arming a fresh
  2 second timer. One refusal silently changes the window for everything
  typed afterwards.
- The retry runs in `.default` run-loop mode (PageModel.swift:1049-1063,
  `:898-909`), deliberately, so it cannot fire underneath the quit
  alert's modal and make its text false. The cost is that the retry
  cannot fire while any tracked menu or modal is up, so the window is
  open-ended for as long as one is.

The user is now told all of this (issue #49). A withheld licence raises
a standing banner on the surface with the one recovery action
(`shell/Sources/CompanionKit/PageSurface.swift:94-119`,
`contentRestoreRefused` at PageModel.swift:272-278), the header carries
the write lifecycle as a word, saving, saved or save failed
(`SaveStatus` at PageModel.swift:205-221, moved in `markDirty` and
`saveState`), and the quit path warns on both loud outcomes: a refused
write, and a settled flush over a withheld licence with work in the
session (`quitOutcome` at PageModel.swift:1071-1085,
BackdropApp.swift:121-151). `saveState()` still sets `saved = true` on
the withheld-licence leg (PageModel.swift:990-994), so `settled` stays
true there; the standing state is what carries the story, not the
write's return value.

The tradeoff is accepted as stated, and the number does not move.
Shortening the debounce multiplies on-disk ciphertext generations, and
each rename unlinks rather than erases the prior one (ADR-0012:55), which
matters more under this ADR than it did under ADR-0012 because reboot no
longer makes those generations undecryptable. The compensation is
visibility, not a smaller number.

**Required work, done.** Issue #49 (surface a withheld licence and a
refused write) landed first, as above. Issue #46 (⌘S force-save riding
the same status surface) rides `saveState()` directly
(`shell/Sources/CompanionKit/PageSurface.swift:270-271`), the same call
the debounce timer and the quit path make, so a press asks for nothing
the write lifecycle does not already do on its own, only for it now.
Under ADR-0012 a silently withheld save licence cost one boot session;
under this ADR it would have cost every page until the user noticed,
which is why #49 was a precondition of this ADR rather than a
follow-up.

### 3. Key availability across a restart

**Required work.** The second half stops folding `current_boot_uuid()`
into its filename (`crates/ffi/src/persist.rs:451-464`) and moves out of
`_CS_DARWIN_USER_TEMP_DIR` (`crates/ffi/src/persist.rs:461-466`,
`:483-490`) into the app support state directory beside `state.sealed`. That threads the state
path into `persist`, which derives its own directory today. Call it the
file half, not the boot half; nothing about it is per-boot any more. The
name stays an HKDF output under the keychain half, keyed by
`FILE_HALF_NAME_INFO` (`crates/ffi/src/persist.rs:214`) with
`FILE_HALF_NAME_SALT` (`:222`) as the salt. Only the appended
`current_boot_uuid()` leaves that salt (`:416-418`); the info string and
the salt constant are unchanged, because that derivation is also what
keeps two form factors out of each other's half
(`crates/ffi/src/persist.rs:449-464`). In its new home it inherits the
directory's `.noindex` naming and `isExcludedFromBackup`
(`shell/Sources/CompanionKit/FormFactor.swift:95-122`) and
`write_private`'s 0600 mode and atomic replace
(`crates/ffi/src/persist.rs:1139-1153`).

**The keychain half's protection class does not change, and nothing in
`crates/credentials` changes.** What the half buys does change, and
smaller, so state it. ADR-0012:45 could say an extracted keychain item
was useless once its per-boot partner was gone; with both halves durable
the split bounds nothing in time. It still buys two things. The
ACL gate: a process running as the user that reads the 0600 file half
will derive nothing without passing the keychain. And separation of backup
domains: the state directory is excluded from Time Machine
(`shell/Sources/CompanionKit/FormFactor.swift:120-122`) and the keychain
database is not, so neither a backup nor a copy of the state directory
yields a key on its own.

The class itself stays `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
with `kSecUseDataProtectionKeychain` on an entitled build
(`crates/credentials/src/lib.rs:637-646`). On every build this tree
currently produces the half is instead a login keychain item with no
protection class at all: the `DefaultFile` add scope sets no
`kSecAttrAccessible` (`crates/credentials/src/lib.rs:647-651`), and no
build here carries the entitlement
(`scripts/package-app.sh:197-213`, `scripts/local.env:1-10`). The lock
gate today is therefore the login keychain's, and the reasoning below
describes the entitled build only.

The reason `WhenUnlocked` is enough is where the read happens. The only
caller of `loadStateIfNeeded()` is `BackdropModel.start()`
(`shell/Sources/OnetimePad/BackdropModel.swift:110`), and the key is
loaded from inside that restore
(`crates/ffi/src/lib.rs:1558-1562`,
`shell/Sources/CompanionKit/PageModel.swift:629-635`). `start()` runs when
the app launches, and the app launches either because the user opened it
or because `SMAppService.mainApp` started it as a login item
(`shell/Sources/CompanionKit/SettingsSections.swift:27-40`). Both are
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
   (`crates/core/src/clock.rs:88-123`), which the live timer already
   reads through `companion_next_event_ms`
   (`shell/Sources/CompanionKit/PageModel.swift:2189-2217`). That clock
   is not settable, so a clock step mid-session buys nothing. ADR-0012:63
   is therefore narrowed rather than replaced: monotonic stays
   authoritative for every interval the process observes.
2. **Wall clock measures only the gap the process did not observe,**
   which is the interval between the last save and the next restore:
   `away = wall_now.saturating_sub(sealed_wall_ms)`. Nothing else in the
   lifetime math reads the calendar clock. The content path holds two
   other wall-clock readers and neither ages a page: `created_wall_ms` at
   page birth (`crates/core/src/store.rs:232`), which names a page, and
   the block stamps written into the same sealed file as wall seconds
   (`crates/core/src/persist.rs:597-598`), from which nothing derives a
   deadline. `saturating_sub` is what makes a backward gap read as zero
   rather than as a credit (`crates/core/src/persist.rs:244`).
3. **Elapsed life crosses the file as the life that is left, plus the
   stamp that ages it.** *(Amended 2026-08-23, from a specified
   `drained_ms` field to the encoding that shipped; the paragraph after
   this one records why.)* Each page record writes the span it has left,
   the running one (`crates/core/src/persist.rs:489-491`) or, for a held
   clock, the hold's own span and the frozen remaining (`:493-506`),
   because a held clock is a suspended drain and not a drained one. The
   file carries `sealed_wall_ms` in its authenticated header. Restore
   charges the gap against a live hold first: a gap shorter than the
   remaining hold shortens the hold and leaves the frozen life alone, and
   only the part beyond the hold reaches the countdown
   (`crates/core/src/persist.rs:844-873`). What reaches it is subtracted
   and never added: `deadline = now + remaining.saturating_sub(away)`,
   with `away` already floored at zero, so no restore hands life back and
   the never-rewind invariant this section opens with is a property of
   the arithmetic rather than of a rule about a field. The span read back
   is bounded by the rung of the tab that holds the page (`:846`, `:852`,
   the rung threaded in at `:790`), so a file cannot claim more life
   than the ladder allows however it was edited. The one exception is not
   a clock effect: a deliberate TTL rung click sets the deadline to the
   rung's full duration, which is the user's own instruction
   (`crates/core/src/ttl.rs:4-6`).

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
`state.sealed`, in the field the header carries today as `wall_ms` and
hands back as `Opened::Plaintext { saved_wall_ms }`
(`crates/ffi/src/persist.rs:576`, `:612`, `:699`), renamed
`sealed_wall_ms` in the new envelope, and therefore inside the AEAD
associated data. It is not in `UserDefaults` and not in a third file: it
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
(`crates/ffi/src/persist.rs:594-605`, `:660-699`), which is section 7's
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

The tree's existing direction is kept in half and dropped in half.
`monotonic_away_ms` charges the ceiling for a stamp that reads later than
now (`crates/ffi/src/lib.rs:1218-1230`); wall-clock aging charges zero for
that same case, because `saturating_sub` floors at zero. What survives is
the never-credit half: a restore only ever subtracts from the span a
page carries, so no restore hands life back. What is dropped is that
function's stated absolute, "Granting life past a page's TTL is the
one outcome that must be impossible", which the paragraph above prices.

### 5. The reboot trap in the restore path

State this separately so nobody reimplements it.

Removing the boot check is not sufficient. Restore currently hands the
core `saved_wall_ms.saturating_add(away_ms)` where
`away_ms = monotonic_away_ms(sleep_inclusive_ns(), saved_mono_ns)`
(`crates/ffi/src/lib.rs:1618-1630`). Both readings come from a clock that
restarts at reboot. After a restart, `sleep_inclusive_ns()` is small and
`saved_mono_ns` is large, `checked_sub` returns `None`, `away_ms` becomes
`u64::MAX` (`crates/ffi/src/lib.rs:1225-1230`), and the core drains every
countdown the instant the surface opens.

The failure is silent and it presents as success. `persistRestore`
returns true, the save licence is granted, the ledger fills with
`expired` records, and the pad is empty. To the user it reads as "restore
worked, everything had expired." To a test that only asserts
`persistRestore == true` it reads as a pass.

**Required work.** The restore path stops calling `monotonic_away_ms`
entirely, and `saved_mono_ns` leaves the header in the same format break
as the boot field (section 9). Time away is
`wall_now.saturating_sub(sealed_wall_ms)` per section 4. A test that
simulates a monotonic clock restart while wall time advances by minutes,
and asserts the pages are still there, is mandatory before this ships
(section 10, case 3).

### 6. Key rotation once `BootMismatch` is gone

`rotate_key_halves` has one caller today, the `BootMismatch` arm
(`crates/ffi/src/lib.rs:1300`), and that arm is deleted by this decision.
Rotation therefore needs a new trigger or it leaves the design.

**Required work.** Both halves rotate on exactly two events:

1. **The pad empties, which means no tab holds a page.** None of the
   machinery below exists today.

   The definition is load-bearing because ADR-0017 rides the same break.
   Today the condition is `client.sheets().isEmpty`
   (`shell/Sources/CompanionKit/PageModel.swift:911`), which is the page
   vector's own emptiness, the same test the core's `is_empty` runs
   (`crates/core/src/store.rs:279-280`, which ADR-0017:425 lists among
   the readers that follow the split), and meeting it drops the content
   file rather than resealing it
   (`shell/Sources/CompanionKit/PageModel.swift:769-773`, applied on the
   `persistErase` leg at `:995-1010`). Dropping it stops being available:
   the same sealed file will carry the durable tab names, rungs and strip
   order, and a tab survives its page (ADR-0017:73-74), so an expiry that
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
   previous one rather than erasing it (ADR-0012:55). The rotation has to
   complete before the reseal, so that the generation left behind is
   already undecryptable when it is unlinked.

2. **Explicit Clear.** The content side now has one, issue #49's
   discard (`clearUnreadableStateFile`,
   `shell/Sources/CompanionKit/PageModel.swift:1420-1434`, the licence
   re-grant through `licencesAfterContentClear` at `:855-859`),
   mirroring the ledger's
   (`shell/Sources/CompanionKit/PageModel.swift:1364-1383`, the licence
   re-grant at `:1376-1380`). Section 7 requires it for a second
   reason, and it is the same gesture.

`erase_state` must also unlink the file half. Today it zeroes, truncates
and unlinks only the state file (`crates/ffi/src/persist.rs:790-816`),
which was sufficient when the other half died with the boot session and
is not sufficient now.

**What is lost by rotating less often than once per boot.** An install
that always holds at least one page keeps one content key for the life of
the install, bounded only by the keychain ACL identity changing
(ADR-0012:90). Crypto-erasure stops being a scheduled event and becomes
the finishing step of a deletion the user or the TTL asked for. Concretely:
a ciphertext generation captured by a backup or an APFS local snapshot,
together with a captured pair of halves, stays decryptable until the user
empties the pad or clears it, where previously it stopped being
decryptable at the next reboot. Section 8 carries this into the
consequences.

### 7. Recovery guarantees

**The binding rule: a failed restore must never replace prior persisted
state with empty state.** Every case below satisfies it through the save
licence rather than through a second copy. Three of the four hold today.
The third holds today only for a file this boot session sealed, and
deleting the `BootMismatch` arm (`crates/ffi/src/lib.rs:1289-1312`) is
what makes it unconditional.

| Failure | What happens | Citation |
|---|---|---|
| Snapshot fails authentication (tampered, truncated, wrong key, superseded magic) | `Opened::Refused`, restore returns false. The file is still on disk when the probe runs, so `grantsSaveLicence(fileExists: true, restored: false)` is false and the session may not write over it. A working page opens; nothing is destroyed. | `crates/ffi/src/persist.rs:594-605`, `:660-699`, `crates/ffi/src/lib.rs:1562`, `shell/Sources/CompanionKit/PageModel.swift:629-642`, `:721-724` |
| Snapshot authenticates but the core rejects the payload | `diag_fault` names it as the one refusal that survives a fresh keychain, restore returns false, same licence outcome, file untouched. | `crates/ffi/src/lib.rs:1631-1641` |
| Key unavailable (locked keychain, denied ACL, changed bundle id or signing identity) | `load_key_for` returns `None`, the file opens as refused, same licence outcome, file untouched. Rotation is not attempted, so nothing is deleted on the way past. Today this holds only for a file this boot session sealed: the boot check runs before the key closure (`crates/ffi/src/persist.rs:724-726`), so an earlier session's file is rotated and erased without the key ever being asked for. Deleting that arm is what makes the row true unconditionally. | `crates/ffi/src/persist.rs:262-282`, `:724-726`, `crates/ffi/src/lib.rs:1558-1562`, `:1289-1312` |
| `sealed_wall_ms` missing or corrupt | Not separable from the first row: the stamp lives in the associated data. | section 4 |

The cost of that rule is the session: a refusal withholds the content
licence for the whole run, and the one thing that clears it is the
user's own discard on the banner the refusal raises
(`clearUnreadableStateFile`,
`shell/Sources/CompanionKit/PageModel.swift:1420-1434`). Under ADR-0012
that cost ended at the next reboot, because the boot mismatch arm
dropped the offending file. Under this ADR nothing ever drops it
unbidden, so the withholding lasts until the user acts, and issue #49's
surfacing is what makes sure they can.

**Decision on a last-known-good generation: not required, and not built.**
The app cannot produce a torn state file; every write lands whole or not
at all (`crates/ffi/src/persist.rs:1139-1198`). The realistic failures
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
  `shell/Sources/CompanionKit/PageModel.swift:1420-1434`,
  `licencesAfterContentClear` at `:855-859`). Without it the
  withholding was permanent by construction, since nothing else removes
  the file.
- Issue #49's surfacing, so the user learns the session is not writing
  at the moment it stops writing rather than at the moment they lose a
  week: the standing banner with the discard action
  (`shell/Sources/CompanionKit/PageSurface.swift:94-119`), the header's
  write-lifecycle word, and the quit warning over a withheld licence
  with work in the session (`quitOutcome` at PageModel.swift:1071-1085,
  `shell/Sources/OnetimePad/BackdropApp.swift:121-151`).
- The superseded-magic disposal path from section 9, so the one-time
  format break does not present as a permanently unwritable install.

### 8. What is honestly given up

The three redrafts below state ADR-0012's consequences as they read once
this decision's Required work has landed, not as the tree stands today;
the citations in them mark the code each claim will rest on.

**Retracted.** ADR-0012:41, "Crypto-erasure at reboot is the primary
mechanism", is withdrawn. So is the public form of it in the repo-root
`DOGFOOD.md:57-63`, "Staged content no longer survives a reboot, by
design." Under ADR-0007's rules that is a claim change, so the wording is
replaced rather than quietly dropped.

**The replacement claim.** Staged content is bounded by its TTL and by
policy, not by the boot session. Nothing outlives its TTL, the ceiling is
the ladder's top rung at seven days (`crates/core/src/ttl.rs:6-7`,
`:32`, `:45-46`), and crypto-erasure is what finishes a deletion that the
TTL, an emptied pad, or an explicit Clear has already decided. Content
forgets on schedule, not at reboot.

**Redraft of ADR-0012:98.** A ciphertext artifact exists on disk
continuously from the first save until the last tab is closed. The pad
emptying of pages does not remove it, because the same file carries the
durable tabs: section 6 rotates both halves at that transition and
reseals the surviving tab metadata, so what sits on disk afterwards is a
fresh generation holding tab names and no page content, and every
generation that ever held content is undecryptable from that moment.
Alongside it are unlinked prior generations until APFS reclaims them,
plus any stranded `.tmp` generation from a death mid-write
(`crates/ffi/src/persist.rs:1144-1163`), and, now that the file half is
written through the same function into the same directory, any stranded
`.tmp` copy of a key half. `erase_state` removes neither, because it
unlinks only the exact path it is given
(`crates/ffi/src/persist.rs:790-816`), and unlike the temp directory this
one is never cleared at boot. Required work: sweep `*.tmp` in the state
directory at launch. Both key halves are durable across boot sessions:
one in the keychain under the app's ACL, one at 0600 in the state
directory. The file is unreadable without both halves. Both halves are
replaced on each of section 6's two triggers, the pad emptying of pages
and an explicit Clear, and the old pair is deleted when they are. A
change of keychain ACL identity removes nothing: the keychain item
survives and only stops being readable by the new code identity
(ADR-0012:90), and the file half in the state directory is untouched,
which is section 7's unavailable-key row. That event ends this install's
access without ending the material's readability for anyone holding both
halves.

**Redraft of ADR-0012:100.** The audit story is one small module that
writes secret ciphertext, one derivation of two key halves, and **one**
mechanical check rather than two: the TTL, measured against a per-page
`drained_ms` that no restore reduces and a wall stamp inside the
authenticated header. The boot session UUID check is gone. The ledger is
content-free by construction except the capped, user-visible title field,
unchanged.

**Redraft of ADR-0012:101, accepted residual exposure.** Everything
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
(`shell/Sources/CompanionKit/FormFactor.swift:95-122`), which closes one
channel and not the volume-snapshot channel. **Reverting this decision
later does not retroactively kill a half that was durable while it was
captured.** That asymmetry is the reason this section exists.

**Rollback of the state file, accepted.** Removing the boot field removes
the only thing that ever made a previous generation of `state.sealed`
refuse to open, and it only ever refused one from an earlier boot
session: that file took the `BootMismatch` arm and was rotated and erased
(`crates/ffi/src/lib.rs:1289-1312`). Within a single boot session the
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
(`crates/ffi/src/persist.rs:1139-1153`), and it cannot read the
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
ADR-0012:82 keeps content-derived titles, capped at eighty characters
(ADR-0012:70), under a long-lived never-rotated key for a rolling ninety
days, and calls that a bound an auditor can state in one sentence. This
decision keeps full page bodies under a long-lived key for the life of
the page, at most seven days, plus the unlinked and stranded generations
this section already says nothing sweeps. Larger per byte, shorter per
calendar, both behind the same keychain ACL. The reader can weigh that.

**Required work.** The repo-root `DOGFOOD.md:57-63` is rewritten and `README.md` and
`SECURITY.md` are audited for erasure-at-reboot language before this
ships.

### 9. Migration: one format break, taken deliberately

`FILE_MAGIC` bumps from `OTSSEAL2` to `OTSSEAL3`
(`crates/ffi/src/persist.rs:154`). The header loses `boot_uuid[16]` (section 3) and `mono_ns[8]` (section 5),
leaving `magic[8] ‖ sealed_wall_ms[8]`. `STATE_HEADER_LEN` therefore
changes (`crates/ffi/src/persist.rs:234-236`), and since the whole header
is the AEAD associated data (`crates/ffi/src/persist.rs:582-587`, `:688-695`), every
existing `state.sealed` fails authentication. The snapshot's own `MAGIC`
bumps from `OTSSNAP3` to `OTSSNAP4` (`crates/core/src/persist.rs:102`) in
the same break, and it carries two causes rather than one. Each page's
record replaces its running span with `drained_ms` (section 4), and
issue #54 gives every repeated record its own length prefix
(`crates/core/src/persist.rs:405-421`). #54 landed first and took the
bump; this decision rides it rather than spending a second one.

**The ledger payload magic breaks in the same release, and it did not
have to.** `LEDGER_MAGIC` goes `OTSLEDR1` to `OTSLEDR2`
(`crates/core/src/persist.rs:111`), because the ledger record is framed
under the same rule as the content records (`:620-624`). Nothing else
about the ledger changes: `LedgerRecord` is unchanged, the file keeps its
own envelope magic (`crates/ffi/src/persist.rs:181`) and its own
long-lived key (`crates/ffi/src/persist.rs:196`), and the `OTSSEAL3`
bump reaches neither. The ledger file would have sat out this break;
framing its records is what breaks it. The cost is the retained history:
the capped titles and the event records, back to the ninety day retention
window, destroyed once, in this release, alongside the staged content. It
is accepted so the module carries one encoding rule rather than two, and
so a later per-record field costs the ledger nothing. A superseded ledger
magic refuses as unknown format, tested alongside the content magics
(`crates/core/src/persist.rs:2391`, `:2442`).

**There is no migration path and none is possible.** An `OTSSEAL2` file's
key derives from a half in the temp directory that the restart already
cleared, and even in-session the changed associated data makes the bytes
unauthenticatable. Users lose whatever is staged, once, and the retained
ledger history with it. This is the
second announced break (the repo-root `DOGFOOD.md:50-56` announced the first, in which
the envelope and the snapshot each took a version byte at once) and it is
announced the same way.

**Required work.** A file whose magic is a *known superseded* version is
erased and the licence is granted, rather than left as a refusal. The
known superseded set at this break is exactly one entry, `OTSSEAL2`, and
it grows by one entry per future break. `OTSSEAL1` stays out of it: it is
refused outright today (`crates/ffi/src/persist.rs:1414-1428`) and this
break does not change that. "Erased" here is `erase_state`'s discipline,
zero the bytes, truncate, unlink, and confirm the absence
(`crates/ffi/src/persist.rs:790-816`), not a plain unlink, because the
file being discarded is a full ciphertext generation of staged content.
Without this, the first launch after the update presents as an install
that has permanently stopped saving, which is the exact failure Amendment
2026-08-10 was written about (ADR-0012:49). Nothing is written to the
ledger for the discarded pages: a superseded magic fails
`StateHeader::parse`, so the file is never decrypted and the UUIDs inside
it are unknowable (`crates/ffi/src/persist.rs:664-678`,
`crates/ffi/src/lib.rs:1562`).

**Required work.** The same question exists one layer down, for a known
superseded *ledger payload* magic, and the paragraph above does not
answer it. The envelope's superseded magic never decrypts. An `OTSLEDR1`
file authenticates and opens under the unchanged envelope and the
unchanged key, and is then refused inside `restore_ledger`
(`crates/core/src/persist.rs:326-328`). The seam reports that as a failed
restore (`crates/ffi/src/lib.rs:1858-1864`), the file is still on disk
when the probe runs, so the ledger licence is withheld for the session
(`shell/Sources/CompanionKit/PageModel.swift:657-660`), and it is
withheld again on every later launch, because nothing removes that file
except the user's own Clear (`:1364-1383`), which the log line at
`:662-678` already names as the only way out. Every install carrying a
ledger file meets this on first launch after the release. So a known
superseded ledger payload magic is disposed of and the ledger licence
granted, on the rule this section already sets for the envelope. The
known superseded set is exactly one entry, `OTSLEDR1`. The disposal is
layered the way the envelope's is, one level down (issue #61): the core
owns the magic, so it names the refusal, `RestoreError::Superseded` for
an entry of `SUPERSEDED_LEDGER_MAGICS` (`crates/core/src/persist.rs:127`,
`:151`, `:324`), and the seam owns the file, so it erases it with
`erase_state`'s discipline and reports the restore as failed
(`crates/ffi/src/lib.rs:1860`); the probe then finds no file and grants
the licence, exactly as after the envelope's `Superseded`. The ledger
key is not rotated: the file was authentic under it, the user's Clear
does not rotate it either, and a rotation at launch is the Keychain
prompt ADR-0004 forbids. Nothing is written to the ledger about the
records dropped. Salvage is not on the table: there is no reader for a
superseded version and no downgrade writer
(`crates/core/src/persist.rs:2442`).

**[ADR-0017](0017-durable-tabs-expiring-pages.md), "Durable tabs,
expiring pages", rides this same break, deliberately.** The split
(`docs/dogfood/ABERRATIONS.md:68`) moves page metadata onto a Tab object
and therefore changes the persisted object graph, which no compatibility
rule absorbs. Taking it in a second break would cost users their staged
content twice, so it ships in this `FILE_MAGIC` bump or it waits for the
next one.

ADR-0013's interaction count is the other pending obligation on this
format, declared not derivable from the op log and implemented nowhere
today (`crates/core/src/persist.rs:589-606` writes `created_s`,
`modified_s` and `origin` and no count; recorded at
`docs/plans/44-ground-truth.md:100`). It is a trailing field, so the rule
immediately below releases it from this break: it can land whenever
ADR-0013 is implemented, at no cost to anyone's staged content.

**The snapshot's records are self-describing as of this break.** They
were positional, and
[issue #54](https://github.com/onetimesecret/macos/issues/54) gave each
repeated record its own byte length in front of its fields
(`crates/core/src/persist.rs:405-421`): the page record (`:472`), the chip
records inside it (`:516`), the materialized block record (`:589`) and the
ledger record (`:624`). Four kinds, not the three #54 named. The chips
were taken in deliberately, so the rule has no exception inside the
module and a later per-chip field costs no break either. A reader
consumes the fields it knows and then reaches the next record by that
record's length rather than by where its own field walk stopped
(`:709-714`), so a file written by a build that added a trailing field
still reads here, minus the field this build has never heard of. One test
per record kind holds the rule (`:1995`, `:2021`, `:2044`, `:2084`). Full
tag-length-value encoding is rejected in #54, because it puts a parser
inside the one module ADR-0012:30 stakes the audit story on.

**What the rule does not buy.** A field that moved, changed width or
changed meaning is not a trailing field and still costs a new magic, and
so does anything outside a record: the magics, the counts, and the
sections that trail a record list. A new magic still refuses every
existing file, and a tail after the last record is still damage, because
it sits outside every frame and nothing states how long it is
(`crates/core/src/persist.rs:271-277`).

The envelope does not follow. Its header is associated data in full
(`crates/ffi/src/persist.rs:234-236`), so anything added there changes what
authenticates, and an unknown envelope magic must keep failing closed
(`:664-678`). Extensibility belongs in the payload.

### 10. Required test coverage

Mapped to the seven cases in issue #48. Everything below is required
work; the citations mark what exists today to build on or to delete.
`docs/qa/verification-procedures/` holds the four procedures below plus
one about drag tracking, and none of them has been run.

| # | Case | CI | Hardware procedure |
|---|---|---|---|
| 1 | Clean quit | Rust round trip exists (`crates/ffi/src/lib.rs:2726`, `crates/core/src/persist.rs:1134`). Add a Swift test that drives `saveState()` and `applicationShouldTerminate`; today a regression removing the quit flush passes CI green. Blocked on issue #53 (no injectable state directory or credential store). | None |
| 2 | Crash or force termination | Debounce arithmetic and the latch are covered as value types (`shell/Tests/CompanionKitTests/StateLicenceTests.swift:320`, `:388`) and atomic replace under concurrency is genuinely covered (`crates/ffi/src/persist.rs:2184`, `:2290`). Add: every mutation site reaches `markDirty()`; the shipped plist still declares `NSSupportsSuddenTermination` (`shell/OnetimePad-Info.plist:56`); the post-refusal window is 10 s and absorbs subsequent mutations (section 2). | `kill -9` mid-burst, then relaunch and confirm what survived |
| 3 | macOS restart | The existing boot-session tests are **invalidated by this ADR**: the discard and refusal assertions at `crates/ffi/src/persist.rs:1868` and `:1850`, the boot-UUID plumbing they rest on at `:1683`, `:1705` and `:1728`, and at the seam `crates/ffi/src/lib.rs:3423` and `:3481`, which turns on the deleted `BootMismatch` retry. The rotation tests at `crates/ffi/src/persist.rs:1925`, `:1958`, `:1985`, `:2003` survive and gain the two triggers of section 6. Add: a monotonic clock that restarts while wall time advances leaves pages alive (section 5, mandatory); a running page's save-to-restore gap drains by wall clock and by that gap only; a page held across a restart charges the gap against the hold first, so a gap shorter than the remaining hold comes back still held with `frozen_remaining` intact and `drained_ms` unmoved, and a longer gap drains only the excess, which is `crates/core/src/persist.rs:2321`'s property carried onto the new restore path; `drained_ms` is persisted and no restore reduces it. | A real reboot with a live pad, plus a reboot with the pad emptied first, confirming rotation ran; a reboot with a page paused, confirming it returns paused |
| 4 | App update or dev rebuild | Format-version refusal is covered (`crates/ffi/src/persist.rs:1419`). A superseded magic is erased and the licence granted, for the envelope (`crates/ffi/src/lib.rs:4110`) and for the ledger payload (`:4210`), section 9. | Re-sign with a different identity and confirm the unavailable-key path refuses without erasing; `.debug` versus release bundle id separation |
| 5 | Damaged snapshot | Rust coverage is strong (`crates/core/src/persist.rs:1364`, `:2104`, `:2463`, `:2489`, `:2520`; `crates/ffi/src/persist.rs:1305`, `:1511`). Add the Swift half: a refusal withholds the licence, does not overwrite the file, and the new content-side Clear re-grants it. Blocked on issue #53. | None |
| 6 | Unavailable encryption key | All automated coverage runs against `InMemoryCredentialStore` or a refuses-to-delete double (`crates/ffi/src/persist.rs:1794`, `:2003`; `crates/credentials/src/lib.rs:1151`); the one real-keychain test is `#[ignore]`d (`crates/credentials/src/lib.rs:1302`). CI cannot cover a locked keychain. | Locked keychain at load; denied ACL prompt; confirm no erase and no overwrite in both |
| 7 | TTL expiry | Both legs covered (`crates/core/src/persist.rs:2284`, `:2300`, `:2321`, `:2378`; `crates/core/src/store.rs:1753`, `:2423`). Three of the seam tests go with `monotonic_away_ms`, because section 5 removes it from the restore path: `crates/ffi/src/lib.rs:3330`, `:3354` and `:3568` assert the monotonic stamp is what measures time away, which stops being true. Add: a system clock stepped back before a restore ages the page by zero rather than negatively, so a page with two days left still has two days left afterwards, which is the accepted freeze of section 4 and not a defect; a `sealed_wall_ms` ahead of the system clock leaves `drained_ms` unchanged; the ceiling holds at seven days on an untampered clock. | Step the machine clock back a day with a live pad |

The four hardware procedures this required now exist under
`docs/qa/verification-procedures/`: `reboot.md`, `power-loss.md`,
`re-signed-bundle.md` and `locked-keychain.md`. Each names delano as its
owner and carries a dated Results section, and none of the four has been
run yet. Every one of them starts from a rebuild and reinstall through
`scripts/install.sh`, because both format breaks in section 9 landed and
an older installed copy cannot read the files this build writes.
`docs/hardware-verification.md` indexes all four (`:182-207`) and states
the Results convention once, at the end (`:209-215`); the procedures it
holds itself still name no owner, including the keychain round trip at
`:92-97`.

## Consequences

- The failure that opened this milestone stops happening. Accepting a
  system update no longer costs the user their staged work.
- ADR-0011's ladder means what it says for the first time. The 3d and 7d
  rungs are reachable on a machine that reboots weekly, so no rung needs
  relabelling and the ladder does not change.
- Two live defects are deleted rather than fixed. A transient
  `sysctlbyname` failure currently substitutes a per-process sentinel
  (`crates/ffi/src/persist.rs:933-936`) that turns the live session's own
  valid file into `BootMismatch` and destroys it
  (`crates/ffi/src/lib.rs:1289-1312`); issue #51 stops being reachable
  once that arm is gone. Reboot deaths that leave no ledger record
  (`crates/ffi/src/lib.rs:1289-1313`) stop occurring because nothing dies
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
  and is then rejected by the core (`crates/ffi/src/lib.rs:1702-1712`).
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
