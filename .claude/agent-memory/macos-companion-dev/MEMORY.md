# Memory Index

- [Issue #33 backdrop geometry stages](project_issue33_backdrop_geometry.md) — D0-D3 landed and verified green 2026-07-17, uncommitted; resting stays mouse-transparent
- [ADR-0013 stage progress](project_adr0013_stages.md) — all six stages landed on feature/adr-0013-provenance-core; compaction is rebuild-from-runs, pause hook is top-up only, stamp clamp has 2 s slack
- [Issue #53 PageModel seams](project_issue53_pagemodel_seams.md): seams folded into PageModel.Seams struct, green 2026-08-20; companion_new_ephemeral is the credential seam
- [ADR-0018 gated seams](project_adr0018_gated_seams.md): SwiftPM never dead-strips, so gated-symbol refs live only in test targets; nm the linked binary, not the thin-LTO .a
