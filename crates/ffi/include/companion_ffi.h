/*
 * companion_ffi.h — C ABI for the Onetime Secret macOS companion core.
 *
 * This is the *entire* surface a non-Rust shell may call, speaking
 * interaction-model rev C (docs/spec/04): sheets of ink and sealed
 * chips. By construction it hands out only opaque handles, non-secret
 * JSON metadata (titles, excerpts, counts), and action results — never
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
 * JSON array of non-secret page summaries, in visible (tab) order.
 * Free with companion_string_free(). Fields per page:
 *   id, title (first typed line, heading markup stripped; "untitled"),
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
 * consent is the gesture. Returns the chip's JSON (free with
 * companion_string_free()):
 *   chip_id, kind ("text"|"image"), excerpt (the mechanical face —
 *   the only rendering the content ever gets), size_label ("40 ch",
 *   "5 ln", "212 KB"), promoted (bool).
 * Null when the board is empty, the page unknown, or content empty.
 */
char *companion_sheet_seal_from_pasteboard(CompanionHandle *handle,
                                           uint64_t sheet);

/*
 * The cmd-return retrofit: seal `text` (the selection, or the current
 * line) onto the page. The seam's one deliberate plaintext-in entry:
 * the argument is visible ink the shell already holds, readable on
 * screen by definition; the gesture moves it into core custody. After
 * this returns, delete the shell-side copy — undo never un-seals.
 * Returns chip JSON as above, or null.
 */
char *companion_sheet_seal_text(CompanionHandle *handle, uint64_t sheet,
                                const char *text);

/*
 * Drop-to-seal: the core reads the DRAG pasteboard itself
 * (NSPasteboardNameDrag — the board the in-flight drag session's
 * content rides on) and seals it onto the page; dropped bytes never
 * transit the shell. Call from the drop handler while the session's
 * data is still on the board. Returns chip JSON as above, or null
 * (unknown page, empty/unreadable drag content, off-macOS build).
 */
char *companion_sheet_seal_from_drag(CompanionHandle *handle, uint64_t sheet);

/* ------------------------------------------------------------------ */
/* The synced document                                                 */
/* ------------------------------------------------------------------ */

/*
 * Replace a page's document snapshot: a JSON array of runs in document
 * order — {"ink": "text"} for visible ink, {"chip": id} where a chip
 * sits. The shell owns the live document; the core mirrors it for tab
 * titles, the ledger, and page promotion. AUTHORITATIVE FOR CHIP
 * LIVENESS: a chip the snapshot omits was deleted in the editor and is
 * zeroized here. Malformed snapshots (bad JSON, foreign chip,
 * duplicate reference) are rejected whole. Returns acceptance.
 */
bool companion_sheet_sync_document(CompanionHandle *handle, uint64_t sheet,
                                   const char *json);

/* ------------------------------------------------------------------ */
/* Chips                                                               */
/* ------------------------------------------------------------------ */

/*
 * Copy a chip back out: the core writes the pasteboard itself, marked
 * transient AND concealed (a chip is sealed by definition). Does not
 * consume the chip — multi-paste is a core moment. Returns whether the
 * chip existed.
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
 * The ledger (cmd-0): dead pages, newest first — session-bound,
 * read-only, capped at the newest dozen. Free with
 * companion_string_free(). Fields per record:
 *   cause ("expired"|"closed"), title, age_ms (since death),
 *   segments: array of {"ink": "…"} | {"tombstone": "<excerpt>"} in
 *   document order. Sealed bytes were zeroized at death; a tombstone
 *   carries only the excerpt that always rendered (struck through
 *   shell-side, labelled "zeroized").
 */
char *companion_ledger_json(CompanionHandle *handle);

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
 * share_domain, extid, has_token.
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
 */
char *companion_sheet_promote(CompanionHandle *handle, uint64_t sheet,
                              const char *opts_json);

/* ------------------------------------------------------------------ */
/* Dev scaffolding                                                     */
/* ------------------------------------------------------------------ */

/*
 * DEV SCAFFOLDING: put text on the pasteboard as an external app
 * would, so demo affordances have something for
 * companion_sheet_seal_from_pasteboard() to seal. On macOS this writes
 * the REAL system clipboard. Exists only when the core was built with
 * the off-by-default `dev-scaffolding` cargo feature; build-core.sh
 * defines COMPANION_DEV_SCAFFOLDING in the packaged header iff it
 * enabled that feature.
 */
#ifdef COMPANION_DEV_SCAFFOLDING
bool companion_dev_seed_pasteboard(CompanionHandle *handle, const char *text);
#endif

/* Free a string returned by this library. Null is a no-op. */
void companion_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* COMPANION_FFI_H */
