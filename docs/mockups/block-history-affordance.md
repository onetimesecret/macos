My recommendation is a hybrid: remove the permanent timestamp rows, retain a compact “edited” affordance only where it carries useful information, and put the full history one click away.

The current treatment spends 20 points of vertical space per labeled block and repeats `EEE HH:mm` above the content ([InkEditorView.swift](/Users/d/Projects/dev/onetimesecret/macos/shell/Sources/CompanionKit/InkEditorView.swift:2926)). In the time-tabs layout, the checkpoint header has already established the day, deliberately avoiding repeated dates ([DayScrollView.swift](/Users/d/Projects/dev/onetimesecret/macos/shell/Sources/CompanionKit/DayScrollView.swift:1206)). The block labels undermine that otherwise economical hierarchy.

### Proposed resting state

```text
plop
- one
- item
- per
- point

A new paragraph                              edited
```

- Untouched block: no visible metadata.
- Modified block: faint, right-aligned `edited` affordance on the first line.
- No reserved metadata row, so blocks retain normal paragraph rhythm.
- Prefer a right-margin overlay to inline text, avoiding reflow or collisions with wrapping.

On hover, keyboard focus, or caret entry, expand the affordance without moving content:

```text
A new paragraph        created 17:21 · edited 17:22 · 4 revisions
```

Clicking it opens the richer block-history experience:

- revision scrubber;
- word-level changes;
- full absolute timestamps;
- restore or create checkpoint;
- retention/shed explanation where relevant.

This fits the draft block-revisions concept, which says “The stamp is the doorway,” but improves the doorway rather than preserving the current stamp’s exact presentation ([block-revisions spec](/Users/d/Projects/dev/onetimesecret/macos/docs/spec/feature/block-revisions/README.md:70)). That document is draft and ADR-0025 remains proposed, so this is a proposal, not an established project decision.

### Formatting rules

Within a checkpoint whose day is already visible:

- Same-day creation: `created 17:21`
- Same-day edit: `edited 17:22`
- Cross-day edit: `created Tue 23:58 · edited Wed 00:03`
- Expanded detail/popover: full localized date and time
- Multiple states: show `4 revisions`, which is more useful than merely repeating two clocks

The persistent `edited` word directly answers the useful question—“has this changed?”—while the detailed timestamps answer “when?” only on demand.

I would not make the feature hover-only. That maximizes visual density, but weakens discovery and excludes keyboard and accessibility paths. The right-aligned `edited` affordance should have a generous invisible hit target, a context-menu equivalent such as “Show Block History,” and a VoiceOver label containing the complete created/modified information.

One implementation caveat: eventually the marker should be driven by meaningful revision count, not just `modified > created`. The accepted architecture says metadata derives from changes while history exists ([ADR-0013](/Users/d/Projects/dev/onetimesecret/macos/docs/adr/0013-bounded-document-history-and-block-metadata.md:29)); the proposed revision design goes further by collapsing identical reconstructed states. That prevents incidental edits—or edits within the same minute—from producing misleading UI.

In short: keep the checkpoint timestamp as the page’s temporal coordinate, replace block timestamp rows with a compact `edited` signal, and let interaction reveal the actual history. This raises the signal-to-noise ratio without discarding the genuinely valuable provenance.
