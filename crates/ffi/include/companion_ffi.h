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
 * companion_sheet_set_rung(); returned by companion_sheet_cycle_rung().
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

/* Lifecycle. Freeing the handle wipes every sealed byte it holds. */
CompanionHandle *companion_new(void);

/* As companion_new(), with Keychain items scoped to `service` rather
 * than the default "com.onetimesecret.companion". A second form factor
 * passes its own bundle id so its state key is its own item, granted to
 * its own code identity; sharing one item across two signed binaries
 * would make each one's first read a confirmation prompt for the
 * other's key. Null or empty falls back to the default scope. */
CompanionHandle *companion_new_scoped(const char *service);

void companion_free(CompanionHandle *handle);

/* ------------------------------------------------------------------ */
/* Sheets                                                              */
/* ------------------------------------------------------------------ */

/*
 * A new page at the end of the tab strip, default rung, countdown
 * running. Returns its id, or 0 when the store refused at the cap of 9
 * — the keyboard wall; the app declines the tenth and says so (0 is
 * never a valid id).
 */
uint64_t companion_sheet_new(CompanionHandle *handle);

/*
 * Close a page: it rests in the ledger like an expired one, sealed
 * bytes zeroized. Returns whether the page existed.
 */
bool companion_sheet_close(CompanionHandle *handle, uint64_t id);

/*
 * Move a page to `index` in visible order (drag-to-reorder; the
 * command-number map follows). Out-of-range clamps to the end.
 */
bool companion_sheet_move(CompanionHandle *handle, uint64_t id,
                          uint64_t index);

/*
 * Name a page explicitly (the rename gesture in the tab context menu).
 * An empty or all-whitespace title clears the user override and
 * re-derives from the page's own content, the way back to the default.
 * Anything else is trimmed, capped at 80 characters, and from then on
 * sticky: editing the page never overwrites it again. Returns whether
 * the page existed.
 *
 * The title is the one piece of page-owned text that reaches the
 * ledger, so a secret typed into the rename field lands in the audit
 * record. Documented exception, not an accident; the cap bounds it.
 */
bool companion_sheet_set_title(CompanionHandle *handle, uint64_t id,
                               const char *title);

/*
 * JSON array of non-secret page summaries, in visible (tab) order.
 * Free with companion_string_free(). Fields per page:
 *   id, title (the page's own name): the first non-empty line of its
 *     ink with markdown markup stripped, capped at 80 characters;
 *     "MMDD-HHmm" from the page's creation stamp in LOCAL time while
 *     there is no ink to derive from; or whatever
 *     companion_sheet_set_title() last set, which then sticks,
 *   rung_code (CompanionRung), rung_label ("8h"), remaining_ms,
 *   remaining_label ("3h 40m"), spoken_remaining ("about 3 hours
 *   remaining" — the VoiceOver value), fraction_remaining (0.0..1.0),
 *   paused (bool), hold_remaining_ms, chip_count, last_hour (bool).
 */
char *companion_sheets_json(CompanionHandle *handle);

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
 *   "5 ln", "212 KB"), promoted (bool).
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
 * routes return (chip_id, kind, excerpt, size_label, promoted). Ink
 * renders anyway; a chip crosses as its face, never its bytes. Free
 * with companion_string_free(). Null for an unknown page.
 */
char *companion_sheet_document_json(CompanionHandle *handle, uint64_t sheet);

/* ------------------------------------------------------------------ */
/* Chips                                                               */
/* ------------------------------------------------------------------ */

/*
 * Copy a chip back out: the core writes the pasteboard itself, marked
 * transient AND concealed (a chip is sealed by definition). Does not
 * consume the chip — multi-paste is a core moment. Returns whether the
 * chip existed.
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

/* Cycle the countdown to the next rung (clock reset to the full rung —
 * each click resets the clock); new code, or -1 if the page is gone. */
int companion_sheet_cycle_rung(CompanionHandle *handle, uint64_t id);

/* Set an explicit rung (clock reset). Returns success. */
bool companion_sheet_set_rung(CompanionHandle *handle, uint64_t id, int rung);

/*
 * The pause gesture (double-click a tab): first press holds the clock
 * 1 hour; a press while held tops the hold up to 24 hours from now —
 * never cumulative. Holds the clock, never extends the rung. The hold
 * lapses on its own (folded into companion_next_event_ms()). Returns
 * false for an unknown or already-due page.
 */
bool companion_sheet_pause_press(CompanionHandle *handle, uint64_t id);

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
 * affordance. The records outlive the boot session by design, so a way
 * to end them on demand is part of that bargain. In-memory only: call
 * companion_ledger_save() afterwards for the empty ledger to reach the
 * file.
 */
void companion_ledger_clear(CompanionHandle *handle);

/*
 * Save the ledger to `path`, sealed with ChaCha20-Poly1305 under its
 * OWN 32-byte key ("ledger-key" account, minted on first save) and its
 * own envelope magic. That key is SEPARATE and LONG-LIVED: it is not
 * derived from the boot session, unlike the content key. That is the whole
 * point: the audit record survives the reboot that discards staged
 * content, and a content-key rotation must never touch it. The two
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
/* Persistence: the sealed state file, bound to this boot session      */
/* ------------------------------------------------------------------ */

/*
 * Save the staged content (sheets, sealed chips, clocks) to `path`,
 * encrypted (ChaCha20-Poly1305) under a key that exists only while this
 * boot session does: HKDF of a keychain half and a boot half, the boot
 * half living in the per-user temp directory macOS clears at restart
 * (ADR-0012). Neither half alone unwraps anything, and no key byte
 * crosses this seam: the shell passes a path and receives a bool.
 *
 * The envelope stamps itself with kern.bootsessionuuid and with both
 * clocks at the save, all of it authenticated, so a file cannot be
 * re-dated and cannot be opened by a later boot session. The ledger is
 * NOT in this file; it has its own file under its own long-lived key
 * (companion_ledger_save), because content is boot-session-bound and
 * the audit record is not.
 *
 * Only ciphertext touches disk; the write is atomic and owner-only.
 * Call on every mutation, debounced, and once more at quit to flush
 * what is still pending; the core saves nothing on its own. Returns
 * success.
 */
bool companion_persist_save(CompanionHandle *handle, const char *path);

/*
 * Restore from a state file companion_persist_save() wrote: decrypt
 * (both key halves loaded, never minted), replace the store's sheets,
 * and drain every countdown by the time that passed while the app was
 * closed; pages that came due while away expire into the ledger
 * immediately. Call at startup, before creating the first page.
 *
 * A file from another boot session is discarded before anything in it
 * is decrypted: both content key halves are rotated FIRST, and the
 * file is dropped from disk only if that rotation succeeded. The
 * rotation is what actually forgets the content; the unlink is a tidy
 * on top of it. A keychain that refuses the delete (locked at launch,
 * an ACL dismissed) therefore leaves the file exactly where it is,
 * because that file is the only thing that triggers this path and
 * dropping it would consume the trigger while both halves stayed
 * alive. The next launch tries again. The ledger key is untouched
 * either way, so the audit record survives the restart that discards
 * the content it describes.
 *
 * Time away is measured from the file's monotonic stamp, not from the
 * calendar, so stepping the system clock backwards buys a page no extra
 * life.
 *
 * Returns whether a state was restored. False covers "no file yet" (a
 * fresh start, not an error) and a discarded foreign-session file, as
 * well as a missing key, failed authentication, or a damaged snapshot.
 */
bool companion_persist_restore(CompanionHandle *handle, const char *path);

/*
 * Drop the state file at `path`: overwrite, truncate, sync, unlink.
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
 * is copy on write and every earlier generation the atomic rename
 * unlinked is out of reach; what actually forgets staged content is
 * crypto-erasure: the boot half dying with the boot session, and the
 * halves rotating on a session mismatch. Call this when the store
 * empties, so the last ciphertext generation does not sit on disk for
 * the rest of the session describing nothing.
 *
 * The in-memory store is untouched: this deletes a file, not a page.
 */
bool companion_persist_erase(CompanionHandle *handle, const char *path);

/* ------------------------------------------------------------------ */
/* Promotion: the exit ramp, the app's only network action             */
/* ------------------------------------------------------------------ */

/*
 * Configure where promotion goes. json (non-secret except the token in
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
 * promotion needs.
 */
char *companion_connection_json(CompanionHandle *handle);

/*
 * The Settings "test" button: one GET /api/v3/status. BLOCKS for the
 * round-trip — call from a background queue. Returns {"ok"} or
 * {"ok": false, "error"}; free with companion_string_free().
 */
char *companion_connection_test(CompanionHandle *handle);

/*
 * Promote one sealed chip into a one-time link (the chip's hover ↗).
 * opts_json: {"ttl_secs"?, "passphrase"?, "recipient"?} or NULL (TTL
 * defaults to the page's remaining time snapped DOWN the ladder).
 * Sealed bytes travel core -> client -> transport, never through the
 * caller. On success the share link is on the clipboard (transient)
 * and only the receipt id stays on the chip. BLOCKS for the round-trip
 * — call from a background queue; the core mutex is released during
 * the network call. Returns {"ok": true, "receipt_id"} or
 * {"ok": false, "error"}; free with companion_string_free().
 */
char *companion_chip_promote(CompanionHandle *handle, uint64_t chip,
                             const char *opts_json);

/*
 * Promote the whole page (the footer's ↗ page): ink verbatim, sealed
 * bytes inlined in document order. Refuses a page holding an image
 * chip. Options, blocking, and result shape as companion_chip_promote.
 * No per-chip mark is set, the link stands for the page, but the
 * egress is recorded: one "sent" record against the page's own
 * identity, destination "link", with a size class and no content.
 */
char *companion_sheet_promote(CompanionHandle *handle, uint64_t sheet,
                              const char *opts_json);

/* Free a string returned by this library. Null is a no-op. */
void companion_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* COMPANION_FFI_H */
