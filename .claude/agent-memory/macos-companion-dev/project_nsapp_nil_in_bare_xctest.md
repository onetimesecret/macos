---
name: nsapp-nil-in-bare-xctest
description: NSApp is nil in a filtered xctest run until some AppKit view forces NSApplication.shared; unwrapping it traps and the trap path hangs the run silently
metadata:
  type: project
---

A test that touches `NSApp` passes in the full suite and hangs when run
alone with `--filter`: the full run has already created
`NSApplication.shared` through some NSTextView or NSHostingView test,
the filtered run has not, and `NSApp.modalWindow` on the nil IUO traps
inside `_assertionFailure` in a way that never exits (found 2026-09-05
while adding `ModalSession.isRunning`; `sample <pid>` showed the trap).

**Why:** the full suite is what CI runs, so the fault is invisible until
somebody loops one suite; the symptom is a `swift test` that prints
"Build complete!" and nothing else for ten minutes.

**How to apply:** read `NSApp?.x` in shared code and let nil mean the
closed answer; when a filtered run prints nothing after the build,
`pgrep -f xctest` and `sample` it rather than waiting. `NSApp.modalWindow`
was measured (scratch script) to be the NSOpenPanel for the whole of its
`runModal` even though the panel is drawn out of process, and main actor
Tasks do run during a modal session.
