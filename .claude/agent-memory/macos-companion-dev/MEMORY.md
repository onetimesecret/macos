# Memory Index

- [Issue #33 backdrop geometry stages](project_issue33_backdrop_geometry.md) — D0-D3 landed and verified green 2026-07-17, uncommitted; resting stays mouse-transparent
- [ADR-0013 stage progress](project_adr0013_stages.md) — all six stages landed on feature/adr-0013-provenance-core; compaction is rebuild-from-runs, pause hook is top-up only, stamp clamp has 2 s slack
- [Issue #53 PageModel seams](project_issue53_pagemodel_seams.md): seams folded into PageModel.Seams struct, green 2026-08-20; companion_new_ephemeral is the credential seam
- [ADR-0018 gated seams](project_adr0018_gated_seams.md): SwiftPM never dead-strips, so gated-symbol refs live only in test targets; nm the linked binary, not the thin-LTO .a
- [Test seams are mandatory](feedback_test_seams_are_mandatory.md): a default-seam PageModel in a test erased the installed app's real ledger.sealed
- [ADR-0017 tab/page split](project_adr0017_tab_page_split.md): core in PR #59, seam and shell 2026-08-22; the two emptiness predicates must never be wired backwards
- [Keymap #76/#77](project_keymap_76_77.md): TabStrip/Ledger contexts are declared but unconsulted, ⌥⌘N retired not aliased, override sits outside the .noindex dir
- [Issue #78 hidden UI](project_issue78_hidden_ui.md): four elements parked behind HiddenUI flags, not deleted; ledger::Show stays bindable by an override
- [Window behaviour stack 41/22/23/73/74](project_window_behaviour_stack.md): merge-only propagation in dogfood-a; the mouse gate must converge open
- [Two version numbers](project_two_version_numbers.md): app version lives in the shell plist (#89), crate version in crates/ffi; bump the plist for user visible work
- [Stacked review findings](feedback_stacked_review_findings.md): verify each finding on the branch that owns the code; a claim false on 77 can be true on 78
- [Conceal vocabulary](feedback_conceal_vocabulary.md): "promotion" is banned (#92); conceal/reveal only, and nspasteboard_concealed keeps the clipboard marker apart
- [Issue #79 day seam](project_issue79_day_seam.md): one `local_day` for every day bucket, `Sheet::has_content` is the ledger's bar, and a new non-optional Codable field breaks the four summary fixtures in CompanionClientTests
