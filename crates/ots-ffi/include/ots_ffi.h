/*
 * ots_ffi.h — C ABI for OTS Cache's trust core.
 *
 * This is the *entire* surface Swift may call. By construction it hands out
 * only opaque handles, non-secret JSON metadata, and action outputs — never a
 * plaintext secret (docs/01 §3, §5). Keep it in sync with crates/ots-ffi/src/
 * lib.rs; in a later milestone it is generated (cbindgen) rather than hand-
 * maintained.
 *
 * Memory rules:
 *   - Pointers returned by otsc_*_json() are owned by the caller; free each
 *     with otsc_string_free().
 *   - The OtsCache* from otsc_cache_new() is freed with otsc_cache_free().
 *   - otsc_version() returns a static string; do NOT free it.
 */

#ifndef OTS_FFI_H
#define OTS_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to the cache. */
typedef struct OtsCache OtsCache;

/*
 * TTL ladder rung codes, in ascending order (docs/00 §7).
 * Passed to otsc_cell_reset_ttl(); returned by otsc_cell_cycle_ttl().
 */
typedef enum {
    OTS_RUNG_1H  = 0,
    OTS_RUNG_3H  = 1,
    OTS_RUNG_8H  = 2,
    OTS_RUNG_24H = 3,
    OTS_RUNG_3D  = 4,
    OTS_RUNG_7D  = 5
} OtsRung;

/* Process hardening (disable core dumps). Idempotent. */
void otsc_init(void);

/* Static version string; do not free. */
const char *otsc_version(void);

/* Lifecycle. */
OtsCache *otsc_cache_new(void);
void otsc_cache_free(OtsCache *cache);
bool otsc_cache_set_api(OtsCache *cache, const char *base_url, const char *extid);

/*
 * Ingest the pasteboard into a new cell; returns its id, or 0 if there was
 * nothing to ingest (0 is never a valid id).
 */
uint64_t otsc_ingest_pasteboard(OtsCache *cache);

/* JSON array of non-secret cell summaries, newest first. Free with otsc_string_free(). */
char *otsc_list_json(OtsCache *cache);

/* Reset a cell to an explicit rung (OtsRung). Returns success. */
bool otsc_cell_reset_ttl(OtsCache *cache, uint64_t id, int rung);

/* Step a cell up the ladder; returns the new OtsRung code, or -1 if gone. */
int otsc_cell_cycle_ttl(OtsCache *cache, uint64_t id);

/* Evict a cell now, wiping its secret. Returns whether it existed. */
bool otsc_cell_evict(OtsCache *cache, uint64_t id);

/*
 * Promote a text cell to a one-time link. ttl_secs is the link's server-side
 * lifespan. Returns a JSON object (free with otsc_string_free()):
 *   success: {"ok":true,"share_url":...,"metadata_url":...,"secret_key":...,
 *             "metadata_key":...,"ttl_secs":...}
 *   failure: {"ok":false,"code":<int>,"message":<string>}
 * Blocks on network I/O — call off the main thread.
 */
char *otsc_cell_conceal_json(OtsCache *cache, uint64_t id, uint64_t ttl_secs);

/* Free a string returned by an otsc_*_json() function. Null is a no-op. */
void otsc_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OTS_FFI_H */
