/*
 * companion_ffi.h — C ABI for the Onetime Secret macOS companion core.
 *
 * This is the *entire* surface a non-Rust shell may call. By construction
 * it hands out only opaque handles, non-secret JSON metadata, and action
 * results — never a plaintext secret. Both pasteboard directions stay in
 * Rust: ingest reads the pasteboard in the core, copy-out writes it in
 * the core. Keep this header in sync with crates/ffi/src/lib.rs; a later
 * milestone generates it (cbindgen) rather than hand-maintains it.
 *
 * Memory rules:
 *   - Pointers returned by companion_list_json() are owned by the caller;
 *     free each with companion_string_free().
 *   - The CompanionHandle* from companion_new() is freed with
 *     companion_free().
 *   - companion_version() returns a static string; do NOT free it.
 *
 * Scheduling rule (no polling): arm ONE timer from
 * companion_next_deadline_ms(); when it fires call companion_expire_due()
 * and re-arm. -1 means nothing to schedule.
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
 * companion_cell_set_ttl(); returned by companion_cell_cycle_ttl().
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

/* Lifecycle. */
CompanionHandle *companion_new(void);
void companion_free(CompanionHandle *handle);

/*
 * Stage the pasteboard's content as a new cell; returns its id, or 0 when
 * there was nothing to stage or the store refused at capacity (0 is never
 * a valid id). The core reads the pasteboard itself.
 */
uint64_t companion_ingest_pasteboard(CompanionHandle *handle);

/*
 * Copy a cell back out: the core writes the pasteboard itself, marked
 * transient (and concealed when the cell is). Does not consume the cell.
 * Returns whether the cell existed.
 */
bool companion_cell_copy_out(CompanionHandle *handle, uint64_t id);

/*
 * Clear the pasteboard iff it still holds our last copy-out (change-count
 * guarded; never clobbers a newer copy). Returns whether a clear happened.
 */
bool companion_clear_clipboard_if_ours(CompanionHandle *handle);

/*
 * JSON array of non-secret cell summaries, newest first. Free with
 * companion_string_free(). Fields per cell:
 *   id, kind ("text"|"image"), state ("staged"|"draining"|"last_hour"|
 *   "expired"), concealed (bool), detected_as (string|null),
 *   ttl_code (CompanionRung), ttl_label ("8h"), remaining_ms,
 *   remaining_label ("3h 40m"), spoken_remaining ("about 3 hours
 *   remaining" — the VoiceOver value), recognition (masked line),
 *   display_size, promoted (bool).
 */
char *companion_list_json(CompanionHandle *handle);

/*
 * Milliseconds until the earliest deadline — the ONE timer to arm.
 * -1: nothing to schedule. 0: something is already due.
 */
int64_t companion_next_deadline_ms(CompanionHandle *handle);

/* Expire every overdue cell (wiped as they drop); returns how many. */
uint64_t companion_expire_due(CompanionHandle *handle);

/* Cycle TTL to the next rung (clock reset); new code, or -1 if gone. */
int companion_cell_cycle_ttl(CompanionHandle *handle, uint64_t id);

/* Set an explicit rung (clock reset). Returns success. */
bool companion_cell_set_ttl(CompanionHandle *handle, uint64_t id, int rung);

/* Discard a cell now, wiping its buffer. Returns whether it existed. */
bool companion_cell_discard(CompanionHandle *handle, uint64_t id);

/*
 * DEV SCAFFOLDING — deleted when the NSPasteboard adapter lands: put text
 * on the in-process pasteboard stand-in, as an external app would, so the
 * vertical slice can demonstrate a live cell today.
 */
bool companion_dev_seed_pasteboard(CompanionHandle *handle, const char *text);

/* Free a string returned by companion_list_json(). Null is a no-op. */
void companion_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* COMPANION_FFI_H */
