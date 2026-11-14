# Clipboard provenance: facts and assumptions

## Status and scope

Research record for [ON-R01](transition.md#review-resolution-on-r01), dated 2026-11-14. This separates external evidence from proposed OnetimePad behavior. It is not a browser compatibility matrix, accepted security contract, or report of runtime testing.

The initial design uses manually supplied, locally managed values. Paste-time metadata may help suggest an optional source note; it does not create an external connection. The requested initial application categories are password managers, browsers, and terminal applications. No clipboard contents were inspected and no applications were launched during this research.

Navigation: [Overview](README.md) · [Conceptual model](conceptual-model.md) · [Scenarios](scenarios.md) · [Transition](transition.md).

## What the evidence establishes

### macOS pasteboard conventions

Apple's [NSPasteboard documentation](https://developer.apple.com/documentation/appkit/nspasteboard) describes pasteboard contents and types. The research did not identify a public pasteboard API supplying a trustworthy writer identity. This is a research limitation, not proof that no future API can provide one.

The community-maintained [NSPasteboard conventions](https://nspasteboard.org/) distinguish these markers:

| Marker | Documented meaning | Attribution limit |
| --- | --- | --- |
| `org.nspasteboard.source` | UTF-8 application bundle identifier; an empty string means the source is unknown | Voluntary metadata, not authenticated application identity |
| `org.nspasteboard.ConcealedType` | Content should be treated as confidential | Does not identify an application or issuer |
| `org.nspasteboard.TransientType` | Content is temporary | Does not identify an application or issuer |
| `com.agilebits.onepassword` | Listed as a proprietary 1Password confidentiality marker | Possible application hint, not proof of origin or current-version support |

The convention explicitly describes the source marker as:

> This is meant to be shown to the user by a supporting app for informational purposes only.

These are community conventions, not an OS-enforced provenance mechanism. Another writer can supply the same metadata. Clipboard managers may reproduce metadata; Universal Clipboard can introduce content from another device. The immediate copying application, original issuer, and authoritative store are different concepts.

### Password managers

| Application | Evidence found | Remaining uncertainty |
| --- | --- | --- |
| 1Password | The convention above lists `com.agilebits.onepassword`; community discussions also describe concealed markers | Current versions and desktop versus extension copy paths were not tested; consistent application identification is unverified |
| Bitwarden desktop | A [community discussion](https://community.bitwarden.com/t/prevent-passwords-copied-from-browser-extension-from-being-saved-in-macos-clipboard-history/82098) reports use of `org.nspasteboard.ConcealedType` and distinguishes browser-extension behavior | This shared marker does not identify Bitwarden; current desktop and extension coverage remains untested |
| KeePassXC | [Issue 6518](https://github.com/keepassxreboot/keepassxc/issues/6518) documents concealed markers and differences between copy paths | A historical issue is not a current support matrix; no unique source identifier was verified |
| Enpass | The community convention lists concealed and transient markers | Neither marker uniquely identifies Enpass; current behavior was not tested |

These sources support sensitivity-marker handling as a research direction, not a promise that password-manager names can be inferred. No consistent adoption of `org.nspasteboard.source` by these products was established.

### Browsers

**Chromium:** the inspected [macOS clipboard implementation](https://github.com/chromium/chromium/blob/main/ui/base/clipboard/clipboard_mac.mm) writes `kUTTypeChromiumSourceUrl` when its source endpoint is URL-based. This establishes a conditional implementation path, not coverage for every selection, form field, extension, or Copy button. It does not verify the behavior of every Chromium-derived browser or released version.

**Safari / WebKit:** a [2024 clipboard-format investigation](https://alexharri.com/blog/clipboard) describes `com.apple.WebKit.custom-pasteboard-data`, including source information used for same-origin handling of custom data. This is secondary evidence about a browser-specific container, not a stable public source-field contract. It does not establish that ordinary text copies or token Copy buttons always include an origin. WebKit metadata also does not uniquely identify Safari.

**Firefox:** the [W3C source-URL discussion](https://github.com/w3c/clipboard-apis/issues/244) documents `text/x-moz-url-priv`. A September 2026 Firefox developer comment describes origin-only metadata, omission for browser/extension UI, and `about:internet` in private browsing. That discussion does not establish macOS export. The inspected [macOS clipboard implementation](https://github.com/mozilla-firefox/firefox/blob/main/widget/cocoa/nsClipboard.mm) does not explicitly export that source format; macOS availability remains unverified.

The W3C discussion concerns standardization work, not an implemented cross-browser contract. A URL for a copied link or image is the destination/resource URL, not necessarily the page from which it was copied. None of these findings establishes reliable adoption of `org.nspasteboard.source` across browsers.

Source-code links above track moving branches. They record the basis of this investigation, not pinned evidence for a release-specific compatibility promise.

### Terminal applications

Terminal applications are requested scope, but no product-specific marker support was established during this research. Apple Terminal, iTerm2, and other terminals need separate investigation before naming supported products.

Even if metadata identifies a terminal application, it does not establish which command, local or remote host, shell session, or upstream secret store produced the copied text. Source suggestions should not invent those details.

## Proposed OnetimePad behavior

These are design targets, not existing guarantees:

1. Inspect available metadata only as part of an explicit paste. Do not monitor clipboard changes, foreground applications, browser tabs, or terminal sessions to infer origin.
2. Treat recognized application identifiers and browser-source metadata as optional hints. A concealed marker alone supplies no source name. Empty, missing, unsupported, malformed, or conflicting metadata may produce no suggestion.
3. Offer the person a source suggestion they can accept, edit, or ignore. Manual notes remain possible; lack of metadata does not block value entry.
4. Suggest a browser hostname by default, not an automatically saved full URL. URL paths, queries, and user information may contain sensitive data. Do not interpret link destinations as source-page evidence.
5. Keep the kind of evidence understandable: application-reported hint, inferred hint, or user-supplied note. User confirmation is not independent verification of origin or freshness.
6. Associate any accepted provenance with the supplied value/version rather than silently applying it to all later versions of the credential.
7. Do not infer freshness, synchronization, account, environment, credential issuer, or remote revocation from clipboard metadata.

Before implementation, decide parser allowlists and size limits, ambiguous-marker handling, URL normalization, and how source notes participate in storage, export, and deletion. Parsing a browser-private container is optional; unsupported formats can remain unknown. Do not retain raw metadata blobs or full URLs merely to enable suggestions without a separate review of that behavior.

## Assumptions to validate

- Available markers will be useful often enough to justify the interaction, even when many pastes yield no suggestion.
- A source hostname or immediate application name provides useful context without pretending to identify the authoritative credential store.
- Optional confirmation will add less friction than mandatory provenance entry.
- Selected terminal applications may expose usable metadata; no evidence yet supports a particular product.
- Application updates, extensions, clipboard managers, and copy method can change which metadata is present.

## Synthetic validation plan

Use fabricated text and URLs, never actual credentials. Inspect only user-initiated test pastes. Record application/version, macOS version, copy method, available marker names, and synthetic source values; do not build a background capture tool.

| Case | Observation or expected design outcome |
| --- | --- |
| Password manager desktop Copy versus extension Copy | Establish marker differences; a concealed marker alone must not produce a product name |
| Browser selected text, form field, and website Copy button | Establish when an actual source origin is available, rather than assuming identical paths |
| Browser copied link or image | Avoid treating resource destination as source page |
| Private browsing or empty source marker | No invented origin; opaque placeholders are not website suggestions |
| Terminal selection versus programmatic clipboard write | Establish whether either path supplies useful application metadata; do not infer command or host |
| Clipboard manager replay or cross-device copy | Treat retained source hints as unverified; do not assume the current foreground app is the source |
| Missing, malformed, oversized, spoofed, or conflicting markers | Paste remains possible without a misleading suggestion |
| Synthetic URL containing credentials, query token, or sensitive path | Proposed hostname-only suggestion does not reproduce those components |
| Accepted, edited, ignored, and manually entered source notes | Input remains optional and locally managed; freshness remains separate |

Any future automated OnetimePad UI probe must follow the project runtime-testing instructions: injected temporary state and `PageModel.Seams(stateDirectory:client:)` with the test-util in-memory credential client. Do not launch, replace, quit, or reset a person's running app, change production identity for a probe, or authorize a Keychain prompt to continue testing.

No cases above have been executed. Research establishes candidate metadata sources and limitations; implementation and release-specific coverage require subsequent validation.
