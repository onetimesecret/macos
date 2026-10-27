---
name: issue332-list-reach
description: Issue 332 walker placement after comrak's fix_zero_end_columns; parity with cmark-gfm's list ends was built, then dropped by the lead; how to get a cmark oracle quickly
metadata:
  type: project
---

comrak's `fix_zero_end_columns` moves a list's end back to its last surviving child when an empty line closes it, so a definition ending the last item places its object after the list, where cmark-gfm kept it in the item. Pinned by `a_definition_closing_a_list_after_an_empty_line_follows_the_list` in `crates/markdown/src/tests/parser.rs`.

- **Dropped on 2026-10-24:** a `Lines::reach` rule that replayed comrak's item continuation (padding, lazy and blank lines, task items) to restore cmark-gfm's ends. About 80 lines coupled to comrak internals for a placement that changes nothing but where the object shows, and full parity is out of reach anyway: cmark 0.31 stops checking open blocks on a second blank line at indent 0, cmark-gfm and comrak do not, so block structure itself differs there.
- **Oracle:** clang builds a sourcepos dumper from the maple-turtle worktree's `shell/Sources/CMarkCommonMark/upstream/*.c` (plus `generated/`) and `CMarkGFM/upstream/{src,extensions}` in seconds.

**How to apply:** an object after a list instead of in its last item is this pinned behaviour, not a bug. Do not restore parity with cmark-gfm's spans unless the user asks. See [[issue332-spec-corpus]], [[issue332-ffi-entry]].
