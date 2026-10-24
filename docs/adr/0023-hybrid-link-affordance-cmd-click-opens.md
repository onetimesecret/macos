---
documentation_status: reviewed # draft | needs-review | reviewed | stale
---

# ADR-0023: Hybrid markdown link affordance — ⌘-click opens, a plain click edits

- **Status:** accepted
- **Date:** 2026-08-25
- **Superseded in part by:** [ADR-0059](0059-preview-images-use-an-explicit-resource-request-route.md), only the Consequences bullet beginning “Opening is deliberate”, narrowing its app-wide reading; the source text and link behavior remain unchanged.

## Context

The page styles markdown without rewriting it (docs/spec/design/04):
markup stays on screen, dimmed, and the bytes never change. URLs had no
affordance at all — a link pasted into a page had to be selected and
copied back out to be followed — and the two obvious fixes both break
something. The system's automatic link detection writes `.link`
attributes as the user types, a second styling authority beside the
restyle pass with its own, looser opinion of what a URL is. And
AppKit's default click behavior opens a link on any click, which makes
the URL's own text uneditable by mouse: on a page whose whole posture
is "this is your editable text", a click that navigates instead of
placing the caret is a stolen gesture.

## Decision

Links are read and styled by the restyle pass alone, and opened only by
an aimed gesture. A bare http(s) URL in body ink, and a markdown
`[text](url)` whose target is http(s), carry `.link` and render as
links, with the markdown syntax dimmed in place the way a fence's rules
are. The detection is deliberately conservative — http and https only,
trailing sentence punctuation handed back to the sentence, nothing
inside a fence — because a link is an offer to open something, and a
guessed-at target is worse than plain ink. Every click on a link is
claimed by the delegate: with ⌘ held the target opens in the default
browser; without it the caret is placed where the click fell and
nothing else happens. Automatic link detection is off, and the system's
link text attributes are emptied so neither the styling nor the
pointing-hand cursor promises open-on-click.

## Consequences

- The URL's text edits like any other ink: click into it, arrow through
  it, break it with a keystroke — the restyle pass un-links whatever
  the edit un-made.
- Opening is deliberate and therefore auditable as a gesture: nothing
  leaves the app because a click landed a pixel too far left.
- The affordance is quieter than the platform norm — no hand cursor, no
  open-on-click — and that is a cost accepted knowingly: the page is an
  editor first, and the ⌘ convention is the one every macOS editor's
  "open link" already uses.
- Only http and https open. Anything else a page carries is text.

## Decision history

- 2026-10-16: Superseded in part by [ADR-0059](0059-preview-images-use-an-explicit-resource-request-route.md), only for the Consequences bullet beginning “Opening is deliberate”, narrowing its app-wide reading while preserving the source text. A distinct, destination-visible **Load Image** control may authorize a preview-resource request. Editable-ink link detection, plain-click editing and ⌘-click link opening remain unchanged; ordinary preview text, link and image-body clicks do not load images. Exact image-control gestures remain R5 work.

## Eject triggers

- The conservative detector misses enough real links in practice that
  the reading moves to `NSDataDetector`, behind the same pure seam and
  the same http(s) gate.
- A hover affordance (hand cursor under ⌘, a title tooltip) proves
  wanted: it lands in the text view's cursor handling without touching
  this decision's click grammar.
