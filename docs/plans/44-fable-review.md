# 44: independent review of ADR-0016 and ADR-0017

Reviewer: a Fable agent, run 2026-08-20 with no prior involvement in drafting either ADR.
It read `44-ground-truth.md`, both new ADRs, ADR-0012, the plan and the roadmap, and was asked
whether the decision is right, whether an engineer could implement it in six months without asking
the author, and to re-derive the aging arithmetic itself.

This record is **verbatim and unedited**, including its punctuation, which does not follow the repo's
writing rules. It is a quotation, not repo prose. Three earlier verification rounds removed 61 findings
before this review ran.

**Verdict:** sound-with-fixes

## Is the decision right

The decision is right. The boot bound was an implementation accident elevated to a security feature: ground truth shows rotation only ever fired from the BootMismatch arm, so the "rotated every boot" claim in ADR-0012:38 was never true, the fail-closed sysctl path destroys the live session's own content on a transient read error, and reboot deaths are invisible to the ledger. Keeping the bound (option A) means paying to fix all three and still relabelling the 3d/7d TTL rungs as fiction on any machine that reboots weekly. Dropping it deletes two live defects, makes the TTL ladder mean what it says, and removes the failure that cost the maintainer real work. C and D were dismissed correctly: two ciphertext paths double the one module the audit story rests on, and D's default reproduces the original loss. One deliberate divergence from the ground-truth plan deserves notice and I agree with it: ground truth (44-ground-truth.md:70, open question 1) proposed charging the CEILING when the clock reads earlier than the high-water mark (fail toward death); ADR-0016 section 4 instead freezes (away = saturating_sub floors at zero, fail toward preservation). Freezing is the correct call for this milestone. Charging the ceiling would destroy work on an innocent NTP correction or a dead CMOS battery, which is exactly the "innocent event destroys work" class this milestone exists to remove; and the ADR states the trade flatly, including retiring monotonic_away_ms's absolute ("granting life past a page's TTL is the one outcome that must be impossible"). Where I disagree is with two justifying sentences, not the decision: the replay exposure's dismissal overclaims what a same-user process can do (findings), and the "same trade, shorter" analogy equates 90 days of derived title labels with 7 days of full secret bodies, which is a value asymmetry the prose papers over. Neither changes the verdict; both are the exact sentence-that-sounds-right failure mode this project documented. On question 5: these are genuinely two decisions. ADR-0016 changes the lifetime and crypto contract; ADR-0017 changes the object graph and UX. The coupling is only format-break economics, and the dependency is declared honestly. The one place the split shows a seam is the blocking finding below: the meaning of "the store empties" falls in the crack between them.

## Could someone implement it from these documents alone

Unusually high for an ADR pair: near-every claim carries a file:line, required work is enumerated (ADR-0017 items 1-12), test invalidation is listed by line, and the reboot trap (section 5) is stated so nobody reimplements it. An engineer in six months would still have to guess at four places. (1) BLOCKING: what "the store empties" means once ADR-0017 lands. ADR-0016 section 6 rotation trigger 1 and section 8's "ciphertext exists until the pad empties" both cite the drop-on-empty path (PageModel.swift erasesContentFile, keyed on client.sheets().isEmpty; verified in tree). Under ADR-0017 the sealed file also carries durable tab names, rungs and order, so when all pages expire the file cannot be dropped without destroying the tabs, and sheets().isEmpty changes meaning. Neither ADR-0016 section 6 nor ADR-0017's required-work list touches erasesContentFile, is_empty (store.rs:279-280 is listed in item 5 only as a mechanical rename), or the persistErase leg. The engineer must invent either "empty = no tabs" (rotation almost never fires; ADR-0016's "an emptied pad is a forgetting" claim quietly dies) or "empty = no pages, reseal tabs under rotated halves" (drop becomes reseal; section 8's sentence is false as written). (2) IMPORTANT: ADR-0017's mint-on-selection vs expiry-does-not-mint. "Selecting an empty tab mints a fresh page... immediately on selection" conflicts with "Expiry does not mint the replacement" and with "at launch... Return mints" unless user-gesture selection is distinguished from restored/reconciled selection, and the live case (the selected tab's page expires while the user watches; refresh() reconciles selection onto a now-empty tab) is decided nowhere. (3) minor: the file half's new HKDF name derivation says "its own info string, minus the boot UUID in the salt" without naming the string; readable out of persist.rs:405-431 but a guess. (4) minor: section 9 does not name the new FILE_MAGIC value or enumerate the "known superseded" magic set, and does not say whether the superseded-magic erase is the full erase_state discipline.

## The aging arithmetic, re-derived by the reviewer

Model per section 4: at save, drained = rung.duration() - remaining(now) on the monotonic clock, sealed_wall_ms = wall now, both inside the AEAD-authenticated header/payload; at restore, away = wall_now.saturating_sub(sealed_wall_ms), drained' = drained_saved + away.saturating_sub(hold_remaining), deadline rebuilt from rung.duration().saturating_sub(drained'), remaining derived not stored, drained nondecreasing except an explicit rung click. Scenario 1, page held across restart: gap G charged to the hold first. G < hold_remaining: hold shortened by G, drained unmoved, page returns held with frozen_remaining intact. G > hold_remaining: drained' = drained + (G - hold_remaining). Section 4 item 3, section 10 case 3's test list ("frozen_remaining intact and drained_ms unmoved... a longer gap drains only the excess"), and the hardware procedure ("a reboot with a page paused, confirming it returns paused") all say this consistently; the only wobble is section 1's definition of "survives" ("countdowns drained by the time that passed"), which overstates the held case (the hold drains, not the countdown) - wording, not contradiction, since section 4 governs. Scenario 2, saved and restored one minute later: away = 60000 ms, no hold, drained' = drained + 60000, remaining down one minute; matches the clean-quit row "pages are there with less time on them". No double-charge: drained_saved already contains all monotonic time up to the save, and post-restore aging starts from the restore instant. Scenario 3, clock stepped back before reboot: stamp T1 > wall_now, saturating_sub gives away = 0, drained unchanged, countdown frozen until wall clock re-passes T1 (self-healing: the next save restamps at the stepped-back now). Section 4 ("accepted freeze... allowed to happen silently"), section 10 case 7 ("ages the page by zero rather than negatively... accepted freeze... not a defect"), and the consequences bullet all agree. Scenario 4, sealed stamp ahead of current clock: mechanically identical to scenario 3; away = 0, "nothing is credited and nothing is charged", page returns with exactly the life it held, satisfying the never-rewinds invariant (equal, not more). Section 4 explicitly folds it into the same accepted freeze rather than a separate failure - correct. The inverse direction (stamp far in the past, e.g. clock stepped back mid-session then saved) over-drains, which costs life, and section 4 says so. Rollback of the whole file CAN rewind drained_ms; the invariant paragraph carves that out to section 8 explicitly. I found no arithmetic contradiction between sections 1, 4, 5, 8 and 10.

## Findings

### 1. [blocking] `0016-content-persists-across-restart.md`

> The store empties. This is already the condition under which the content file is dropped rather than resealed (shell/Sources/CompanionKit/PageModel.swift:683-695, :838-844)

**Problem.** This condition is redefined by ADR-0017, which ships in the same format break, and neither ADR reconciles it. The cited path keys on client.sheets().isEmpty (verified: erasesContentFile in PageModel.swift, is_empty at store.rs:279-280). Under the tab/page split, the sealed file also carries durable tab names, rungs and strip order, so an expiry that empties the pages cannot drop the file without destroying the tabs, and sheets().isEmpty stops meaning what this section needs it to mean. Every downstream claim inherits the hole: rotation trigger 1 ('rotating here is what makes an emptied pad a forgetting'), section 8's 'a ciphertext artifact... exists on disk continuously from the first save until the pad empties', and the consequence 'Both halves are removed when the store empties'. If empty means no tabs, rotation nearly never fires for a user with named tabs and the forgetting claim is hollow; if empty means no pages, the file must be resealed under rotated halves, not dropped, and section 8's sentence is false as written. ADR-0017's required work (items 1-12) never touches erasesContentFile or the persistErase leg. This is exactly the project's documented failure mode: a guarantee sentence no code path will make true.

**Suggestion.** Add one paragraph to ADR-0016 section 6 (or ADR-0017's required work) deciding it: define 'empties' as 'no tab holds a page AND no tab carries a user-set name' with drop, or as 'no pages' with rotate-and-reseal of tab metadata under the new halves. Then correct section 8's 'until the pad empties' sentence and the consequences bullet to match, and add erasesContentFile/is_empty to ADR-0017's reader list in item 5 with the chosen semantics.

### 2. [important] `0017-durable-tabs-expiring-pages.md`

> Selecting an empty tab mints a fresh page into it at the tab's rung, immediately on selection rather than lazily on first keystroke.

**Problem.** This rule conflicts with two other statements unless 'selection' is narrowed, and the ADR never narrows it. 'Expiry does not mint the replacement... The honest state at the 09:00 relaunch is an empty tab' and 'At launch with every tab empty... Return mints into the previously selected tab' both require that restored or reconciled selection NOT mint. But refresh() reconciles selection today (PageModel.swift:928-936), so when the selected tab's page expires live, the selected tab becomes an empty selected tab - and the mint-on-selection rationale (never unmount InkEditorView) applies to exactly that moment. An implementer must guess whether mint fires on user gesture only, and if so what the editor does when the selected tab's page dies under the cursor; the launch case with a mix of empty and live tabs (previously selected tab empty, another tab live) is also undecided.

**Suggestion.** State the trigger precisely: minting fires only on a user selection gesture (click, ⌘N-through-⌘9, ⌥⌘arrows), never from restore or from refresh() reconciliation; and say explicitly what the surface renders when the selected tab's page expires in place (the empty state of item 11, accepting the editor unmount, or an immediate mint - pick one and give the reason).

### 3. [important] `0016-content-persists-across-restart.md`

> This is accepted on the same argument as the clock case: the adversary is the logged in user, who can read the content out of the running app directly.

**Problem.** Overclaim in the justification of the replay exposure (section 8, repeated in the consequences bullet 'The last two adversaries can read the plaintext out of the running app'). The replay attacker is 'any process running as the user' - the ADR's own words two sentences earlier - and such a process can swap state.sealed (0600, user-owned) but can NOT in general read the running app's plaintext: task_for_pid is SIP/entitlement-gated, screen capture is TCC-gated, and the keychain ACL blocks it from deriving the key itself. What replay actually buys that process is resurrection of content the user believes destroyed, delivered through the app's own display and egress paths. The clock case's argument (setting the system clock takes the human operator with admin rights) does not transfer. The acceptance itself may still be right - one keychain write per 2s debounce save is a real price - but the stated reason is the sentence-that-sounds-right defect this project documented, and an auditor will catch it.

**Suggestion.** Reprice honestly: 'the replay adversary is any same-user process; it cannot read the key or the app's memory, but it can cause the app to resurrect and display content the ledger says is dead. Accepted because the defense costs one keychain write per save and the resurrected content still renders only inside the ACL-gated app.' Fix the consequences bullet to match.

### 4. [important] `0016-content-persists-across-restart.md`

> The residual exposure this accepts is one ADR-0012 already accepted in larger form: ADR-0012:82 keeps content-derived page titles under a long-lived, never-rotated key for a rolling ninety days

**Problem.** 'Larger form' is doing false work. Ninety days of 80-character derived first-line labels is not strictly larger than seven days of full secret bodies plus unlinked generations; a title is often the secret's label while the body IS the secret, and the same paragraph elsewhere concedes the generations are swept by nothing. This is the one softened sentence in an otherwise flat section 8, and it is the softening the review brief asked to hunt: an analogy standing in for a priced comparison.

**Suggestion.** Drop the comparative. State it as: 'ADR-0012 accepted content-derived labels under a long-lived key for ninety days; this accepts full bodies under a long-lived key for at most seven days of page life plus unswept generations. The second is a larger exposure per byte and a shorter one per calendar; both sit behind the same keychain ACL.' The decision survives the honest version.

### 5. [minor] `0016-content-persists-across-restart.md`

> Superseded wholesale: lines 34 to 51, the entire **Staged content, bounded to the boot session** subsection

**Problem.** Bookkeeping contradiction: lines 47 and 49 (keychain tiering and the 2026-08-10 amendment) sit inside the 34-51 range, and the very next list item declares them 'Left standing... carried forward and leaned on in section 3'. ADR-0012's own Supersession section repeats the same tension. 'Wholesale' is false; an auditor mapping supersession line by line stumbles on the first range they check.

**Suggestion.** Write 'lines 34 to 51 except 47 and 49' in both ADR-0016's header and ADR-0012's Supersession section.

### 6. [minor] `0016-content-persists-across-restart.md`

> "Survives" means: unexpired pages and their chips come back on the next launch, with their countdowns drained by the time that passed

**Problem.** Overstates the held-page case. Section 4 item 3 charges the away gap against a live hold first, so a held page's countdown is deliberately NOT drained by the time that passed when the gap fits inside the hold; section 10's own hardware procedure verifies exactly that ('a reboot with a page paused, confirming it returns paused'). Section 4 governs, so this is wording rather than a design contradiction, but the definition sentence is where a skimming implementer starts.

**Suggestion.** Amend to 'with their countdowns drained by the time that passed, or their holds shortened by it first per section 4'.

### 7. [minor] `0016-content-persists-across-restart.md`

> A file whose magic is a *known superseded* version is erased and the licence is granted, rather than left as a refusal.

**Problem.** Two small guesses left to the implementer: the set of known superseded magics is never enumerated (OTSSEAL2 only, or every prior magic?), the new FILE_MAGIC value is never named, and 'erased' is not pinned to the erase_state discipline (zero, truncate, unlink) versus a plain unlink. Section 9 is otherwise precise enough that these gaps stand out.

**Suggestion.** Name the new magic (e.g. OTSSEAL3), state that the superseded set is exactly {OTSSEAL2} at this break and grows by one per future break, and say the disposal is erase_state's zero-truncate-unlink path.

## Would you ship it

Yes, after fixing the blocking finding and the mint-on-selection ambiguity; both are a paragraph each, not a redesign. The decision is correct, honestly argued, and the arithmetic is internally consistent across all four scenarios I re-derived. The pair is the best-cited ADR work I have reviewed: required work is separated from shipped reality on every line, the reboot trap is documented against reimplementation, and the test matrix names what each change invalidates. What survived three verification rounds is exactly what the project's failure-mode note predicts: not broken guarantees inside either document, but a guarantee stretched across the seam between the two ('the store empties' means different things on each side of the tab/page split) plus two justifying sentences in section 8 that sound right and overclaim. Fix those four sentences and the seam paragraph, and this ships.

## Disposition

Added after the review, not part of it. All seven findings were applied, plus one
gap the review named in prose but did not number.

| # | Severity | Outcome |
|---|---|---|
| 1 | blocking | Applied. The maintainer decided the seam: "empties" means no tab holds a page, which rotates both halves and reseals surviving tab metadata under the new ones. The file is dropped outright only when no tabs remain. ADR-0016 section 6 states it, ADR-0017 states the object-graph half in "Emptying the pad is two predicates, not one", and ADR-0016 section 8's "until the pad empties" was corrected to "until the last tab is closed". |
| 2 | important | Applied. Minting fires only on a user selection gesture, never from restore and never from `refresh()` reconciliation. The expire-in-place case renders the empty tab state. |
| 3 | important | Applied. The replay exposure no longer borrows the clock case's argument. It names the adversary as any same-user process, states that it cannot read the app's memory or the key, and prices acceptance on the anti-rollback counter's keychain write per save. The matching eject trigger was corrected too. |
| 4 | important | Applied. The "already accepted in larger form" comparative is gone. Both exposures are stated flat, ending "Larger per byte, shorter per calendar." |
| 5 | minor | Applied. Both ADR-0016's header and ADR-0012's Supersession section now read "lines 34 to 51 except 47 and 49". |
| 6 | minor | Applied. Section 1 separates the running case from the held case and points at section 4. |
| 7 | minor | Applied. Section 9 names `OTSSEAL3` and `OTSSNAP4`, states the known superseded set is one entry at this break, and pins "erased" to `erase_state`'s zero, truncate, unlink discipline. |

The unnumbered gap was implementability item 3: section 3 described the file half's
name derivation as using "its own info string" without naming it. Section 3 now names
`BOOT_HALF_NAME_INFO` and `BOOT_HALF_NAME_SALT` and states that only the appended
`current_boot_uuid()` leaves the salt.

Two of the reviewer's disagreements were with justifying sentences rather than with the
decision, and both were rewritten rather than defended.
