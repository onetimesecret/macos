---
id: 2026-1016-ui-ux-decisions
title: UI/UX decisions with explicit preview resources
status: accepted
dated: 2026-10-16
supersedes: docs/spec/design/2026-0915-ui-ux-decisions.md
superseded-by:
reviewed: 2026-10-16
surfaces: OnetimePad page presentations, Markdown preview and Settings
sources:
  - docs/spec/design/2026-0915-ui-ux-decisions.md
  - docs/spec/design/2026-0916-clipboard-clear-interval.md
  - docs/spec/design/2026-0916-rail-redundancy.md
  - docs/law/0001-sealed-object.md
  - docs/law/0007-edit-in-place.md
  - docs/adr/0059-preview-images-use-an-explicit-resource-request-route.md
  - the maintainer's 2026-10-16 instruction to enact the recommended document amendments
---

# UI/UX decisions with explicit preview resources

## Authority and scope

The maintainer's instruction on 2026-10-16, “Please enact the recommended document amendments”, adopts the policy amendments in this record. The approved concept is selectable CommonMark and GitHub Flavored Markdown, GFM by default, restricted HTML formatting without scripts or embedded browser content, and explicitly activated remote images.

This record supersedes the [September 15 UI/UX record](2026-0915-ui-ux-decisions.md) in full. It incorporates surviving decisions by reference rather than duplicate them. Acceptance changes the required behavior; it is not evidence of implementation, parser conformance, request isolation or completed accessibility checks. The [technical plan](2026-1016-markdown-dialects-and-preview.md) remains draft for unresolved implementation details.

## Incorporation and precedence

The incorporated pre-existing sources are the versions in repository revision `103eef0270843173c3acbf9f3013bd421f602dd6`, before this enactment. The newly enacted resource policy is in D-09 and the preview amendments below, [ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md), and Law 0001's dated resource-request amendment. These are new decisions, not independent evidence validating their implementation.

1. Incorporate the predecessor's operative sections 1–9, including D-01 through D-33, acceptance criteria and explicit verification debt, subject to the schedule below. Existing open decisions D-04 and D-13's surviving default/prototype question remain open.
2. The listed intervening accepted decisions take precedence over predecessor passages within their stated scopes. This record's amendments replace only the expressly identified portions. All other surviving requirements remain in force.
3. The predecessor's introduction, section 0 publication procedure, section 10 history, code observations and mockups remain historical context. Implementation observations and verification debt do not establish tested behavior.
4. Incorporation does not accept a linked proposal, draft law, withdrawn ADR version or unratified specification. Future amendments require their own recorded authority; the revision pin does not incorporate them automatically.
5. This record follows the [dated-record publication procedure](2026-0915-ui-ux-decisions.md#0--pipeline-and-status): a changed decision requires a new dated successor; the predecessor changes only status and successor reference. Law amendments follow the [law conventions](../../law/README.md#pipeline), and ADR successors follow the [ADR conventions](../../adr/README.md#lifecycle).

### Incorporated decision schedule

Each linked pre-existing source below uses the revision identified above. Accepted clauses apply only within their stated scope; proposed bases or amendments are not accepted by this table.

| Predecessor decisions | Incorporated requirements and controlling amendments |
| --- | --- |
| D-01–D-04 | Preserve ambient stance, keyboard, appearance and accessibility requirements, including D-03's October 14 contrast correction. Apply accepted [ADR-0032](../../adr/0032-inactive-raised-surfaces-follow-normal-app-stacking.md), [ADR-0033](../../adr/0033-separate-the-primary-editor-from-the-ambient-panel.md), [ADR-0034](../../adr/0034-full-screen-participation-follows-altitude.md) and [ADR-0036](../../adr/0036-editing-presentations-are-mutually-exclusive.md) within their window/ownership/visibility scopes. D-04 remains open. |
| D-05–D-06 | Preserve source-styling requirements as qualified by accepted [ADR-0029](../../adr/0029-betlang-source-language-detection-behind-the-existing-c-abi.md) and [ADR-0030](../../adr/0030-visible-pages-share-preview-rendering.md), and the explicit source/preview distinction below. Accepted inferred-language and whole-file Source presentation are not prohibited by D-06's older fence-label wording. |
| D-07 | Preserve persistent editor/storage-switch behavior within ADR-0033's window roles and exclusive ownership, as amended by ADR-0036's mutually exclusive presentations. Do not restore simultaneous content-window visibility or the superseded non-owner glance. |
| D-08–D-10 and D-27–D-33 | Incorporate accepted [Law 0001](../../law/0001-sealed-object.md)'s contract and amendments through October 16, [ADR-0042](../../adr/0042-a-sealed-name-is-a-shell-identifier.md), [ADR-0043](../../adr/0043-a-sealed-objects-name-and-note-are-fields-of-its-chip.md), [ADR-0044](../../adr/0044-a-sealed-objects-note-is-edited-on-the-pages-own-surface.md), [ADR-0045](../../adr/0045-the-core-composes-and-resolves-the-sealed-fragment.md), [ADR-0046](../../adr/0046-a-removed-sealed-object-stays-recoverable-until-its-page-ends.md) and [ADR-0047](../../adr/0047-name-value-copies-the-value-unquoted.md). Replace D-09's app-wide action count below; preserve its other surviving behavior. |
| D-11–D-13 and D-26 | Incorporate the accepted [clear-interval/navigator successor](2026-0916-clipboard-clear-interval.md), [rail-redundancy record](2026-0916-rail-redundancy.md) and [ADR-0037](../../adr/0037-one-page-layout-setting.md). Two settings/four combinations and D-13's obsolete prerequisite are replaced by Page layout: Tabs or Timeline. Surviving layout metrics and the default/prototype question remain. |
| D-14–D-16 | Preserve noninterrupting interaction, sentence register and empty-state requirements. Apply accepted [Law 0007](../../law/0007-edit-in-place.md) to in-place naming and [ADR-0055](../../adr/0055-menus-and-buttons-use-the-platforms-wording.md) to menu/button wording. Sentence register does not override title-case controls. |
| D-17–D-19 | Preserve accepted file-conflict, render-state, draft-stamp and quit requirements. Do not adopt the draft September 30 Locate changes or a proposed file architecture transitively. |
| D-20–D-22 | Preserve sync-surface requirements with accepted [ADR-0021](../../adr/0021-multi-device-sync-over-a-blind-relay.md) and [ADR-0027](../../adr/0027-account-auth-gates-the-sync-channel.md). Proposed sync amendments are not incorporated as accepted. |
| D-23–D-25 | Preserve native Settings, write-only credential UI and conditional capture-control configuration, subject to the capture qualification below. Do not adopt the proposed fifth Pads form by reference. |
| Unnumbered provisions | Preserve surviving contract, typography, geometry, contrast and accessibility requirements from sections 1–9, including accepted [ADR-0022 Amendment 1](../../adr/0022-fence-regions-coalesce-stamps-in-display.md#amendment-1-the-regions-reading-rides-its-opening-line) for fence provenance. Apply the same named qualifications as the numbered decisions. |

The two accepted September 16 records remain accepted; this successor does not supersede them. Their D-34–D-48 provisions retain their identifiers and stated amendment relationships.

### Exclusions that remain effective

- D-10's September 15 click-to-open-menu amendment does not override Law 0001's subsequent selection, menu and named copy-zone rules.
- Old 90-second clipboard wording does not override the accepted clear-interval record's 60-second, change-count-guarded attempt. No broader observer-retention or erasure result is inferred.
- Boot-bound autosave or quit/reboot amnesia does not override accepted [ADR-0016](../../adr/0016-content-persists-across-restart.md). Its persistence scope and snapshot/rollback residual exposures remain unchanged.
- Screenshot wording describes capture-control configuration, not universal prevention. Preserve the predecessor's October 14 publication clarification; `sharingType = .none` is not evidence that every screenshot or screen-sharing mechanism excludes the surface.
- Expiry follows Law 0001's deadline and settlement rows, including documented display gaps. Earlier absolute disappearance wording is not a verified instantaneous result.
- Sealed-object payload, excerpt, name/note, fragment, removal and ledger behavior follows the accepted Law 0001 contract and named ADRs, not obsolete counts, shell-visible-text prohibitions or an unratified appearance specification.
- Draft laws, proposed ADRs or amendments, the withdrawn October ADR versions, and research/delivery material remain non-authoritative unless a named accepted source explicitly incorporates a particular provision.

## D-09 · Concealment and separately authorized resources

D-09's exclusivity concerns network promotion of sealed payloads to a one-time link. It is not a count of all application network actions or destinations. Its remaining inline-confirmation, named-destination, discoverability, link-lifetime, failure/retry and optional-local-burn requirements are incorporated unchanged, including ADR-0055's wording amendment. A local copy is not burned automatically.

This replacement removes the predecessor's app-wide one-network-action restriction and the same restriction in its September 15 review correction. It does not change D-32's three complete-payload egresses or authorize the Swift shell to receive sealed payloads. Existing sync and authentication retain their separate ADR-0021/ADR-0027 authority.

### Preview-resource authorization

[ADR-0059](../../adr/0059-preview-images-use-an-explicit-resource-request-route.md#decision) enacts the resource route, jointly with [Law 0001's preview-resource row](../../law/0001-sealed-object.md#appkits-text-routes):

- Markdown images and supported HTML images use a separate, explicitly activated **Load Image** control. Its destination is visible before activation, with disclosure that the resource provider receives the resource URL and request metadata. The recipient is identified by the document's resource address, not assumed to be the OTS server or an enrolled device. Intermediaries and redirects require the further R4 policy.
- Parsing, HTML conversion, rendering, styling, preview opening, scrolling, resizing, reparsing and cache refresh do not authorize image requests.
- Ordinary clicks on text, links and image bodies do not load images. Link opening retains its aimed-link route and ⌘-click behavior. A linked image has distinct load and open targets.
- On a nonselected page, the first activation only promotes that page. A separate activation is required to load. Pointer, keyboard and VoiceOver use the same originating-page, deadline and key-ownership gates; their exact mechanics remain R5 work.
- A resource address containing a sealed object or its parser stand-in is refused. Objects inside alt text retain their identity and rendered/copy order through every image state; a loaded image does not erase their positions.
- Image fetches do not create lifecycle-ledger `sent` events or add image URLs, alt text or response details to that event. Any request-audit feature requires a separate accepted decision. Operational request logging/cache policy remains R4 work.

This is an explicit, narrow amendment to [design principles §§3, 5 and 6](2026-0707-design-principles.md#amendment-e--restricted-page-preview-and-explicit-resources-2026-10-16): §3 permits the approved restricted formatting and images on rendered page preview, not expanded sealed-content or recognition surfaces; §§5–6 permit a document-provided resource destination authorized for an image request without becoming an enrolled sync destination. It grants no device trust or replication permission and does not authorize unrelated traffic. The network-free local editing path remains available; merely displaying content does not authorize the resource route.

The bounded route inventory in ADR-0059 distinguishes conceal, sync/authentication, feedback, release-feed evidence and images. Unresolved authority for feedback or release checks is not approved by this amendment and does not restore D-09 as an app-wide prohibition on already accepted sync/authentication.

## D-05 and D-06 · Source styling and rendered page preview

**Markup-preserving editor styling** names the mounted/quiet source presentation governed by ADR-0030. D-05's visible-markup and source-copy requirements apply there. D-06 is qualified by ADR-0029's accepted language-state/Source presentation and ADR-0030's visible-page scope.

**Rendered page preview** names the separate syntax-removing page surface governed by Law 0001's October 16 preview amendment. D-05's sentence prohibiting a renderer from hiding markup does not apply to that surface. Preview copy uses rendered ink and sealed-object references in rendered order, not the source Markdown. Rendering does not itself rewrite page bytes.

ADR-0059 partially supersedes only ADR-0030's surface-scope ambiguity. Its source-styling preference scopes, pure display refresh, invalidation and geometry obligations remain unchanged. The dialect/header-toggle/scope matrix remains R2 work; neither rendering path acquires request authority from a cache refresh.

## Approved scope and remaining technical work

Settings → Code offers CommonMark and GitHub Flavored Markdown, with GFM as the default. The approved baseline is rendered page preview, not unrequested changes to editor/file semantics or a Settings reorganization. Supported HTML formatting is restricted; scripts, embedded browser content and automatic resource loading are excluded.

The exact dialect versions/parser, sealed-object grammar extension, HTML composition and allowlist, preference precedence/storage, consent lifetime, schemes/ATS, redirect/destination rules, credentials/headers, cache/storage/logging, image formats/decoding and numeric limits, attachment interactions and accessibility remain technical decisions in R1–R5. Resource authority is accepted; these details are not selected by this record. R6 still requires integrated release evidence.

## Acceptance and evidence boundary

The policy-reconciliation gate R0 is closed by this accepted successor, ADR-0059 and the dated Law 0001 amendment. R1–R6 are not closed by this enactment. Existing test debt remains debt; new resource-route tests are owed to the plan's R4/R5 work before production wiring.

This record changes documents only. It does not report parser experiments, transport traces, application tests, macOS 13.0 decoder results or keyboard/VoiceOver observations.
