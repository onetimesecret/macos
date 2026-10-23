---
documentation_status: needs-review
---

# ADR-0059: AppKit owns application window presentation

- **Status:** accepted
- **Date:** 2026-10-22
- **Supersedes in part:** [ADR-0033](0033-separate-the-primary-editor-from-the-ambient-panel.md), only its unconditional editor selection on application activation, Cmd-Tab and reopen, and its activation-based launch classification. The separate window roles and presentation ownership remain.

## Context

ADR-0033 states: "A launch the person performs, a Dock click, a reopen and ⌘Tab select the editor window, opening it when it is closed". Selecting the editor on every activation also interrupts a return to Settings or another ordinary window. Activation does not identify a request to create an editor.

The application used a SwiftUI Settings scene as a lifecycle placeholder while AppKit created its real windows. The placeholder redirected window attachment into opening another Settings window. A startup presentation could therefore become a Settings command even though the person requested no settings. A second presentation system made the activation policy harder to reason about.

Apple describes [applicationOpenUntitledFile](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationopenuntitledfile(_:)) as asking the delegate to open an untitled file. That event supplies an explicit initial-open route; elapsed time since process startup does not.

## Decision

AppKit owns the application lifecycle, main menu, status item and window presentation. The application declares no placeholder SwiftUI scene. SwiftUI continues to render content inside AppKit windows.

- An initial foreground untitled-open event selects the editor, with the existing launch anchor on today. An event received before model startup waits for startup to finish. An explicit nondefault launch notification suppresses the initial untitled request; later untitled callbacks use the reopen route. Finder file opens and explicit reopens retain their own intent. A queued reopen never becomes a launch-anchor request.
- A background launch starts the configured ambient presentation. Ordinary activation creates no editor and does not change the selected presentation or anchor.
- Cmd-Tab leaves focus and window ordering to AppKit, including a return to Settings, About, Send Feedback or a minimized editor.
- A reopen with a visible ordinary window delegates ordering to AppKit. If only a companion panel remains, the application orders it directly and suppresses the native untitled fallback. With no visible ordinary window, reopen opens or deminiaturizes the editor, preserving the current page and scroll position. The ambient panel does not count as an ordinary window for this decision.
- Explicit Settings commands open the single AppKit Settings window. View creation, window attachment and key-window notifications do not open Settings.
- Explicit presentation commands, hotkey summons, Finder file opens and modal returns retain their own routes. A deferred explicit editor command may finish on activation; activation alone is not such a command.

## Consequences

The main menu is built with AppKit. Its app-specific actions retain keymap equivalents and model-based validation; native editing actions use the responder chain. Services, the Window menu and Help are registered with NSApplication.

Returning to an application with all ordinary windows closed may show no editor. The Dock reopen and Open in Window command remain ways to request one. Returning from the ambient presentation no longer implicitly selects the editor.

There is no launch timer and no dependency on the macOS 15 SwiftUI launch-suppression modifier. Older deployment targets still require their own platform execution checks; building with a deployment target is not an execution result.

## Eject triggers

Revisit this decision if a supported macOS release fails to deliver initial-open or reopen events as required, native focus restoration consistently selects the wrong ordinary window, or a future document-scene architecture can replace the AppKit window controllers as a complete presentation owner.
