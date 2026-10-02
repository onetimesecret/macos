---
documentation_status: needs-review
---

# ADR-0038: Explicit clipboard operations

- **Status:** proposed
- **Date:** 2026-10-01

## Context

Context-assisted pad selection needs application identity and deliberately supplied
paths, but does not need clipboard content. The authoritative scope constraint is
the maintainer's request in the 2026-10-01 design conversation, exactly:

> we are not interested in background clipboard collection, or any automatic copying of information that is not readily available in the given context. Paths, applications, and what NSPasteboard/UTI can afford.

The maintainer also agreed to the following wording in that conversation:

> design around explicit paste and validate the supported macOS releases before making compatibility promises.

These are human instructions for this work, not evidence that the current build
meets them. This completed proposal translates those constraints into operation
boundaries; its architectural status remains proposed. The companion
[copy law](../law/0002-copy.md) and [paste law](../law/0003-paste.md) are complete
drafts with explicit coverage debts, rather than accepted implementation claims.

Accepted [Law 0001](../law/0001-sealed-object.md#the-rule) states its governing
rule, exactly:

> A sealed item occupies one position in the document, but its plaintext is
> not part of the document's ambient text.

The explanatory prose that follows the rule, not the rule itself, gives the
sealed-object egress boundary this proposal relies on:
“Plaintext leaves the object only through an action that names that consequence.”

That authority governs sealed objects. It does not establish an ordinary copy,
rich-paste, application-provenance, or OS-compatibility guarantee. The
[platform research](../research/2026-1001-macos-context-and-pasteboard.md) is a
research reference, not authority for project guarantees.

## Decision

Propose making every clipboard content transfer an explicit user operation with
an identified source or destination and paste mode. Validate each supported
macOS release and command route before publishing compatibility claims.

- Activation, app association, pad selection, and folder association do not
  authorize clipboard content reads or writes. There is no background collection,
  clipboard history, clipboard preview, or continuously recorded app-switch history.
- Copy writes the selected document material or deliberately supplied context.
  Application identity or a bound path never authorizes acquiring another
  application's document contents. A pasteboard representation does not prove
  the originating app, window, or directory.
- Paste captures its pad/page or file destination and mode at invocation.
  Deliberate drops use the drop destination; explicitly invoked Services use
  their chosen receiver. A suggestion cannot redirect an in-flight transfer.
  If the receiver disappears or loses editing ownership, cancel without inserting
  into a replacement destination.
- Ordinary text paste, sealed paste, and optional conversion are distinct
  operation classes. A configured transformation may run within explicit paste;
  it does not authorize an earlier content read. New representation priorities,
  conversions, or imports require a named mode and its own defined contract.
- Preserve Law 0001's existing reference-only structural operations and named
  core-side payload egress. General copy/paste rules do not broaden sealed access.

## Consequences

Pad suggestions and directory routing can work independently of clipboard
transfer. Convenient clipboard previews and automatic capture are excluded from
this design. Asynchronous transfer requires destination and ownership checks;
conversion requires documented behavior and failure handling.

This proposal does not adopt rich-text conversion, file import, or Services
support merely because the APIs exist. Ordinary paste currently calls
`pasteAsPlainText`, with optional configured code fencing; this is a source
observation in [InkEditorView.swift](../../shell/Sources/CompanionKit/InkEditorView.swift),
not the release-validation evidence owed here. The keymap's `cmd-shift-v` invokes
sealed paste, so it cannot be promised as a universal formatting-removal shortcut.

Accepted [D-43](../spec/design/2026-0916-clipboard-clear-interval.md)
states the existing limit exactly:

> It does not bound retention by clipboard managers, Universal Clipboard,
> other observers or receiving applications, and it makes no erasure or
> retention claim about the drag pasteboard.

An explicit copy command therefore establishes intent, not local-only delivery
or erasure by other software. This proposal adds no such guarantee.

## Validation required before acceptance

The laws identify concrete contract rows and existing tests of limited scope.
The following evidence remains owed; no runtime compatibility matrix was
produced by the mockup work:

- Instrument clipboard access to prove activation, association, picker hover,
  command-key hints, sorting, and app-icon activation perform no content reads
  or automatic writes. Test availability queries separately from content reads.
- Exercise each shipped keyboard/menu route on the minimum supported macOS
  release and each supported release family. Record exact OS/build, signing,
  sandbox, access setting, action origin, and requested representations.
- Test unavailable and malformed representations, multiple items, delayed
  providers, denial, cancellation, destination switches, and editing ownership.
  Validate whichever conversions are actually shipped; unsupported modes remain
  absent from the UI.
- Check copy representation offers, sealed references, named decrypted egress,
  guarded clear, and any implemented cut/drop/Services route against their laws.

The release owner must identify the supported-release matrix and complete these
checks before acceptance or compatibility wording. API availability annotations
and a shortcut name alone are insufficient evidence. This ADR does not create a
new macOS deployment target or change existing page/link expiry decisions.

## Eject triggers

- A supported macOS update changes access behavior or representation delivery
  for a previously validated explicit command; revalidate that route and revise
  its compatibility statement.
- A deliberate transfer cannot retain its destination through an asynchronous
  provider, as demonstrated by a reproducible destination-switch test; revisit
  the transfer interaction before shipping it.
- A requested workflow needs an additional representation or conversion mode;
  extend the relevant law's contract and validation evidence before exposing it.

## Enforcement

Background collection or content reads caused by application/pad context violate
the maintainer's stated constraint. Correct those paths; their existence is not
an eject trigger or authorization to relax the boundary.

## Decision history

- 2026-10-01: Proposed after the context-and-pasteboard exploration. Completed
  for review alongside the one-pad-picker mockup; clipboard runtime validation
  and formal acceptance remain outstanding.
