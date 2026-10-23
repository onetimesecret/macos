# Application lifecycle follow-up

Date: 2026-10-22. Implementation: [ADR-0059](../adr/0059-appkit-owns-window-presentation.md).

## Review disposition

| Finding | Materiality | Disposition | Evidence and verification |
| --- | --- | --- | --- |
| L1: Settings attachment opens another Settings window | Material: unsolicited startup UI | Addressed | Removed the SwiftUI application scene and redirect. Native menu installation and startup regressions assert that no Settings controller is created. |
| L2: Every application activation selects the editor | Material: interrupts returns to Settings and other windows | Addressed in implementation | Ordinary activation returns no presentation action. Reopen delegates visible ordinary windows and companion panels to AppKit. Router and lifecycle tests cover these decisions. |
| L3: Launch is classified by a two-second timer | Material: timing-dependent presentation | Addressed | Native untitled-open events select the initial editor; background activation does not. The launch timer and its classifier were removed. |
| L4: Unknown or unbundled app identity can resolve a production fallback | Material: unintended store selection during testing | Addressed at executable startup | The entry point rejects identities outside the three packaged app identifiers before constructing its delegate. Unit tests cover absent, unknown, prefix-like and recognized identifiers. This does not identify every possible misuse of a known development identity. |
| L5: The test lane can rebuild a live executable from its build directory | Material: disrupts ongoing development sessions | Addressed for supported build lanes | The test, development and packaging lanes share resolved executable-path inspection and stop before building. Script tests cover absolute and relative executable launches, symlinked paths, exited processes and inspection failures. Direct invocations of build tools remain outside these checks. |
| D1: ADR and specifications describe superseded activation behavior | Material: contradictory guidance | Addressed | ADR-0059 partially supersedes ADR-0033; current editor/background specifications and the current QA matrix describe the replacement. ADR lint and changed-document local-link checks pass. |
| D2: Old hardware results could be mistaken for verification of the replacement | Material: overstates validation | Addressed | The QA procedure identifies the replaced route expectations as historical and leaves replacement hardware checks unchecked. |

## PR-326 review follow-up

Claude's initial completed review was recovered from the edit history of its [review comment](https://github.com/onetimesecret/macos/pull/326#issuecomment-6353671800), which a later run replaced with a progress checklist. Each numbered item is assessed below; related Copilot and Greptile findings are included.

| Feedback | Disposition | Implementation or rationale |
| --- | --- | --- |
| Claude 1; Copilot startup drain: pending launch overwrites Finder selection; early reopen anchors today | Addressed | Pending events distinguish untitled launch from reopen. Finder opens supersede either pending event, including a gated file queue. Reopen preserves its activation route. Delegate regressions cover both event orders and the modal gate. |
| Claude 2: check nondefault launch metadata | Addressed with narrower interpretation | Explicit false `launchIsDefaultUserInfoKey` suppresses queued and later untitled callbacks, without suppressing an explicit reopen or Finder file open. Apple describes a nondefault launch, not a general background-launch flag; login and restoration still need the hardware checks below. |
| Claude 3: newer companion request can supersede deferred editor selection | Retained deliberately | Preserve the companion's activation request rather than retrying the earlier editor selection over Settings or About. The router regression asserts that a pending editor route returns no presentation action when another window requested activation. No comment-only workaround was added. |
| Claude 4: main menu must precede role registration | Addressed | Install the main hierarchy before registering Services and Window roles. Help remains registered by the delegate afterward. Tests cover role identity and reinstallation; populated Services and automatic window-list behavior still need manual checking. |
| Claude 5; Copilot build guard: brittle status capture, relative and symlinked paths | Addressed | Replace command-string matching with resolved executable-path inspection. Unknown inspection failures stop the supported script; exited processes are skipped. Native tests launch only owned disposable command-line fixtures using absolute and relative paths. |
| Claude 6: launch-identity diagnostics, fork configuration, comment framing, Darwin import | Addressed except import removal | Refusal includes the observed identifier. The shell README documents recognized identifiers and how forks update packaging and constants. The type comment describes its identifier list. Keep `import Darwin` for direct `exit`/`EXIT_FAILURE` use rather than relying on transitive imports. |
| Claude 7: dead activation case, duplicate policy, binding consistency, menu lifetime | Addressed | Remove the unused late-activation reason and test the actual activation router. Set the regular policy once at entry. Bind commands consistently and replace dangling menu-controller captures with weak references. Tests release and reinstall the controller while retaining old menus. |
| Claude 8: shell README still recommends bare swift run | Addressed | Replace the stale loop with packaged development and supported isolated test commands. |
| Claude 9: consciously assess native-menu parity | Assessed; broader inventory deferred | Restore the concrete Find and Replace omission below. Retain the existing explicit Print omission. No additional View or Minimize All command was established as a regression from the previous app implementation; Emoji/Symbols and Dictation population remain manual inventory checks. |
| Claude docs/tests: add login/restoration checks; remove fixture try! | Addressed | Add unchecked login and session-restoration rows. Fixture I/O and allocation failures now throw into XCTest. |
| Copilot companion-panel reopen | Addressed | A visible About panel is ordered directly when AppKit reports no visible ordinary windows; returning false prevents native untitled fallback. Modal reopens likewise return false. Delegate tests cover About, Settings and modal callback sequences. |
| Greptile: Find and Replace disappears | Addressed | Restore Find and Replace with Command-Option-F, native responder target and `showReplaceInterface`. Tests cover all five Find commands; existing editor tests cover replacement behavior. |

The later completed Claude review expanded to 23 numbered items in the same comment. Items 2–5, 7, 10, 12–13, 18–19 and 21 overlap dispositions above. The additions are assessed here:

| Later Claude item | Disposition | Implementation or rationale |
| --- | --- | --- |
| 1, 18: repeated untitled callbacks anchor today | Addressed | Initial opening is consumed once; later callbacks use reopen behavior. Finder intent and early reopen consume the initial intent too. Callback tests verify file selection and anchor counts. |
| 6, 8: duplicate process inspection and packaging/dev gaps | Addressed | Build-lane helpers share resolved-path inspection for test, dev and packaging. The dev lane's existing graceful-quit flow also stops on inspection failure; fixture tests mock builds and quit commands. |
| 9: implicit shipping fallback below app entry | Addressed | CompanionKit's resolver returns no identity for unknown hosts. Its runtime wrapper refuses them rather than silently selecting shipping configuration. XCTest retains an explicit configuration exception and the existing requirement for injected model seams. Custom non-app hosts must supply an explicit FormFactor. This is not identity authentication. |
| 10: allowlist rejects forks | Retained with configuration instructions | Identifier spelling is independent of signature: re-signing with the same identifier does not fail this comparison. Forks with different identifiers update packaging and FormFactor constants, or custom hosts inject FormFactor. Do not restore silent shipping fallback to accommodate them. |
| 11: unused companion branches in explicit route decisions | Addressed | Remove unreachable checks from launch and reopen decisions. Deferred-activation companion precedence remains in routeForActivation and its regression. |
| 14: monolithic menu installation | Addressed | Extract per-menu construction methods; installation only builds the hierarchy and registers menu roles. |
| 15: decoder traps | Addressed | Archived action items decode with no executable closure and disabled validation. A real archive roundtrip regression invokes the decoded action. |
| 16: menu inventory | Partially addressed; manual inventory explicit | Add the public character-palette action and test its native responder target. No public Dictation action was found in the SDK headers; do not invent one. Fullscreen retitling, automatic menu additions and other standard window commands remain unchecked in the manual matrix. |
| 17: localization | Addressed structurally; translations deferred | Route menu titles through existing CompanionL10n lookup. The current resource bundle provides English; no additional translations were invented. |
| 20: test hygiene | Assessed | Fixture setup throws. The Settings test intentionally closes and reopens the same controller, then uses defer for cleanup. The FFI source documents companion_init as idempotent; no extra once-only latch was added. |
| 22: reported macOS version | Retained | The supplied Apple crash report identifies macOS 27.2 (26B5112a); this was not a guessed or normalized version. |
| 23: handoff state sentence removed | Addressed | Restore explicit page, caret and scroll continuity in the primary-editor draft specification. The existing model-state paragraph also remains. |

Apple's [launch metadata reference](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey) identifies file opens, Services and saved-state restoration as nondefault launches. The [reopen callback reference](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) describes the native untitled fallback when only panels remain. These API descriptions motivate the callback tests; they do not substitute for the remaining platform executions.

## Validation scope

The review follow-up passed 381 OnetimePad tests and 1,826 CompanionKit tests (2,207 total), plus 99 script tests. The full Swift run passed CompanionKit but initially failed four native assertions comparing `/var` with `/private/var`; after normalizing both sides of those fixture path comparisons, all 381 native tests passed on rerun. The final source passed ADR lint (52 records), shell syntax, whitespace diagnostics and 39 changed-document local file links. Native menu tests include an actual archive roundtrip and Services-role reinstallation. No installed application was launched, quit or used as a fixture.

Historical validation before the review follow-up:

The complete Swift suite passed 2,192 tests after the lifecycle, menu and launch-identity changes. After the final companion-panel correction, the native-app target passed a separate rerun of 367 tests. The script suite passed 81 tests. ADR lint and whitespace diagnostics passed.

Transient packaged probes on macOS 27.2 observed foreground launch opening an editor without Settings, background launch opening neither, background activation creating no editor, and reopen opening or deminiaturizing an editor when appropriate. These probes are not a complete acceptance run: a fixed-delay focus assertion trapped once, another run passed, and a later run reported focus-check failures. The snapshots did not establish a stable, complete Cmd-Tab/focus verdict. Do not treat these checks as all passed.

The temporary probes used persistent credentials despite their separate bundle identities. Rebuilt probes subsequently logged restore failures under their own credential services. They were stopped, and their temporary source instrumentation was removed. Further automated checks use injected temporary directories and in-memory credentials. The executable startup check rejects unknown or unbundled identities. Repository runtime-testing instructions require temporary state and in-memory credentials for automated probes.

The user confirmed that OnetimePad Local's stored content was erased during testing. The responsible testing action and mechanism remain unresolved, including whether the Keychain prompts were related. Its sandboxed storage could not be inspected. The testing safeguards above do not establish the cause or demonstrate that the underlying data-loss problem is fixed.

No macOS 13 execution, full replacement hardware matrix, or stable cross-Space focus run was performed. The source still targets macOS 13. The [current manual procedure](verification-procedures/spaces-and-cmd-tab.md#current-launch-and-activation-checks-adr-0059) records the remaining checks.
