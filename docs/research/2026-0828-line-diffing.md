
# Line diffing.

**Line diff** — real; that is standard unified diff output (`difflib.unified_diff`, same format as `git diff`).

**`=15 -5 +"fast" =108`** — a made-up shorthand, not a published format. It mirrors diff-match-patch's actual in-memory result, which is a list of tuples `[(0, "Thanks for the "), (-1, "quick"), (1, "fast"), (0, " turnaround…")]`, but a real implementation would store what you write, not what dmp returns (dmp keeps the deleted text).

**The `@@ -12,13 +12,12 @@` patch** — real; that's diff-match-patch's `patch_toText` format (it's unidiff-like with URL-encoding of special characters).

**`[-quick-]{+fast+}`** — real; `git diff --word-diff=plain` output.

**The CRDT op** — schematic pseudo-notation I wrote to convey the idea. Not Loro's format, not Yjs's.

**What it actually looks like in Loro**, since that's what you use: the binary op log is columnar with run-length encoding, so there is no human-readable "op" at rest; consecutive inserts from one peer merge into a single run, which is why the benchmarks come out near 1 byte per op. For debugging there is `doc.exportJsonUpdates()`, which (from memory of the docs, so verify the field names) renders each change as `{ id: "0@peer", timestamp, deps, lamport, ops: [ { container: "cid:root-text:Text", counter, content: { type: "insert", pos: 15, text: "fast" } } ] }` and deletes as `{ type: "delete", pos, len, start_id }`. The delete refers to the original op IDs of the removed characters, which is the property that lets you do span-level restore: the old characters keep their identity as tombstones.

Given you're on Loro, the practical numbers from the earlier research that matter: about 109 bytes per keystroke on the wire if you send each one unbatched (B1.1), roughly 1 byte per op in the stored log after merging, and shallow snapshots that drop history before a chosen frontier at 70–90% size reduction. Two things to check for your use case, which I couldn't confirm from docs: whether `setRecordTimestamp(true)` is on (you need it to map "ten minutes ago" to a frontier for the scrubber), and how Loro's per-change timestamp granularity interacts with the merge-window idea, since ops merged into one Change share one timestamp.

Sources: [Loro export modes](https://www.loro.dev/docs/tutorial/encoding), [Loro JS API](https://loro.dev/docs/api/js), [loro-dev/loro](https://github.com/loro-dev/loro)
