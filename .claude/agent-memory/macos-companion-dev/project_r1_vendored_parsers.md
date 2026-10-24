---
name: project-r1-vendored-parsers
description: R1 unit A (2026-10-17) vendored cmark 0.31.2 and cmark-gfm 0.29.0.gfm.13 as CMarkCommonMark/CMarkGFM C targets; gfm's finish frees the refmap, gfm parses race without a lock, scripts/vendor-cmark.sh --check verifies offline
metadata:
  type: project
---

Unit A of R1 on feat/markdown-dialects (2026-10-17): `scripts/vendor-cmark.sh` copies upstream byte-identical into `shell/Sources/CMarkCommonMark/upstream` and `shell/Sources/CMarkGFM/upstream`, applies `CMarkGFM/patches` (0001 = upstream 46829933, 0002 = plane 16 placeholder in autolink.c), writes `prefix.h` from `nm -gU` and `UPSTREAM.md` hashes. `--check` is offline and also reverses the patches to prove the pre-patch hashes.

**Why:** two facts the shim is shaped around, neither visible from the public API. cmark-gfm's `cmark_parser_finish` calls `cmark_parser_reset`, which frees the reference map, so `ots_gfm.c` copies it from a per-parse postprocess extension. Each gfm inline parse toggles the process-wide `SPECIAL_CHARS` table in inlines.c; TSan reports a race without `parse_lock`. cmark 0.31.2 keeps its refmap until `cmark_parser_free`, so its snapshot points into it.

**How to apply:** after touching anything under `upstream/`, `patches/` or the kept-file lists, run the script (network) then `--check`. To nm the SwiftPM build, per-file objects sit at `shell/.build/out/Intermediates.noindex/OnetimePad.build/Debug/<Target>-t.build/Objects-normal/arm64/`. Never name a shim macro `MAX_INPUT` (sys/syslimits.h). Related: [[project-r1-corpus-tests]].
