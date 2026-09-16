---
name: contrast-measurements
description: Measured WCAG ratios of the shell's inks under aqua and darkAqua (2026-09-15); the system secondary label fails 4.5:1 in light, the ramp and ember text tokens pass with margin
metadata:
  type: project
---

The system `secondaryLabelColor` reads 3.95:1 on white under aqua (5.89:1 under darkAqua). Every quiet word in the shell wears it, so the record's 4.5:1 row is not met by `.secondary` text in light, and the findings claim that Apple's labels "pass by contract" is false. `tertiaryLabelColor` reads 1.88:1 light and 2.26:1 dark. The raw system hues on the fence wash (quaternaryLabelColor over the page) read 2.8 to 3.4:1 light.

**Why:** ThemeContrastTests (shell/Tests/CompanionKitTests) measures colours resolved under a named NSAppearance, compositing translucent inks and washes. The ember text token (#B0361A light, #F5865F dark) and the four fence inks in Theme.swift were picked from those measurements with margin, not from the hex the record names. The secondary label was deliberately left unasserted because replacing it is a whole shell decision.

**How to apply:** when a work item asks for 4.5:1 on secondary text, say up front that `.secondary` itself misses in light and needs a maintainer call, rather than asserting it and watching it fail. Under a bare xctest runner `windowBackgroundColor` resolves to pure white in light, so ratios there are the optimistic case.
