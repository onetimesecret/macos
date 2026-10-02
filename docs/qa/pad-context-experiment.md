# Pad context experiment: native verification

This runbook exercises the opt-in implementation attempt of the
[reviewed mockup](../mockups/multiple-pads/one-pad-picker-design.md).
It is a verification procedure, not a record that these checks passed.
Record the exact OS/build, application commit, signing lane, and sandbox status
with each manual run. The browser prototype cannot establish these outcomes.

## Isolated setup

Use a debug bundle and disposable sample notes and folders. Do not point a test
runner at installed application state. Begin with the experiment disabled;
record the existing slot shortcuts and opened files before enabling it.

## Pads and editor ownership

1. Enable the multiple-pad experiment. Confirm existing notes appear in Scratch.
2. Create two named pads. Switch to an empty pad without typing; verify it does
   not silently create a checkpoint or show another pad's ink.
3. Write distinct sample text in each pad. Switch via picker and Command digits,
   with both the ordinary editor and ambient panel. Confirm the same active pad
   appears on both surfaces and there is still one live editor owner.
4. Restart the debug bundle. Confirm pad names, ownership, and writing survive.
   Repeat after reordering and closing slots so numeric handles cannot accidentally
   masquerade as stable identities.
5. Disable the experiment. Verify legacy navigation and shortcuts return and all
   notes remain reachable. Re-enable and verify the same pad memberships.
6. Exercise the existing page-expiry test seams with inactive pads. Confirm
   expiration follows existing page rules and navigation does not revive content.

## Folder bindings and file context

1. Add two directories to one named pad through the explicit chooser. Confirm
   Scratch cannot bind a folder and already-owned roots cannot bind to another pad.
2. Add a nested directory to a different pad. Open a deliberately supplied file
   beneath each root and check the most-specific matching root selects the pad.
   A similarly named sibling directory must not match by string prefix alone.
3. Cancel the chooser, remove an association, and restart. Confirm each operation
   has only its named effect; no sample directory or file is created or scanned.
4. Open an unrelated file, then switch pads. Check file ownership and dirty/save/
   close behavior, including a pending close confirmation across a pad switch.
5. Try missing, renamed, inaccessible, symlinked, and case-varied paths. Record
   the actual matching behavior and any unsupported case; do not infer permission
   or document provenance from a path association.

## App associations

1. Associate a running ordinary application with one pad, then with a second.
   Check add/remove controls are attached to the correct pad.
2. With app associations disabled, leave and return from that app. Confirm no
   app-based pad change. Enable them and exercise the recent-pad tie-breaker.
3. Explicitly supply a matching folder/file path while an app hint is pending.
   Check that folder context wins and does not redirect a pending paste or dirty
   file confirmation.
4. Click each header icon. Check the named running application becomes active;
   quit it and retry to check unavailable-app handling. Two windows belonging to
   that application must not be described as distinct project context.
5. Inspect the implementation's activation path and instrument general-pasteboard
   content reads/writes if available. Activation, hover, pad selection, shortcut
   hints, sorting, and association edits must not acquire clipboard content.
   A source audit alone is not runtime clipboard/privacy validation.

## Picker and timeline

1. Hover/focus a pad cell: highlight includes its folder rows and add action.
   Folder labels remain inert; only add and remove change bindings.
2. Toggle full paths and app associations independently in the menu footer.
   Confirm the closed header stays compact and shows a tally rather than paths.
3. Hold Command to reveal assignments, release it, and move focus to another
   app. Check hints clear and Command-0 always selects Scratch while the
   experiment is enabled. Test user keymap overrides and the disabled mode.
4. Change overall day direction, then change checkpoints within just one day.
   Check the rail and paper agree while another day's order stays unchanged.
   Switch pads and restart to check preference scoping.
5. Verify Timeline stays above Files as files are opened and closed, and test
   narrow window layout, VoiceOver labels, keyboard reachability, and menu closing.

## Persistence failures and release limits

Using injected disposable preferences, present an invalid catalog and confirm
it is not overwritten with a new empty catalog. Test duplicate owners and stale
UUID mappings explicitly. The experiment's context metadata storage is distinct
from note ciphertext; record its actual contents and limitations.

Clipboard compatibility claims require the independent release matrix in
[ADR-0037](../adr/0037-explicit-clipboard-operations.md). No broad macOS release
promise follows from a successful local build or this runbook.
