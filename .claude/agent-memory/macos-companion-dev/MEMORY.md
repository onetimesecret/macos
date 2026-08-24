# Memory Index

- [Issue #33 backdrop geometry stages](project_issue33_backdrop_geometry.md) — D0-D3 landed and verified green 2026-07-17, uncommitted; resting stays mouse-transparent
- [ADR-0013 stage progress](project_adr0013_stages.md) — all six stages landed on feature/adr-0013-provenance-core; compaction is rebuild-from-runs, pause hook is top-up only, stamp clamp has 2 s slack
- [Issue #53 PageModel seams](project_issue53_pagemodel_seams.md): seams folded into PageModel.Seams struct, green 2026-08-20; companion_new_ephemeral is the credential seam
- [ADR-0018 gated seams](project_adr0018_gated_seams.md): SwiftPM never dead-strips, so gated-symbol refs live only in test targets; nm the linked binary, not the thin-LTO .a
- [Test seams are mandatory](feedback_test_seams_are_mandatory.md): a default-seam PageModel in a test erased the installed app's real ledger.sealed
- [ADR-0017 tab/page split](project_adr0017_tab_page_split.md): core in PR #59, seam and shell 2026-08-22; the two emptiness predicates must never be wired backwards
- [Keymap #76/#77](project_keymap_76_77.md): TabStrip/Ledger contexts are declared but unconsulted, ⌥⌘N retired not aliased, override sits outside the .noindex dir
