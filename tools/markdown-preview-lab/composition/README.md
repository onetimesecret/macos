# Preview composition lab

**Frozen.** On 2026-10-16 this code moved into the application as
`shell/Sources/CompanionKit/{HTMLTokenizer,HTMLEntities,PreviewComposer}.swift`,
with its tests in `shell/Tests/CompanionKitTests/`. The application copy
changed whitespace, `br`, block-element and streaming behavior; the plan's
[delivery record](../../../docs/spec/design/2026-1016-markdown-dialects-and-preview.md#delivery-record)
lists the differences. This package is kept as the research record and is not
updated with the application.

Experimental Swift implementation of the R3 composition boundary in the
[Markdown preview plan](../../../docs/spec/design/2026-1016-markdown-dialects-and-preview.md#research-gates).
It converts typed Markdown/HTML events into text runs, formatting traits,
sealed-object references, and inert image descriptors.

This is a first implementation slice, not an accepted HTML policy or a shipping
renderer. R1–R6 remain open. The parser, native attachment and transport labs
are not integrated with this package. Production preview and Settings are
unchanged.

## Run the tests

Requires a Swift 6 toolchain. From this directory:

```sh
swift test
```

The package has no external dependencies. The tests run as a command-line
XCTest suite; there is no app executable, accessibility helper, loader or
AppKit HTML importer in this package. SwiftPM writes build output to `.build/`.
No installed app state or Settings migration is part of these tests.

Observed on 2026-10-16: **104 tests passed**, with Apple Swift 6.4 on arm64
macOS 27.2. Of these, 56 cover tokenization/entities and 48 cover composition.
The suite includes 512 deterministic randomized token-source reconstruction
cases and mixed-context object-order fixtures in both dialect modes.
This is not macOS 13 runtime evidence or an official syntax-corpus result.

## Authority and evidence boundary

Accepted [ADR-0059, Decision §1](../../../docs/adr/0059-preview-images-use-an-explicit-resource-request-route.md#authorization-and-destination)
states:

> Parsing, HTML conversion, rendering, styling, opening, scrolling, resizing, reparsing and cache refresh must not dispatch image requests.

Its §5 states:

> Reject every resource address containing a sealed object or its parser placeholder, including addresses derived from HTML attributes or CSS.

These are requirements, not results established by this package. The code has
no request route. Its address representation is either `unreviewed(String)` or
`refused`; `unreviewed` does not authorize a request or opening a link. R4 must
supply URL, destination, consent, transport and decoding policy before any
loader integration. Tests of this isolated transformation do not establish
transport inactivity in the application.

All composition choices below are **prototype proposals awaiting review**.
The existing [research report](../../../docs/spec/design/2026-1016-markdown-preview-research-results.md)
remains separate evidence for its own experiments.

## Event and output contract

| Input | Treatment in this prototype |
| --- | --- |
| `text` | Already decoded Markdown text. Never recognized again as HTML or decoded a second time. |
| `rawHTML` | Tokenized once, including quoted attributes, comments and typed objects. HTML text and selected attribute values use the limited entity decoder. |
| `object` | Opaque occurrence identity, not a payload or a replacement string. Empty or repeated identities reject the composition. |
| Markdown enter/leave | Separate balanced formatting stack, combined with HTML formatting. |
| `blockBoundary` | Adds one newline when the output is not already at a line boundary. Does not reset HTML scope. |
| Markdown image | Emits an inert descriptor with already-decoded alt text, preserving alt objects; destination objects are refused and recovered after alt content. |

A future parser adapter must distinguish decoded text from raw HTML and supply
complete tag/comment/entity spellings within a raw leaf. This package does not
recognize parser stand-ins or recover objects omitted from a parser tree. It
uses a configurable conservative legacy `OTSAttachment` prefix check and
U+FFFC check in addresses, but those checks do not implement R1's opaque atom.

Output types are independent of AppKit. They do not yet draw text or attachments,
compose a pasteboard, or perform link actions. Image fallback content includes
alt text and typed object references; there is no loading/loaded/failed state.

### Proposed HTML subset

- `em`/`i`, `strong`/`b`, `del`/`s`/`strike`, and `code` contribute formatting
  traits. `span` groups scope without CSS. `p`/`div` add line boundaries and
  `br` emits a newline.
- `a.href` supplies a separate unreviewed link address. `img.src` and `img.alt`
  supply the image descriptor. A linked image retains distinct link/image
  addresses.
- The first duplicate attribute supplies its visible value. Any `src`/`href`
  duplicate containing an object or reserved placeholder refuses that address.
  Objects from every attribute remain in source order.
- Other attributes do not apply formatting or introduce resources. `srcset`,
  CSS, event handlers and dimensions have no output behavior, except recovery
  of any typed objects. They are not implemented alternate resource routes.
- Unsupported elements are escaped into visible literal tag text; their
  children are composed separately, subject to raw-text handling below.
  Comments omit ordinary comment text but emit their object references.
- Matching closing tags close the nearest matching frame and any intervening
  frames. Unmatched closing tags remain literal. Unclosed frames end with the
  composition. Self-closing nonvoid elements are empty in this prototype.
  This is not the browser tree-recovery algorithm.
- Raw whitespace is preserved, not collapsed as in browser HTML. Malformed
  markup and declarations remain literal without entity decoding.

For HTML images, fallback content is assembled in attribute source order: the
first alt value supplies its text and objects; other attributes supply only
objects. Thus a destination object before the alt attribute appears before
alt content. A loaded-image presentation must retain those positions; that
presentation remains R5 work. Empty alt text stays empty here; no UI fallback
wording has been selected.

### GFM filter and raw-text provenance

In GFM mode, all nine disallowed raw-HTML names are filtered before the native
element policy. Their tag spellings become text, with one entity-decoding pass
and no retokenization. Filtered openings do not establish raw-text scope.
This models the filter's leading-`<` escaping as native visible text; it does
not establish published GFM parser conformance.

In CommonMark mode, `script`, `style`, `xmp`, `iframe`, `noembed`, and `noframes`
bodies are raw text; `title` and `textarea` bodies decode entities but do not
recognize nested tags. `plaintext` consumes the remaining raw input as text.
The unsupported wrappers still appear as literal tags. These bodies cannot
produce image or link descriptors. Matching raw-text closing tags are found
without treating script quotes as HTML attribute quotes.

Raw-text scope survives raw leaves. Tag spellings, comments, and entity
references split across leaves are not joined. Structured Markdown formatting
or image events during an active raw-text body reject the composition rather
than silently interpreting a contradictory parser event stream. There is no
HTML5 script escaped/double-escaped-state implementation.

The entity decoder implements only `amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`,
and semicolon-terminated decimal/hexadecimal scalar references. Unknown names
remain spelled as written. Invalid scalar values become U+FFFD. HTML5's full
named-reference table, legacy semicolon omission and numeric control remapping
remain unimplemented.

### Identity and work limits

The composer preflights all events, then compares the complete output object
sequence with the input sequence. It returns no composition on duplicate
identity, order mismatch, unbalanced Markdown, or exceeded limits. This tests
only supplied occurrence identities, not end-to-end sealed-object parsing.

| Budget | Prototype default |
| --- | ---: |
| Document input work units | 1,000,000 |
| Input events | 100,000 |
| Raw HTML tokens across all leaves | 100,000 |
| Combined Markdown/HTML formatting depth | 64 |
| Output runs | 100,000 |

Input work counts Unicode scalars in text and object identity strings. Every
empty text part costs one unit. The standalone tokenizer counts each object
as one opaque atom instead. Entity scanning examines at most 32 scalars per
candidate reference. Limits throw errors; production fallback presentation
has not been chosen.

## Review disposition

| Finding | Resolution and regression |
| --- | --- |
| F1: Raw-text bodies produced nested resource descriptors. | Added contextual raw-text/RCDATA scanning across leaves; tests cover scripts with apparent images/links and unmatched script quotes. |
| F2: GFM-filtered tokens displayed encoded entities unchanged. | Decode filtered-token text once without retokenizing; exact ink/style fixture added. |
| F3: Empty text fragments bypassed the input budget. | Charge empty fragments one unit in both tokenizer and document preflight; exact-limit and over-limit tests added. |
| F4: Later duplicate destinations containing reserved stand-ins did not refuse the selected address. | Check every duplicate `src`/`href`, including decoded spellings; typed-object and stand-in regressions added. |

## Next integration work

1. Review the proposed subset, recovery rules and object placement; replace or
   extend the intentionally incomplete entity/raw-text handling.
2. Connect a reviewed dialect parser/opaque-object adapter and compare its
   event stream with the existing pinned corpus evidence. These tests use
   hand-authored events, not a Markdown parser.
3. Map the output to native attributed text and prototype attachment/copy
   behavior together with the R5 work.
4. Complete R2 preference and surface tests before exposing a dialect picker.
   Complete R4 request policy and R5 lifecycle work before image actions.
5. Record instrumentation, performance and manual interaction evidence under
   the existing gates. No gate is closed by this slice.
