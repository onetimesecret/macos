# Application lifecycle follow-up

Date: 2026-10-22. Implementation: [ADR-0059](../adr/0059-appkit-owns-window-presentation.md).

## Review disposition

| Finding | Materiality | Disposition | Evidence and verification |
| --- | --- | --- | --- |
| L1: Settings attachment opens another Settings window | Material: unsolicited startup UI | Addressed | Removed the SwiftUI application scene and redirect. Native menu installation and startup regressions assert that no Settings controller is created. |
| L2: Every application activation selects the editor | Material: interrupts returns to Settings and other windows | Addressed in implementation | Ordinary activation returns no presentation action. Reopen delegates visible ordinary windows and companion panels to AppKit. Router and lifecycle tests cover these decisions. |
| L3: Launch is classified by a two-second timer | Material: timing-dependent presentation | Addressed | Native untitled-open events select the initial editor; background activation does not. The launch timer and its classifier were removed. |
| L4: Unknown or unbundled app identity can resolve a production fallback | Material: unintended store selection during testing | Addressed at executable startup | The entry point rejects identities outside the three packaged app identifiers before constructing its delegate. Unit tests cover absent, unknown, prefix-like and recognized identifiers. This does not identify every possible misuse of a known development identity. |
| L5: The test lane can rebuild a live executable from its build directory | Material: disrupts ongoing development sessions | Addressed for supported script lanes | The test, development and packaging lanes share resolved executable-path inspection and stop before building. Installation uses the shared query before quitting or replacing a bundle. Script tests cover absolute and relative executable launches, symlinked paths, exited processes and inspection failures. Direct invocations of build tools remain outside these checks. |
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

## Updated Claude review and CI follow-up

The review on commit `50825193` added these findings. Its [updated comment](https://github.com/onetimesecret/macos/pull/326#issuecomment-6353671800) is assessed separately from the earlier reviews above.

| Feedback | Disposition | Implementation or rationale |
| --- | --- | --- |
| 1: other users' processes can fail inspection with EPERM | Addressed; confirmed by CI | Both shell and release packaging failed before building in run 39878137339 with EPERM. Enumerate current-user processes with libproc's PROC_UID_ONLY; inspection errors for those processes still stop the lane. Native fixtures and a libproc argument regression cover the change. A local ordinary-user audit saw no EPERM, which does not negate the runner failures. |
| 2: public FormFactor.panel traps in a packaged pad host | Addressed | Remove the archived panel's production accessor. Legacy panel configuration is explicit in a test-only fixture, and the runtime resolver is internal. ADR-0014's accepted decision is “Archive the panel.” No production callers remained. |
| 3: arbitrary reopen window and ordering a sheet directly | Addressed | Use AppKit's front-to-back window enumeration, which includes panels, and order a sheet's parent. The scripting orderedWindows list can omit panels. Delegate regressions check actual panel ordering and attached-sheet parent selection. |
| 4: localized Help title breaks delegate lookup | Addressed | Pass the constructed Help menu directly to item installation and register NSApp.helpMenu alongside the other roles. A non-English menu-title fixture exercises installation. |
| 5: secure restoration policy and late menu construction | Addressed | Install menus during willFinishLaunching and opt in to secure restoration coders. This does not enable restoration for windows marked isRestorable=false; session restoration remains a manual check. |
| 5: missing CLI arguments and lsof text mappings | Addressed | Invalid arguments produce a usage message and status 2. README records that conservative text mapping checks include dylibs. |
| 5: custom Swift build locations | Scope clarified | Supported scripts check shell/.build. README explicitly excludes custom --scratch-path / --build-path outputs and provides the direct guard command for them. |
| 5: repeated file checks during activation and reopen | Retained | An explicit reopen can occur while the application is already active, so it cannot rely on a new didBecomeActive callback. Keep the idempotent file refresh at both entry points. |

The separate platform failure in run 39878137339 occurred in companion-pasteboard: a text read failed and an Objective-C exception aborted the test process. Twenty isolated pasteboard tests passed locally, and 50 repetitions passed (1,000 executions); the general-pasteboard-name test was excluded. No Rust behavior change is justified by that evidence. The platform job passed on rerun at the same commit; the original exception remains unexplained. Subsequent runs expose uncaptured test output and Rust backtraces for diagnosis if it repeats.

## Repeat review on 1abb03af

All seven workflow checks passed on `1abb03af` (CI run 39913125058; Claude run 39913125075). The next completed Claude review added the following distinct suggestions:

| Feedback | Disposition | Implementation or rationale |
| --- | --- | --- |
| 1: install.sh shadows the shared process guard with pgrep | Addressed | Remove the local override so installation uses resolved executable paths and stops on inspection errors. Isolated install tests use disposable fixture bundles and mocked commands; no installed application is modified or quit. This finding does not establish the mechanism of Local's reported content loss. |
| 2: an ambient-panel sheet can order the ambient parent outside model routing | Addressed | Apply the ambient exclusion to the sheet parent before selecting a reopen target. Retain ordinary Settings-parent sheet handling; cover the ambient-parent case separately. |
| 3: nondefault launch metadata suppresses later callbacks for the whole process | Addressed | Limit suppression to the initial opening and consume that opening. Later untitled callbacks can follow the reopen route without selecting today's page. Finder queues retain precedence. |
| 4: menu localization happens twice | Addressed | Localize titles in one layer and avoid looking up formatted output as another localization key. |
| 5: Python minimum, mapping error errno, and guard exit codes | Addressed | State the Python minimum, use an explicit mapping-inspection error, and distinguish inspection failure from a detected running executable. |
| 6: Jump to Selection | Addressed | Add Command-J with the native centerSelectionInVisibleArea responder action and shortcut coverage. |
| Nit: empty login-launch MARK | Addressed | Remove the obsolete section marker; the delegate lifecycle tests cover background startup. |
| Nit: test-only panel identity assertion is tautological | Addressed | Remove the dead runner-identity assertions against the archived panel fixture; production resolver and backdrop assertions remain. |
| Nit: companion activation context is only read by deferred activation | Retained with rationale | Explicit launch/reopen routes intentionally ignore another window's older activation request; deferred activation respects a newer companion request. Existing router tests cover that distinction. No comment-only change was made. |
| Nit: curly apostrophe in README | Addressed | Use the surrounding ASCII spelling. |

## Review and platform failure on 0cd77310

The shell, release packaging, logic, ADR and secret-scan checks passed on `0cd77310`; platform run 39914544238 failed in `our_own_transient_write_is_not_offered`. Claude's completed review added six findings:

| Feedback | Disposition | Implementation or rationale |
| --- | --- | --- |
| 1: Settings remains restorable | Addressed | Explicitly set isRestorable=false when constructing native Settings; assert it before and after close/reopen. The old redirect set this property, while the native controller omitted it. This does not substitute for session-restoration execution. |
| 2: abandoned companion activation flags can discard a later summon | Addressed | Clear companion flags on resignation and whenever a newer explicit summon supersedes them. Resignation alone is insufficient if activation never arrived. Tests cover earlier Settings, About and Feedback requests, both with and without resignation, and a newer companion request still taking precedence over deferred editor presentation. |
| 3: queued Finder early return depends on another method consuming initial intent | Addressed defensively | Consume initial opening at the nonempty-queue early return too. Current file filtering already made the sequence correct; this local assignment removes the implicit dependency. |
| 4: guard message tells every lane to rerun tests | Addressed | Use command-neutral instructions. |
| 5: any current-user inspection error stops the lane | Retained deliberately | Permission and inspection failures remain distinct from no running process. Existing regressions exercise this behavior; future runner failures require diagnosis rather than skipping uninspectable processes. |
| 6: menu closures retain the delegate | Application lifetime retained; fixture omission fixed | Strong app captures suit the installed menu's lifetime. The lifecycle test helper now restores all four menu roles and the canonical Services menu parent. A regression verifies role identity and delegate/model release after the fixture ends. |

The failing pasteboard fixture cleared the board and wrote a string without first declaring its type or checking the result. Apple's [setString(_:forType:) reference](https://developer.apple.com/documentation/appkit/nspasteboard/setstring(_:fortype:)) states: “The type must have been declared by a previous declareTypes(_:owner:) message.” The fixture now declares the type, checks clear/write results, and verifies readback. A repeated replacement regression checks marker removal and stale-clear rejection.

This is a confirmed fixture defect, not a reproduced explanation of the intermittent CI mechanism: 10,000 local repetitions of the old sequence did not fail. The earlier foreign-exception abort remains independently unexplained. No retry, serialization, or removed coverage is used as the fix. Local Rust executions use uniquely named test boards and exclude the general-pasteboard-name test.

The next CI run, 39917328135 on `52838cdc`, passed platform (both workspace test shapes), release packaging, logic, ADR and secret scan. Shell testing exposed a portability issue in the new teardown regression: the runner retained the installed Window and Services menus when the fixture attempted to restore absent roles to nil, retaining the delegate and model. The XCTest helper now creates neutral menus for missing roles before taking its snapshot; existing nonnil roles and Services parent remain the restore target. The release assertions stay in place. The targeted teardown regression and all 391 native tests passed after this adjustment. The same initializer is shared with the standalone Find-menu fixture; its six filtered tests, including a new delegate-release regression, and all 392 native tests then passed. This avoids depending on lifecycle tests running first.

## Validation scope

This round passed 391 native tests and 1,826 CompanionKit tests (2,217 total), 20 guard tests, and 21 isolated pasteboard tests. Twenty pasteboard stress runs passed 420 test executions and 2,000 replacement cycles. The full Swift run passed CompanionKit but initially crashed in the new native activation matrix: Zombies identified an over-release of AppKit's NSSystemInfoPanel during fixture cleanup. The fixture now hides panels rather than closing them and restores prior window visibility. The matrix passed with Zombies enabled, then all 391 native tests passed on rerun. ADR lint (52 records), Rust formatting, shell syntax and whitespace checks passed. No installed app was used as a fixture.

Previous repeat-review validation:

The repeat-review follow-up passed 388 native tests and 1,826 CompanionKit tests (2,214 total), plus 106 script tests. The full run passed CompanionKit; new native assertions initially omitted the deferred activation callback. After adding that callback to the fixtures, all native tests passed on rerun. The fixtures use temporary state and ephemeral credentials; the install tests use mocked application commands. ADR lint (52 records), shell syntax and whitespace checks passed. The pre-commit hook skipped because its configuration is absent; it is not counted as validation.

Previous updated-review validation:

The updated-review follow-up passed all 385 native tests and all 1,826 CompanionKit tests (2,211 total), plus 101 script tests. A targeted lifecycle run also passed all 21 tests. The new panel-order fixture initially hid on XCTest deactivation; it now stays onscreen and verifies enumeration order before calling the delegate. SDK-backed front-to-back enumeration includes panels that the scripting orderedWindows list omits. ADR lint (52 records), shell syntax, whitespace checks and a direct current-user guard invocation passed. No installed application was launched, quit or used as a fixture.

Previous review follow-up:

The review follow-up passed 381 OnetimePad tests and 1,826 CompanionKit tests (2,207 total), plus 99 script tests. The full Swift run passed CompanionKit but initially failed four native assertions comparing `/var` with `/private/var`; after normalizing both sides of those fixture path comparisons, all 381 native tests passed on rerun. The final source passed ADR lint (52 records), shell syntax, whitespace diagnostics and 39 changed-document local file links. Native menu tests include an actual archive roundtrip and Services-role reinstallation. No installed application was launched, quit or used as a fixture.

Historical validation before the review follow-up:

The complete Swift suite passed 2,192 tests after the lifecycle, menu and launch-identity changes. After the final companion-panel correction, the native-app target passed a separate rerun of 367 tests. The script suite passed 81 tests. ADR lint and whitespace diagnostics passed.

Transient packaged probes on macOS 27.2 observed foreground launch opening an editor without Settings, background launch opening neither, background activation creating no editor, and reopen opening or deminiaturizing an editor when appropriate. These probes are not a complete acceptance run: a fixed-delay focus assertion trapped once, another run passed, and a later run reported focus-check failures. The snapshots did not establish a stable, complete Cmd-Tab/focus verdict. Do not treat these checks as all passed.

The temporary probes used persistent credentials despite their separate bundle identities. Rebuilt probes subsequently logged restore failures under their own credential services. They were stopped, and their temporary source instrumentation was removed. Further automated checks use injected temporary directories and in-memory credentials. The executable startup check rejects unknown or unbundled identities. Repository runtime-testing instructions require temporary state and in-memory credentials for automated probes.

The user confirmed that OnetimePad Local's stored content was erased during testing. The responsible testing action and mechanism remain unresolved, including whether the Keychain prompts were related. Its sandboxed storage could not be inspected. The testing safeguards above do not establish the cause or demonstrate that the underlying data-loss problem is fixed.

No macOS 13 execution, full replacement hardware matrix, or stable cross-Space focus run was performed. The source still targets macOS 13. The [current manual procedure](verification-procedures/spaces-and-cmd-tab.md#current-launch-and-activation-checks-adr-0059) records the remaining checks.
