---
documentation_status: needs-review
---

# ADR-0066: A preview fetches an image only when its reader asks

- **Status:** proposed
- **Date:** 2026-11-14
- **Depends on:** [ADR-0021](0021-multi-device-sync-over-a-blind-relay.md) and [ADR-0027](0027-account-auth-gates-the-sync-channel.md), whose sync and sign-in routes this record leaves as they are

Read [ADR conventions](README.md) before filing or changing an ADR.

## Context

D-09 of the [2026-0915 UI/UX decisions](../spec/design/timeline-tabs/2026-0915-ui-ux-decisions.md#3--sealed-content-and-the-conceal-flow),
incorporated unchanged by the accepted
[sealed-content interface revision](../spec/design/timeline-tabs/2026-1031-sealed-content-ux-revision.md#whole-record-succession),
states: "Concealing is the app's one network outbound action". Its review
correction states: "“one outbound action” is narrowed to “one network
outbound action”; it does not replace D-32's egress inventory."

The [design principles](../spec/design/timeline-tabs/2026-0707-design-principles.md)
say the person can always answer whether anything leaves the machine, with
the answer (§5) "only on an explicit conceal, or to a device the user
enrolled, and the UI makes that boundary visible", and (§6) "Every
destination is one the user enrolled and can see."

The count in D-09 was already short before images. ADR-0021 states: "The
relay is a second allowed TLS destination." ADR-0027 states: "Use OAuth 2.0
authorization code with PKCE in the system browser." Feedback posts to the
configured server's `api/v3/feedback` (`FeedbackClient.endpointURL`);
accepted ADRs name the Send Feedback window, and none decides its request.

On 2026-10-16 the maintainer approved the Markdown preview direction that
the [preview design](../spec/design/timeline-tabs/2026-1016-markdown-dialects-and-preview.md#status-and-scope-authority)
records, including that remote images "load only after an explicit click",
with: "Yes agreed. Please capture the plan at docs/spec/design". The same day
the maintainer instructed "Please enact the recommended document
amendments". Those amendments (an image route ADR, a D-09 rewrite, a design
principles amendment and a Law 0001 row) were written on
`feat/markdown-dialects` and never reached main; they are kept at the tag
`archive/markdown-dialects`. On 2026-11-14 the maintainer confirmed both
instructions as theirs and asked for this record: "Yes to all. Please
continue".

Image loading shipped in PR 336 for issue 332. Its
[request and interaction policy](../spec/design/timeline-tabs/2026-1028-preview-image-loading.md)
is proposed and says of itself: "These details are implementation choices
for review, not an accepted privacy guarantee." Main therefore ships a
network request that D-09 and principles 5 and 6 do not allow.

## Decision

The rendered page preview may fetch a remote image, and only when the reader
activates that image's own control. An image fetch is a second kind of
network action beside concealing. D-09's sentence that concealing is the
one network outbound action no longer describes the app; the rest of D-09
stands for concealing.

- Opening, rendering, scrolling, resizing, selecting, refreshing, changing
  dialect and promoting a page start no request. One activation authorizes
  one request for one image occurrence, at the address its control shows.
- The control names the destination host before activation, and its help
  gives the full address. The server is the page author's choice, not an
  enrolled destination. Principles 5 and 6 gain this exception and no other:
  fetching an image enrolls nothing and grants no sync, device trust or
  other destination.
- The request asks the preview's page first, as the preview's readers do
  under [Law 0001](../law/0001-sealed-object.md#appkits-text-routes): when
  the reader activates, when the response arrives and before the image is
  shown. A page past its deadline, or a preview that no longer owns its
  presentation, fetches and shows nothing.
- An address that contains a sealed object, or its stand-in, is refused, and
  no sealed value is resolved to build a request. Objects in alt text stay
  objects by reference, in rendered and copied order, in every image state.
- An image fetch writes no `sent` record to the lifecycle ledger; that record
  keeps its meaning of a complete payload leaving.

Transport, limits and the control's states stay in the
[image loading record](../spec/design/timeline-tabs/2026-1028-preview-image-loading.md).

## Consequences

Main's image loading has an accepted rule to answer to once this record is
accepted, and the 2026-1028 policy becomes the detail under it rather than
the only authority.

A page's author can make the reader's Mac contact a server the reader never
chose, after one click on that image. The request exposes the full address,
which can include text the author wrote into it, along with the reader's
network address and ordinary TLS metadata. No anonymity follows from the
click being explicit.

Principle 5's question gains a third answer: the image control is where the
person sees that something leaves.

Concealing keeps D-09's confirmation and named destination. ADR-0021's relay
and ADR-0027's sign-in keep their own authority. ADR-0023's link rules are
unchanged: a plain click in a preview still opens nothing, and the image
control is a separate target from any link around the image. ADR-0030's
preview setting still sends nothing by itself.

Open questions for the maintainer:

- The feedback route is still outside any accepted record; this decision
  does not approve it.
- The shipped controls read **Load image**, **Cancel image**, **Unload
  image** and **Retry image**. ADR-0055 states: "Menu items and buttons are
  title case".
- The preview's gate checks the deadline and the presentation, not whether a
  name field or the note owns the keys. The 2026-10-16 draft asked for the
  keys check as well.

## Eject triggers

- A hand check with the pointer, the keyboard or VoiceOver shows that people
  cannot tell loading an image from opening a link or promoting a page.
- A transport test finds the request sends something the control's help does
  not disclose: a cookie, a credential, a redirect or a second host.
- Someone asks for automatic loading, a load all action or a remembered
  permission per site. That needs a successor decision, not a setting.

## Decision history

- 2026-10-16: The maintainer instructed the amendments this record restates.
  They stayed on `feat/markdown-dialects` (draft PR 328, closed unmerged).
- 2026-11-14: Proposed for main.
