---
documentation_status: needs-review
---

# ADR-0038: Pad selection and associations

- **Status:** proposed
- **Date:** 2026-10-01

## Context

A note-taking pad can collect pages across related directories and applications.
The [reviewed one-pad-picker mockup](../mockups/multiple-pads/one-pad-picker-design.md)
uses a single selector so that a directory is context for a pad, rather than a
competing destination. The user requested a native implementation attempt of
that mockup, including folder and application associations. This is a proposal
for that attempt; the browser prototype implements the picker interactions,
not native routing, filesystem access, process activation, or persistence.

The user's explicit exploration constraint is:

> we are not interested in background clipboard collection, or any automatic copying of information that is not readily available in the given context. Paths, applications, and what NSPasteboard/UTI can afford.

This instruction defines the proposal's permitted context. It does not prove
that the existing application enforces the boundary. The
[macOS research](../research/2026-1001-macos-context-and-pasteboard.md)
separates supplied paths from app identity and explains why an app name does
not identify the focused project in another app. Clipboard transfers remain
the distinct topic of [ADR-0037](0037-explicit-clipboard-operations.md).

The pad shortcuts requested in the latest mockup conflict with accepted
[ADR-0017](0017-durable-tabs-expiring-pages.md), which states:
“⌘1 to ⌘9 are shortcuts to the first nine slots and the rest have no chord
(issue #158).” Acceptance of this proposal would supersede that shortcut
ownership clause only; the Tab/Page split and expiry decisions remain outside
its scope. Until acceptance, this is a proposed successor and does not alter
the accepted record.

## Decision

Use one pad picker with many directory bindings per pad and one owner per
specific directory identity. Treat an application association as a weaker
hint to an already active/recent pad, not a source of directory or document
identity.

The proposed rules are:

- Scratch has no directory bindings. Other pads may have zero or several.
  Add/remove controls sit within that pad's menu cell; a folder label itself
  performs no action. Application-wide association and full-path options sit
  in the footer.
- An explicitly supplied path may select its uniquely matching bound pad,
  including a known pad outside the active/recent list. This is **folder
  binding**. Defining filesystem identity, nested-root resolution, and failed
  bookmark handling is a prerequisite to calling routing deterministic.
- Application identity may suggest an already active/recent associated pad;
  most recently active is the proposed tie-breaker. This is an **app hint**.
  It does not establish clipboard provenance, a window's project, or permission
  to inspect another app. A uniquely resolved folder binding takes precedence
  over a redundant app hint. The bounded recent-set policy remains unresolved.
- Header icons represent explicitly associated applications. Selecting one is
  a deliberate request to activate that application. Several icons appear
  horizontally at the right edge; the browser version reports a simulation.
- In the proposed native command context, Scratch owns `⌘0` and the first nine
  remaining pads own `⌘1`–`⌘9`. Holding Command reveals the current assignments
  in the picker. The prototype contains four named pads and demonstrates
  `⌘1`–`⌘4`. Pads beyond nine need an ordinary picker route. Acceptance must
  record the replacement of the slot shortcut clause in ADR-0017 and settle
  the slots' replacement keyboard route through the keymap.
- Preserve existing page lifetimes. No directory binding grants permission to
  modify or scan a checkout, and no app association permits background
  clipboard collection. These are requirements of this proposal, not claims
  verified by the mockup.

The first native attempt may use an opt-in catalog in UserDefaults for pad
names, directory paths, application bundle identifiers, and stable tab UUID
ownership. This is an implementation proposal, not an accepted storage policy.
These fields can disclose work context; UserDefaults would leave them outside
the encrypted note-content envelope. The catalog must contain no note content
or clipboard payload, and the attempt must state this limitation clearly.
Proposed [ADR-0012](0012-framing-threat-boundary-and-persistence-model.md)
says “Settings remain in UserDefaults (never secrets).” Its proposed status and
original scope do not establish authority for storing this new metadata.
Storage choice, migration, and metadata removal still require review.

## Consequences

- A directory may identify one pad while several related roots share the same
  writing context. App hints remain useful when only broad context is supplied,
  but cannot disambiguate two projects in one application.
- One header and one selector avoid parallel project/directory navigation.
  The closed header stays compact with a folder tally; detailed bindings remain
  available inside the menu.
- Redirecting numbered shortcuts from slots to pads changes an existing
  command contract. It needs explicit successor acceptance and native keymap
  validation; browser interception is not that validation.
- Stable ownership must survive native tab restoration. A restore-reminted
  numeric handle is insufficient as the persistent catalog identity; the
  implementation must use stable identity and verify restart behavior.
- Path equality, nested roots, inaccessible associations, activation failures,
  association editing, and bounded recency need tests and documented failure
  behavior. Sample chooser exclusivity does not prove any of them.
- Independent day/checkpoint sorting is recorded in the mockup design record.
  Replacing the accepted newest-first day policy requires a separate successor
  design decision; this ADR does not silently supersede it.

## Eject triggers

- A supplied path can resolve to several pads after normalization, bookmark
  restoration, or nested-root handling. Revisit the identity/matching model
  before routing automatically.
- Dogfood reveals that app hints repeatedly choose a different pad from the
  user's manual choice. Revisit the recency rule or reduce the hint to an
  explicit chooser.
- A restore, catalog migration, or moved folder reassigns existing pages to a
  different pad. Stop automatic routing and repair stable ownership before
  expanding the feature.
- Numbered pad shortcuts interfere with an essential slot/editor operation
  without a usable replacement. Revisit command ownership before acceptance.
- The catalog's metadata cannot fit the agreed storage threat boundary.
  Revisit its storage location and opt-in policy; do not advertise encrypted
  context metadata based on encrypted note storage.
