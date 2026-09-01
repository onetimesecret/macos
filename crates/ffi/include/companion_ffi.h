/*
 * companion_ffi.h — C ABI for the Onetime Secret macOS companion core.
 *
 * This is the *entire* surface a non-Rust shell may call, speaking
 * interaction-model rev C (docs/spec/04): sheets of ink and sealed
 * chips. By construction it hands out only opaque handles, non-secret
 * JSON metadata (titles, counts, and a chip's mechanical excerpt in the
 * sheet-facing JSON; the ledger carries no excerpt at all), and action
 * results. It never hands out
 * a sealed byte. Sealed-byte movement stays in Rust: the sealed paste
 * reads the pasteboard in the core, copy-out writes it in the core.
 * The one deliberate plaintext-in entry is companion_sheet_seal_text()
 * (the ⌘↩ gesture): its argument is visible ink the shell's editor
 * already holds; after the call the shell deletes its copy. Keep this
 * header in sync with crates/ffi/src/lib.rs; a later milestone
 * generates it (cbindgen) rather than hand-maintains it.
 *
 * Memory rules:
 *   - Pointers returned by the *_json() and *_seal_*() functions are
 *     owned by the caller; free each with companion_string_free().
 *   - The CompanionHandle* from companion_new() is freed with
 *     companion_free().
 *   - companion_version() returns a static string; do NOT free it.
 *
 * Scheduling rule (no polling): arm ONE timer from
 * companion_next_event_ms() — it folds page expiries AND pause-hold
 * lapses; when it fires call companion_expire_due() and re-arm.
 * -1 means nothing to schedule.
 */

#ifndef COMPANION_FFI_H
#define COMPANION_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to the companion core. */
typedef struct CompanionHandle CompanionHandle;

/*
 * TTL ladder rung codes, in ascending order (docs/spec/04). Passed to
 * companion_tab_set_rung(); returned by companion_tab_cycle_rung().
 */
typedef enum {
    COMPANION_RUNG_1H  = 0,
    COMPANION_RUNG_3H  = 1,
    COMPANION_RUNG_8H  = 2,
    COMPANION_RUNG_24H = 3,
    COMPANION_RUNG_3D  = 4,
    COMPANION_RUNG_7D  = 5
} CompanionRung;

/* Process hardening (disable core dumps). Idempotent. */
void companion_init(void);

/* Static version string; do not free. */
const char *companion_version(void);

/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */

/*
 * How much attention one diagnostic line wants. The shell's two
 * reasonable responses: file it, or surface it as a failure.
 */
#define COMPANION_DIAG_NOTICE 0
#define COMPANION_DIAG_FAULT  1

/*
 * Where the core's diagnostics go. Metadata only: which step refused
 * and the backend's own error text, never ink, a chip, or key material.
 *
 * With no sink registered the lines go to stderr, which a terminal
 * launch reads and a double-clicked app does not: launchd hands the
 * process /dev/null, so the lines written for whoever is debugging a
 * failed launch are discarded before that launch happens. Register one
 * of these early (before the first restore) and forward each line to
 * the unified log, where `log show` reaches it after the fact.
 *
 * `message` is NUL-terminated UTF-8, borrowed for the duration of the
 * call only: copy whatever you keep. It may arrive on any thread. The
 * sink must not call back into the core.
 *
 * Pass NULL to put the lines back on stderr.
 */
typedef void (*CompanionDiagnosticSink)(int32_t level, const char *message);
void companion_set_diagnostic_sink(CompanionDiagnosticSink sink);

/* Lifecycle. Freeing the handle wipes every sealed byte it holds. */
CompanionHandle *companion_new(void);

/* As companion_new(), with Keychain items scoped to `service` rather
 * than the default "com.onetimesecret.companion". A second form factor
 * passes its own bundle id so its state key is its own item, granted to
 * its own code identity; sharing one item across two signed binaries
 * would make each one's first read a confirmation prompt for the
 * other's key. Null or empty falls back to the default scope. */
CompanionHandle *companion_new_scoped(const char *service);

/* As companion_new_scoped(), but the credentials rest in ordinary
 * process memory rather than any OS keychain: keys minted through this
 * handle never reach the login Keychain and die with the process.
 * Handles created with the same `tag` share one store, so a file
 * sealed through one can be opened through another in the same
 * process. A test seam for the shell's persistence suite; the shipping
 * form factors never call it. Null or empty falls back to one unnamed
 * scope. The symbol exists only in test-util builds of the core
 * (ADR-0018; scripts/build-core.sh --test-util): a release build does
 * not export it, so a caller linking against one fails at link time
 * rather than falling back to anything. The declaration stays because
 * a C header carries no cargo features. */
CompanionHandle *companion_new_ephemeral(const char *tag);

/* Age every staged page by `gap_ms` of wall time, the way a relaunch
 * after a night away ages them: the store is snapshotted at one wall
 * reading and restored at a later one, which is the same arithmetic the
 * restore does and the only one that moves a countdown without waiting
 * for it. Nothing expires here, the caller follows with
 * companion_expire_due(), as the shell's armed timer does, and both id
 * counters are re-minted densely as at any restore, so the caller reads
 * ids back from the summaries afterwards. A test seam for the states on
 * the far side of a countdown: a tab standing empty, a slot reused by a
 * second page. The symbol exists only in test-util builds of the core
 * (ADR-0018), on the same terms as companion_new_ephemeral() above. */
bool companion_test_age_ms(CompanionHandle *handle, uint64_t gap_ms);

void companion_free(CompanionHandle *handle);

/* ------------------------------------------------------------------ */
/* Tabs: the durable slots                                             */
/* ------------------------------------------------------------------ */

/*
 * Two objects, two ids, and the routes split between them (ADR-0017).
 * A tab is a durable slot: an identity, a name the user may type, a
 * rung, a place in the strip, and at most one page. A page is
 * everything that expires: the ink, the chips, the clock. On expiry
 * the page is dropped whole and the tab stays where it is, empty and
 * reusable, and the strip still shows it.
 *
 * The routes below take a TAB id. The sealing, document, conceal and
 * meta routes further down take a PAGE id, which the summary carries
 * as page_id. The two counters are unrelated: never pass one where the
 * other belongs, and never derive one from the other.
 */

/*
 * A new tab at the end of the strip, holding a new page on the default
 * rung with its countdown running. Returns the TAB's id, or 0 when the
 * store refused at the cap of 9, the keyboard wall; the app declines
 * the tenth and says so (0 is never a valid id).
 */
uint64_t companion_tab_new(CompanionHandle *handle);

/*
 * Mint a page into a tab that holds none, at THAT TAB's rung. Returns
 * the new page's id, or 0 for an unknown tab and for one that already
 * holds a page. This is the route every deliberate mint into an
 * existing slot takes: a click on the tab, cmd-1..9, opt-cmd-left or
 * right, and the Return grant. Expiry never mints, so a countdown that
 * ran out overnight leaves an empty tab rather than a fresh countdown
 * on nothing.
 */
uint64_t companion_tab_open_page(CompanionHandle *handle, uint64_t tab);

/*
 * Close a tab: whatever page it holds rests in the ledger like an
 * expired one, sealed bytes zeroized, and the slot leaves the strip.
 * An empty slot closes as readily as a full one. Returns whether the
 * tab existed. Explicit close and the cap are the only two things that
 * end a tab.
 */
bool companion_tab_close(CompanionHandle *handle, uint64_t tab);

/*
 * Discard the page a slot holds and leave the slot standing: sealed
 * bytes zeroized, one discarded record in the ledger, and the tab keeps
 * its name, its rung, its position and its number key. Returns whether
 * a page by that id was standing. Page addressed because the burn
 * offered after a conceal names the content that travelled and not
 * the slot it travelled from.
 */
bool companion_page_discard(CompanionHandle *handle, uint64_t page);

/*
 * Move a tab to `index` in visible order (drag-to-reorder; the
 * command-number map follows). Out-of-range clamps to the end.
 */
bool companion_tab_move(CompanionHandle *handle, uint64_t tab,
                        uint64_t index);

/*
 * Name a tab explicitly (the rename gesture in the tab context menu).
 * An empty or all-whitespace title clears the name, and the label falls
 * back to the live page's derived title and then to the tab's own
 * creation stamp. Anything else is trimmed, capped at 80 characters,
 * and from then on sticky: editing the page never overwrites it, and
 * neither does the page dying. Returns whether the tab existed.
 *
 * The name is the one piece of user-typed text that reaches the ledger,
 * so a secret typed into the rename field lands in the audit record and
 * stays on the strip until the tab is closed. Documented exception, not
 * an accident; the cap bounds it, and the app never derives one.
 */
bool companion_tab_set_title(CompanionHandle *handle, uint64_t tab,
                             const char *title);

/*
 * JSON array of non-secret tab summaries, in visible (strip) order: one
 * entry per slot, whether or not it holds a page. Free with
 * companion_string_free(). Fields per tab:
 *   id (the TAB's id, what the selection and the keyboard address),
 *   has_page (bool, false is a slot whose page expired or was never
 *     opened; every clock field below is meaningless then, and the
 *     strip draws the dashed empty treatment instead of a gauge),
 *   page_id (the PAGE's id, or null when has_page is false, what the
 *     sealing and document routes address, and what a shell-side
 *     storage map is keyed by),
 *   title (the tab's label, resolved three ways: the name the user
 *     typed; else the live page's derived title, its first non-empty
 *     ink line with markdown stripped, capped at 80 characters; else
 *     "MMDD-HHmm" from the TAB's creation stamp in LOCAL time),
 *   rung_code (CompanionRung), rung_label ("8h"), both the tab's,
 *   remaining_ms, remaining_label ("3h 40m"), spoken_remaining ("about
 *     3 hours remaining", the VoiceOver value), fraction_remaining
 *     (0.0..1.0), paused (bool), hold_topped_up (bool, the hold is
 *     already at its 24 hour ceiling, so the next pause press releases
 *     it), hold_remaining_ms, chip_count, last_hour (bool),
 *   page_has_content (bool, whether the page holds anything: ink that
 *     is more than whitespace, or at least one chip. It is the same bar
 *     the ledger applies when it decides whether a dying page did
 *     anything worth recording, answered core-side so there is one
 *     definition of it rather than two that drift; false whenever
 *     has_page is false. A boolean and never text: do not read a
 *     document to answer this),
 *   page_day_offset (int64 or null: which local day the PAGE was born
 *     on, counted RELATIVE to today. 0 for a page made today, -1 for
 *     one made yesterday, and so back; a positive value can only mean
 *     the host clock went backwards since the page was made. The stamp
 *     is the PAGE's own and not the tab's, because a slot opened last
 *     week takes today's page and the tab's birthday would file it
 *     under a day nobody was here. Computed with the store's own UTC
 *     offset, the one the MMDD-HHmm placeholder above renders from, so
 *     the label and the day can never disagree; computed afresh on
 *     every call rather than cached, which is how a surface's labels
 *     roll over at local midnight without a timer. Null exactly when
 *     has_page is false: a slot holding no page is on no day).
 */
char *companion_tabs_json(CompanionHandle *handle);

/*
 * The two emptiness predicates, both of them, in one call. Writes
 * whether no tab holds a page and whether no tabs remain; returns
 * false when the handle or the lock will not answer, having written
 * false into both, which is the reading that changes nothing. Either
 * output may be null.
 *
 * They are separate because emptying the pad is two questions
 * (ADR-0017). "No tab holds a page" is the key rotation trigger: rotate
 * both halves and reseal the surviving tab names, rungs and order under
 * the new ones, which is companion_persist_rotate_and_save(). "No tabs remain" is the one condition for dropping the
 * sealed file. Wiring them backwards destroys the tabs an expiry was
 * supposed to leave standing, or leaves the install on one content key
 * for as long as any tab exists. Do not recompute either one from the
 * summary array: the first is a security decision and it must be the
 * core's answer that fires the rotation.
 */
bool companion_store_emptiness(CompanionHandle *handle,
                               bool *holds_no_page_out,
                               bool *has_no_tabs_out);

/* ------------------------------------------------------------------ */
/* Sealing — the gesture routes                                        */
/* ------------------------------------------------------------------ */

/*
 * The sealed paste (shift-cmd-V): the core reads the pasteboard itself
 * and seals whatever it holds — text or image, unread, unclassified;
 * consent is the gesture — then clears the board in the same locked
 * operation, so the secret's pasteboard dwell ends the moment it is
 * staged (ADR-0007 Amendment 1). A refused seal clears nothing.
 * Returns the chip's JSON (free with companion_string_free()):
 *   chip_id, kind ("text"|"image"), excerpt (the mechanical face —
 *   the only rendering the content ever gets), size_label ("40 ch",
 *   "5 ln", "212 KB"), concealed (bool).
 * Null when the board is empty, the page unknown, content empty, or
 * the range not on the page.
 * at_utf16/len_utf16 name the selection the gesture replaces, in
 * UTF-16 code units against the page's body (ADR-0013): the core
 * deletes that range, stands the chip's sentinel in its place, and
 * commits, all in this one locked call. A caret is a zero-length
 * range; a range the body does not have refuses the whole seal and
 * takes nothing from the board.
 * cleared_out (nullable) reports the clear: false after a successful
 * seal means another writer moved the change count mid-take, the
 * guarded clear stood down, and the shell must say so.
 * When the board declares a public.url origin, the core captures it in
 * the same read and persists it inside the sealed snapshot (ADR-0013).
 * The origin is content: it appears in no JSON this seam returns.
 */
char *companion_sheet_seal_from_pasteboard(CompanionHandle *handle,
                                           uint64_t sheet,
                                           uint32_t at_utf16,
                                           uint32_t len_utf16,
                                           bool *cleared_out);

/*
 * Whether the pasteboard holds content a sealed paste could take:
 * non-empty, representable (text or image), and not the companion's
 * own transient copy-out. Answered from type metadata alone; content
 * bytes never cross for a yes/no. Powers the summon-time offer
 * (ADR-0007 Amendment 1).
 */
bool companion_pasteboard_has_content(CompanionHandle *handle);

/*
 * The cmd-return retrofit: seal `text` (the selection, or the current
 * line) onto the page. The seam's one deliberate plaintext-in entry:
 * the argument is visible ink the shell already holds, readable on
 * screen by definition; the gesture moves it into core custody.
 * at_utf16/len_utf16 name the sealed span in UTF-16 code units: the
 * core deletes it from the body and stands the sentinel in its place
 * in the same locked call, so the shell no longer deletes its copy by
 * an edit of its own; undo never un-seals. Returns chip JSON as
 * above, or null (unknown page, empty text, or a range not on the
 * page).
 */
char *companion_sheet_seal_text(CompanionHandle *handle, uint64_t sheet,
                                const char *text, uint32_t at_utf16,
                                uint32_t len_utf16);

/*
 * Drop-to-seal: the core reads the DRAG pasteboard itself
 * (NSPasteboardNameDrag — the board the in-flight drag session's
 * content rides on) and seals it onto the page; dropped bytes never
 * transit the shell. Call from the drop handler while the session's
 * data is still on the board. at_utf16/len_utf16 name the drop point
 * as a UTF-16 range against the page's body, replaced by the sentinel
 * in the same locked call; a plain drop is a zero-length range at the
 * insertion index. Returns chip JSON as above, or null (unknown page,
 * empty/unreadable drag content, a range not on the page, off-macOS
 * build).
 */
char *companion_sheet_seal_from_drag(CompanionHandle *handle, uint64_t sheet,
                                     uint32_t at_utf16, uint32_t len_utf16);

/* ------------------------------------------------------------------ */
/* The document: operations, and the snapshot recovery path            */
/* ------------------------------------------------------------------ */

/*
 * Apply an ordered batch of edits to a page's body (ADR-0013): the
 * operation path that replaces per-keystroke snapshots. json is an
 * ordered array, each element exactly one of
 *   {"ins":  {"at": u32, "text": s}}
 *   {"del":  {"at": u32, "len": u32}}
 *   {"chip": {"at": u32, "id": u64}}
 * with positions and lengths in UTF-16 code units against the body as
 * the batch's earlier ops leave it. Parsing is reject-whole; a batch
 * that parses is validated whole against the page and applied
 * atomically or not at all. Chip liveness follows the document: a
 * delete that swallows a chip's sentinel zeroizes the chip. Returns
 * whether the batch applied; on false, restate the page through
 * companion_sheet_sync_document (the recovery path).
 */
bool companion_sheet_apply_ops(CompanionHandle *handle, uint64_t sheet,
                               const char *json);

/*
 * Replace a page's document wholesale: a JSON array of runs in document
 * order — {"ink": "text"} for visible ink, {"chip": id} where a chip
 * sits. Since edits travel as operations (companion_sheet_apply_ops),
 * this survives as the RECOVERY path: a page restated whole after a
 * rejected batch, at the price of that page's provenance. STILL
 * AUTHORITATIVE FOR CHIP LIVENESS: a chip the snapshot omits was
 * deleted in the editor and is zeroized here. Malformed snapshots (bad
 * JSON, foreign chip, duplicate reference) are rejected whole. Returns
 * acceptance.
 */
bool companion_sheet_sync_document(CompanionHandle *handle, uint64_t sheet,
                                   const char *json);

/*
 * A live page's document, replayed for a shell rebuilding its editor
 * after companion_persist_restore(): a JSON array of runs in document
 * order — {"ink": "text"} for visible ink, {"chip": {…}} where a chip
 * sits, the chip object carrying the same non-secret face the seal
 * routes return (chip_id, kind, excerpt, size_label, concealed). Ink
 * renders anyway; a chip crosses as its face, never its bytes. Free
 * with companion_string_free(). Null for an unknown page.
 */
char *companion_sheet_document_json(CompanionHandle *handle, uint64_t sheet);

/*
 * A page's provenance, derived from its operation log (ADR-0013):
 *   {"created_ms": u64, "modified_s": i64|null}
 * created_ms is the page's creation stamp (epoch ms, the figure the
 * summaries already carry); modified_s is the newest change's commit
 * timestamp in Unix SECONDS, null for an untouched body. Deliberately
 * nothing else: origin URLs are content and appear on no JSON
 * surface. Free with companion_string_free(). Null for an unknown
 * page.
 */
char *companion_sheet_meta_json(CompanionHandle *handle, uint64_t sheet);

/*
 * A page's blocks in document order:
 *   [{"id": uuid, "created_s": i64|null, "modified_s": i64|null,
 *     "paragraphs": u32}, …]
 * The id is the block's random identity, stable across edits inside
 * the block and following the split-keeps-the-first, merge-keeps-
 * the-absorber convention across the ones that are not. Stamps are
 * Unix seconds derived from the operation log, null for a block with
 * no committed content. "paragraphs" is how many paragraphs the block
 * covers: one usually, more where a paste kept its lines together, so
 * one stamp stands above a pasted passage rather than one above each
 * of its lines. Identities, timestamps, and that reach ONLY: no text,
 * no sizes, no origin. Free with companion_string_free(). Null for an
 * unknown page.
 */
char *companion_sheet_blocks_json(CompanionHandle *handle, uint64_t sheet);

/* ------------------------------------------------------------------ */
/* Chips                                                               */
/* ------------------------------------------------------------------ */

/*
 * Copy a chip back out: the core writes the pasteboard itself, marked
 * transient AND ConcealedType (a chip is sealed by definition). Does
 * not consume the chip — multi-paste is a core moment. Returns whether
 * the chip existed.
 *
 * A successful copy-out is an auditable egress: it leaves one "sent"
 * ledger record with destination "clipboard". The pasteboard is the
 * boundary the app cannot follow the bytes past.
 */
bool companion_chip_copy_out(CompanionHandle *handle, uint64_t chip);

/*
 * Remove a chip now, wiping its bytes (backspace removes it whole;
 * there is no resurrection path). Returns whether it existed.
 */
bool companion_chip_delete(CompanionHandle *handle, uint64_t chip);

/*
 * Clear the pasteboard iff it still holds our last copy-out (change-
 * count guarded; never clobbers a newer copy). Returns whether a clear
 * happened.
 */
bool companion_clear_clipboard_if_ours(CompanionHandle *handle);

/* ------------------------------------------------------------------ */
/* Time: the ladder, the pause, the one armed timer                    */
/* ------------------------------------------------------------------ */

/*
 * Milliseconds until the next scheduled instant — the earliest page
 * expiry or hold lapse. The ONE timer to arm. -1: nothing to schedule.
 * 0: something is already due.
 */
int64_t companion_next_event_ms(CompanionHandle *handle);

/*
 * Settle the clock: lapsed holds normalize; every page at zero moves
 * to the ledger, sealed bytes zeroized. Returns how many pages
 * expired. Call on timer fire, then re-arm.
 */
uint64_t companion_expire_due(CompanionHandle *handle);

/* Cycle a TAB's countdown one rung SHORTER (clock reset to the full
 * rung, each click resets the clock). The ladder tapers, 7d -> 3d ->
 * 24h -> 8h -> 3h -> 1h, and wraps back to 7d at the bottom, so the
 * most precarious rung is five clicks away rather than one. Returns the
 * new code, or -1 if the tab is gone. A tab holding no page takes the
 * shorter rung and keeps it for its next page: the rung is the slot's
 * property and never a countdown of the slot's own. */
int companion_tab_cycle_rung(CompanionHandle *handle, uint64_t tab);

/* Set a TAB to an explicit rung (its page's clock reset to it). Returns
 * success; a tab holding no page stores the rung and succeeds, having
 * no clock to reset. */
bool companion_tab_set_rung(CompanionHandle *handle, uint64_t tab, int rung);

/*
 * The pause gesture (double-click a tab), a three state cycle: first
 * press holds the clock 1 hour; a press while held tops the hold up to
 * 24 hours from now — never cumulative; a press while topped up
 * releases the hold and the countdown resumes where it froze. Holds
 * the clock, never extends the rung. An unreleased hold lapses on its
 * own (folded into companion_next_event_ms()). Returns false for an
 * unknown tab, one holding no page, and one whose page is already due.
 * The summary's hold_topped_up says which press comes next.
 */
bool companion_tab_pause_press(CompanionHandle *handle, uint64_t tab);

/* ------------------------------------------------------------------ */
/* The ledger                                                          */
/* ------------------------------------------------------------------ */

/*
 * The ledger (cmd-0): an audit trail of what the app did with items,
 * newest first, read-only, held to a rolling 90-day window on the
 * records' own wall-clock stamps. It is METADATA ONLY: no ink, no
 * excerpts, no tombstones. Free with companion_string_free().
 *
 * Fields per record:
 *   event         "created"|"sealed"|"sent"|"expired"|"discarded"
 *   item          the item's random UUID, lowercase hyphenated 8-4-4-
 *                 4-12, 36 characters. PLAIN: no digest and no salt,
 *                 because an identifier an auditor cannot line up
 *                 across records is not an audit trail
 *   title         the host page's title at the moment of the event.
 *                 The only page-owned text on a record, capped at 80
 *                 characters core-side
 *   at_ms         when it happened, Unix epoch milliseconds
 *   created_at_ms when the item's page was created, epoch milliseconds
 *   size          "tiny"|"small"|"medium"|"large"|"huge", a coarse
 *                 bucket, never a byte count
 *   destination   "none"|"clipboard"|"link"
 *
 * Records accumulate on ordinary use, not only on death: a page's
 * creation, each seal, each egress, each discard. Do not assume an
 * empty ledger for a session in which pages were merely opened.
 */
char *companion_ledger_json(CompanionHandle *handle);

/*
 * Throw the whole ledger away: the user-facing "clear the ledger"
 * affordance. The records outlive the pages they describe by design, so
 * a way to end them on demand is part of that bargain. In-memory only: call
 * companion_ledger_save() afterwards for the empty ledger to reach the
 * file.
 */
void companion_ledger_clear(CompanionHandle *handle);

/*
 * Save the ledger to `path`, sealed with ChaCha20-Poly1305 under its
 * OWN 32-byte key ("ledger-key" account, minted on first save) and its
 * own envelope magic. That key is SEPARATE and LONG-LIVED: it is not
 * the two-half content key and never rotates with it. That is the whole
 * point: the audit record survives the emptying that forgets the staged
 * content it describes, and a content-key rotation must never touch it. The two
 * files are not interchangeable; each magic is its own AEAD associated
 * data, so presenting one as the other fails authentication.
 *
 * The bytes are metadata plus capped titles, never content, so this
 * file resting on disk indefinitely is the intended outcome. The write
 * is atomic and owner-only. Call it beside companion_persist_save(),
 * behind the same debounce.
 *
 * A save first sweeps the rolling 90-day window off the LIVE ledger,
 * so this mutates the in-memory records and not only the file: a
 * record that aged out is gone from companion_ledger_json() after a
 * save, without waiting for a restart to load it away. The window is
 * the same one companion_ledger_restore() applies, so the two paths
 * cannot disagree about what is retained.
 *
 * Returns success. False now also covers an unreadable wall clock,
 * because the sweep has no window to measure without one and writing
 * an unswept file would put records back that the load path drops.
 */
bool companion_ledger_save(CompanionHandle *handle, const char *path);

/*
 * Restore the ledger from a file companion_ledger_save() wrote:
 * decrypt under "ledger-key" (loaded, never minted), replace the
 * in-memory records, and drop everything outside the rolling 90-day
 * window as it loads. Nothing here ages a countdown and nothing
 * expires a page. Call at startup, beside and independent of
 * companion_persist_restore(): either may succeed while the other
 * fails, and the shell should licence each save on its own restore.
 * Returns whether a ledger was restored. False covers "no file yet"
 * (a fresh start, not an error) as well as a missing key, failed
 * authentication, or a damaged snapshot.
 */
bool companion_ledger_restore(CompanionHandle *handle, const char *path);

/* ------------------------------------------------------------------ */
/* Persistence: the sealed state file, bounded by its TTL and by policy */
/* ------------------------------------------------------------------ */

/*
 * Save the staged content (sheets, sealed chips, clocks) to `path`,
 * encrypted (ChaCha20-Poly1305) under HKDF of a keychain half and a
 * file half, the file half being a 0600 file in the same directory as
 * `path` (ADR-0016). Neither half alone unwraps anything, and no key
 * byte crosses this seam: the shell passes a path and receives a bool.
 *
 * The envelope stamps itself with the wall clock at the save, inside
 * the authenticated header, so a file cannot be re-dated to buy the
 * pages in it more life. That stamp measures one thing: the gap until
 * the next restore, which is the interval no process of this app was
 * running to observe. The ledger is NOT in this file; it has its own
 * file under its own long-lived key (companion_ledger_save), because
 * the two have different lifetimes and different keys.
 *
 * Only ciphertext touches disk; the write is atomic and owner-only.
 * Call on every mutation, debounced, and once more at quit to flush
 * what is still pending; the core saves nothing on its own. Returns
 * success.
 */
bool companion_persist_save(CompanionHandle *handle, const char *path);

/*
 * Rotate both content key halves and reseal the store under the new
 * ones: the write for the moment no tab holds a page (ADR-0016 section
 * 6's first rotation trigger, ADR-0017). Returns whether the file at
 * `path` now holds the store under halves nothing else has ever sealed
 * with.
 *
 * The rotation is the forgetting and the reseal is what keeps the
 * strip. Erasing the file half makes every ciphertext generation this
 * key ever sealed undecryptable at once, including the ones an atomic
 * rename unlinked and nothing sweeps. What is then written carries tab
 * names, rungs and strip order and no page content, because by the time
 * this is called there is none. companion_persist_erase() is the other
 * half of the pair and takes the other predicate: no tabs remain, so
 * there is nothing left to reseal and the file goes.
 *
 * A rotation that could not erase the half CANCELS the write and this
 * returns false, leaving the old generation on disk under the old
 * halves: writing anyway would seal the new generation under the key
 * that still opens every earlier one and would report a forgetting that
 * did not happen. The false is what arms the caller's retry. A path
 * that is not the content file is refused outright rather than rotated,
 * on the same gate a drop uses: the ledger rests under its own
 * long-lived key.
 *
 * The window between the erase and the write is one where the strip
 * exists only in memory, so a crash inside it costs the tab names,
 * rungs and order, and nothing else. The in-memory store is untouched:
 * this rewrites a file, not a page.
 */
bool companion_persist_rotate_and_save(CompanionHandle *handle, const char *path);

/*
 * Restore from a state file companion_persist_save() wrote: decrypt
 * (both key halves loaded, never minted), replace the store's sheets,
 * and drain every countdown by the time that passed while the app was
 * closed; pages that came due while away expire into the ledger
 * immediately. Call at startup, before creating the first page.
 *
 * A FILE THIS CALL CANNOT OPEN IS NEVER DESTROYED BY IT. A missing
 * key, a failed authentication and a snapshot the core rejects all
 * leave the file where it is, so the probe the shell takes afterwards
 * sees it and withholds this session's save licence rather than
 * writing over content nobody could read. The one exception is not a
 * failure to open: a file carrying an envelope this build has REPLACED
 * is dropped and the licence granted, because nothing in it can ever
 * be read again and refusing it forever would present as an install
 * that had permanently stopped saving (ADR-0016 section 9).
 *
 * Launch is also where stranded *.tmp generations in the state
 * directory are swept; nothing else ever clears that directory.
 *
 * Time away is the wall-clock gap between the file's sealed stamp and
 * now, which is the one interval this app measures by the calendar: the
 * monotonic clock restarts with the machine and cannot measure it. A
 * clock stepped backwards therefore freezes a countdown for the length
 * of the gap and can never rewind one.
 *
 * Returns whether a state was restored. False covers "no file yet" (a
 * fresh start, not an error) and a superseded file just dropped, as
 * well as a missing key, failed authentication, an unreadable wall
 * clock, or a damaged snapshot.
 */
bool companion_persist_restore(CompanionHandle *handle, const char *path);

/*
 * Drop the state file at `path`: rotate the content key halves, then
 * overwrite, truncate, sync, unlink.
 *
 * The rotation is what forgets. Deleting the keychain half makes every
 * ciphertext generation that key ever sealed undecryptable, including
 * the ones an atomic rename unlinked and nothing sweeps, and it is the
 * finishing step of a deletion the user already asked for: emptying the
 * pad, or clearing it (ADR-0016 section 6). It runs first, so what is
 * unlinked is already undecryptable, and a keychain that refuses the
 * delete is announced without cancelling the drop.
 *
 * ONLY a content file takes the halves with it. This same call drops
 * the ledger file on a user's Clear, and that gesture asked nothing
 * about pages, so the rotation is gated on the envelope magic actually
 * at the path rather than on the caller's intent.
 *
 * The open refuses to follow a FINAL symlink and refuses to block, so a
 * FIFO planted at the name cannot park the call; the writes then refuse
 * anything that is not a regular file. That is the whole of the check,
 * and it is narrower than it sounds: a HARD link at the path is a
 * regular file and IS zeroed and truncated, a symlinked PARENT
 * directory is never examined, and the link and blocking refusals are
 * open flags the shipping platform happens to carry. What contains this
 * is that `path` lives in the owner-only, app-owned state directory the
 * shell chose; the checks only limit what a foothold there is worth.
 *
 * Returns whether nothing is at the path, answered WITHOUT following a
 * link, including when there was nothing to begin with. A dangling
 * symlink left at the path is something, so that reports false even
 * though the name resolves to nothing.
 *
 * NOT erasure, and it must not be described as erasure. The filesystem
 * is copy on write, so the zeros are as likely to land in fresh blocks
 * as over the old ones; the rotation above is what actually forgets.
 * Call this when the store empties, so the last ciphertext generation
 * does not sit on disk for the rest of the session describing nothing.
 *
 * The in-memory store is untouched: this deletes a file, not a page.
 */
bool companion_persist_erase(CompanionHandle *handle, const char *path);

/* ------------------------------------------------------------------ */
/* Conceal: the exit ramp, an explicit user action                    */
/* ------------------------------------------------------------------ */

/*
 * Configure where a conceal goes. json (non-secret except the token in
 * transit):
 *   { "server_url": "https://…",   // required, https only
 *     "share_domain": "…",         // "" -> the server's host
 *     "extid": "…",                // "" -> guest-only
 *     "token": "…" }               // absent: keep stored token;
 *                                  // "": delete it
 * The token goes straight to the OS credential store (Keychain) and is
 * never retained in config. Returns false on malformed JSON or a
 * non-https URL.
 */
bool companion_connection_configure(CompanionHandle *handle, const char *json);

/*
 * Connection state for Settings, never the token itself. Free with
 * companion_string_free(). Fields: configured, server_url,
 * share_domain, extid, has_token. has_token is an existence check —
 * decided without reading the secret, so rendering Settings at launch
 * never triggers the Keychain prompt; that is reserved for the read a
 * conceal needs.
 */
char *companion_connection_json(CompanionHandle *handle);

/*
 * The Settings "test" button: one GET /api/v3/status. BLOCKS for the
 * round-trip — call from a background queue. Returns {"ok"} or
 * {"ok": false, "error"}; free with companion_string_free().
 */
char *companion_connection_test(CompanionHandle *handle);

/*
 * Conceal one sealed chip into a one-time link (the chip's hover ↗).
 * opts_json: {"ttl_secs"?, "passphrase"?, "recipient"?} or NULL (TTL
 * defaults to the page's remaining time snapped DOWN the ladder).
 * Sealed bytes travel core -> client -> transport, never through the
 * caller. On success the share link is on the clipboard (transient)
 * and only the receipt id stays on the chip. BLOCKS for the round-trip
 * — call from a background queue; the core mutex is released during
 * the network call. Returns {"ok": true, "receipt_id"} or
 * {"ok": false, "error"}; free with companion_string_free().
 */
char *companion_chip_conceal(CompanionHandle *handle, uint64_t chip,
                             const char *opts_json);

/*
 * Conceal the whole page (the footer's ↗ page): ink verbatim, sealed
 * bytes inlined in document order. Refuses a page holding an image
 * chip. Options, blocking, and result shape as companion_chip_conceal.
 * No per-chip mark is set, the link stands for the page, but the
 * egress is recorded: one "sent" record against the page's own
 * identity, destination "link", with a size class and no content.
 */
char *companion_sheet_conceal(CompanionHandle *handle, uint64_t sheet,
                              const char *opts_json);

/* ------------------------------------------------------------------ */
/* Sync sign-in (issue #98): account auth for the relay channel       */
/* ------------------------------------------------------------------ */

/*
 * Configure sync's endpoints and client identity. json (non-secret):
 *   { "relay_url": "https://…",      // required, https only
 *     "authorize_url": "https://…",  // required, https only
 *     "token_url": "https://…",      // required, https only
 *     "client_id": "…" }             // required, non-empty
 * Like the conceal connection this is not persisted core-side — the
 * shell re-sends it at launch — but configuring resumes the persisted
 * sign-in: the refresh token loads from its own Keychain account, so a
 * relaunch is signed in without a browser. Returns false on malformed
 * JSON, a missing field, or a non-https URL.
 */
bool companion_sync_configure(CompanionHandle *handle, const char *json);

/*
 * Sync's standing state for Settings: {"configured", "signed_in",
 * "gate", "signin_pending", "attached", "epoch", "frame_present",
 * "enrolled", "pairing"}. Existence checks and in-memory reads only,
 * so rendering Settings never decrypts a credential, wedges on the
 * Keychain, or waits on the network. Free with
 * companion_string_free().
 */
char *companion_sync_status_json(CompanionHandle *handle);

/*
 * Where the account gate stands, as one machine token (ADR-0027
 * section 5): "off", "signed_out", "signing_in", "refused",
 * "unreachable", "ready" or "attached". The same value the status
 * JSON carries as "gate", for a caller that wants the one word
 * without the rest. It says whether this client may attach to the
 * channel and nothing about content: passing this gate without
 * pairing downloads ciphertext that will not open. Null on a null
 * handle. Free with companion_string_free().
 */
char *companion_sync_gate(CompanionHandle *handle);

/*
 * Begin the sign-in ceremony (account-auth.md section 1): bind the
 * one-shot loopback listener, mint the PKCE material, and return
 * {"ok": true, "authorize_url"} for the shell to open in the SYSTEM
 * browser — never a web view. Then call companion_sync_signin_finish
 * from a background queue. {"ok": false, "reason"} with "busy" while a
 * ceremony already waits, "not_configured", "port" (the listener could
 * not bind), or "no_entropy". Free with companion_string_free().
 */
char *companion_sync_signin_begin(CompanionHandle *handle);

/*
 * Finish the sign-in ceremony: wait for the browser's one redirect,
 * redeem the code, and persist the rotated refresh token in its own
 * Keychain account. BLOCKS for up to patience_ms — call from a
 * background queue; account-auth.md section 5 budgets five minutes,
 * because the user is reading a consent screen. The core mutex is held
 * only at the edges; the pad never waits on this. Returns {"ok": true}
 * or {"ok": false, "reason"} with the section-5 tokens: "abandoned",
 * "state_mismatch", "no_code", "unreachable", "refused",
 * "no_ceremony", "keychain". Every failure leaves nothing stored;
 * retry is a fresh begin. Free with companion_string_free().
 */
char *companion_sync_signin_finish(CompanionHandle *handle,
                                   uint64_t patience_ms);

/*
 * Forget a begun, unfinished sign-in ceremony: the listener closes and
 * the PKCE material drops. True when there was one to forget. A finish
 * already blocking is not interrupted — it owns the listener by then.
 */
bool companion_sync_signin_cancel(CompanionHandle *handle);

/*
 * Sign sync out: drop the held tokens and delete the persisted refresh
 * token — exactly one Keychain account. The conceal token, the content
 * and ledger keys, and the pairing accounts all stand; the pad is
 * unaffected, which is the point. True when the delete was accepted.
 */
bool companion_sync_signout(CompanionHandle *handle);

/* ------------------------------------------------------------------ */
/* Sync engine (issue #102): enrolment, the pump, and pairing         */
/* ------------------------------------------------------------------ */

/*
 * Enrol a page into the sync channel, or withdraw it — per page and
 * off by default (relay protocol section 1). Enrolling defers the
 * page's compaction to the coordinated ceremony and starts its delta
 * cursor at the beginning, so the first publish carries the whole
 * page; withdrawing returns it to solo behaviour, performing any due
 * ceremony on the spot. page is the PAGE id.
 */
bool companion_sync_enrol_page(CompanionHandle *handle, uint64_t page,
                               bool enrolled);

/*
 * Attach to the account's channel: ensure the device identity and
 * channel secret (the first device to enable sync founds the channel;
 * a joiner's secret arrives by pairing and overwrites), mint and
 * publish a fresh key package, adopt the relay's cursor. BLOCKS for
 * the round-trips — call from a background queue. Returns
 * {"ok": true, "epoch", "frame_present", "peers"} or
 * {"ok": false, "reason"}: "not_configured", "signed_out",
 * "keychain", "unreachable", "refused". Free with
 * companion_string_free().
 */
char *companion_sync_attach(CompanionHandle *handle);

/*
 * Detach: tell the relay (best effort; idle attachments age out
 * regardless) and dissolve the engine, keeping the sign-in. BLOCKS
 * briefly — call from a background queue. True when there was an
 * engine to dissolve.
 */
bool companion_sync_detach(CompanionHandle *handle);

/*
 * One turn of the engine loop, run repeatedly from a background queue
 * while sync is on: sweep the enrolled pages into the outbox, publish
 * what the 2-second clock owes, long-poll the delta stream for up to
 * wait_seconds (section 8 budgets 25), walk the ballot patience, and
 * publish a committed ceremony's frame. BLOCKS for up to the whole
 * long-poll; the core mutex is held only between round-trips, so the
 * pad never waits on the network. Returns {"ok", "reason"?, "events":
 * [{"kind", "page"?}, ...], "state"} — kinds: applied,
 * countdown_moved, terminal, rejoin_required, ceremony_proposed,
 * ceremony_committed, ceremony_required, epoch_conflict, unauthorized,
 * unreachable, protocol, signed_out. States, never sentences — the
 * surface owns the words. Free with companion_string_free().
 */
char *companion_sync_pump(CompanionHandle *handle, uint32_t wait_seconds);

/*
 * The device list for Settings: every peer a human verified here,
 * joined with the attach roster's times, plus this device and any
 * attached-but-unverified stranger, labelled as exactly that.
 * {"devices": [{"fingerprint", "label", "this_device", "verified",
 * "paired_wall_ms", "attached_ms"}, ...]}. Free with
 * companion_string_free().
 */
char *companion_sync_devices_json(CompanionHandle *handle);

/*
 * Revoke a paired peer by fingerprint: its record goes, nothing is
 * ever sealed to it again, and the chain leaves it behind at the next
 * ceremony at the latest. True when the fingerprint was recorded and
 * the removal stored.
 */
bool companion_sync_revoke_peer(CompanionHandle *handle,
                                const char *fingerprint);

/*
 * Begin inviting a new device into the channel (the pairing ceremony
 * over the relay mailbox): this side holds the channel and will grant
 * it after the human comparison. {"ok": true} or
 * {"ok": false, "reason"}: "not_attached", "busy", "keychain",
 * "no_entropy". Then poll. Free with companion_string_free().
 */
char *companion_sync_invite_begin(CompanionHandle *handle);

/*
 * Begin joining a channel from this new device: waits for an
 * inviter's ceremony. Result shape as companion_sync_invite_begin;
 * then poll.
 */
char *companion_sync_join_begin(CompanionHandle *handle);

/*
 * One mailbox round of the pairing ceremony: post what is queued,
 * fetch the tail, advance, report. BLOCKS for the round-trips — call
 * from a background queue, on a timer while the enrolment sheet is
 * open. Returns {"stage", "sas"?, "reason"?}: "waiting" (keep
 * polling), "sas" (show the six digits, ask the human, call confirm),
 * "confirmed" (this side confirmed; waiting for the peer), "done",
 * "failed", "idle" (no ceremony). Free with companion_string_free().
 */
char *companion_sync_pairing_poll(CompanionHandle *handle);

/*
 * The human's verdict on the short authentication string. A match
 * moves the ceremony forward; a mismatch aborts it whole with nothing
 * stored on this device — failing must always be possible. Returns
 * the stage as companion_sync_pairing_poll does. Free with
 * companion_string_free().
 */
char *companion_sync_pairing_confirm(CompanionHandle *handle, bool matched);

/*
 * Forget the pairing ceremony in flight, at any stage — a finished or
 * failed one whose sheet is being dismissed included. True when there
 * was one.
 */
bool companion_sync_pairing_cancel(CompanionHandle *handle);

/* Free a string returned by this library. Null is a no-op. */
void companion_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* COMPANION_FFI_H */
