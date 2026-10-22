# Application lifecycle follow-up

Date: 2026-10-22. Implementation: [ADR-0059](../adr/0059-appkit-owns-window-presentation.md).

## Review disposition

| Finding | Materiality | Disposition | Evidence and verification |
| --- | --- | --- | --- |
| L1: Settings attachment opens another Settings window | Material: unsolicited startup UI | Addressed | Removed the SwiftUI application scene and redirect. Native menu installation and startup regressions assert that no Settings controller is created. |
| L2: Every application activation selects the editor | Material: interrupts returns to Settings and other windows | Addressed in implementation | Ordinary activation returns no presentation action. Reopen delegates visible ordinary windows and companion panels to AppKit. Router and lifecycle tests cover these decisions. |
| L3: Launch is classified by a two-second timer | Material: timing-dependent presentation | Addressed | Native untitled-open events select the initial editor; background activation does not. The launch timer and its classifier were removed. |
| L4: Unknown or unbundled app identity can resolve a production fallback | Material: unintended store selection during testing | Addressed at executable startup | The entry point rejects identities outside the three packaged app identifiers before constructing its delegate. Unit tests cover absent, unknown, prefix-like and recognized identifiers. This does not identify every possible misuse of a known development identity. |
| L5: The test lane can rebuild a live executable from its build directory | Material: disrupts ongoing development sessions | Addressed for the supported test script | The script checks for matching processes and stops before building. Script tests cover a live process, no match, inspection failure and regexp characters in a path. Direct invocations of build tools remain outside this script's check. |
| D1: ADR and specifications describe superseded activation behavior | Material: contradictory guidance | Addressed | ADR-0059 partially supersedes ADR-0033; current editor/background specifications and the current QA matrix describe the replacement. ADR lint and changed-document local-link checks pass. |
| D2: Old hardware results could be mistaken for verification of the replacement | Material: overstates validation | Addressed | The QA procedure identifies the replaced route expectations as historical and leaves replacement hardware checks unchecked. |

## Validation scope

The complete Swift suite passed 2,192 tests after the lifecycle, menu and launch-identity changes. After the final companion-panel correction, the native-app target passed a separate rerun of 367 tests. The script suite passed 81 tests. ADR lint and whitespace diagnostics passed.

Transient packaged probes on macOS 27.2 observed foreground launch opening an editor without Settings, background launch opening neither, background activation creating no editor, and reopen opening or deminiaturizing an editor when appropriate. These probes are not a complete acceptance run: a fixed-delay focus assertion trapped once, another run passed, and a later run reported focus-check failures. The snapshots did not establish a stable, complete Cmd-Tab/focus verdict. Do not treat these checks as all passed.

The temporary probes used persistent credentials despite their separate bundle identities. Rebuilt probes subsequently logged restore failures under their own credential services. They were stopped, and their temporary source instrumentation was removed. Further automated checks use injected temporary directories and in-memory credentials. The executable startup check rejects unknown or unbundled identities. Repository runtime-testing instructions require temporary state and in-memory credentials for automated probes.

A reported content change in another development instance remains undiagnosed. The available evidence does not establish that the instance's stored content was erased, or that the credential prompts caused that change. Its sandboxed storage could not be inspected. This is an unresolved observation, not a verified consequence of this patch.

No macOS 13 execution, full replacement hardware matrix, or stable cross-Space focus run was performed. The source still targets macOS 13. The [current manual procedure](verification-procedures/spaces-and-cmd-tab.md#current-launch-and-activation-checks-adr-0059) records the remaining checks.
