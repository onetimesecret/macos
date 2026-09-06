---
name: dogfood4-time-indicators
description: Dogfood phase 4 items 3 and 6 (2026-09-05): only the full width page edge gauge in PageStatusStack is gone, the per tab gauge was removed for an evening and restored by maintainer decision; the header countdown yields only in day mode because the day gutter exists only there; the login item launch posture and the post modal re-key are open decisions for the maintainer; parallel lanes share one scratchpad dir
metadata:
  type: project
---

On 2026-09-05 (dogfood phase 4 item 3, issue #156) both bottom edge gauges
came out: the 3 pt GaugeBar under each strip tab and the 4 pt GaugeBar
PageStatusStack drew across the page's full width. The maintainer then ruled
that only the full width bar was the scroll bar lookalike, so the per tab
gauge was restored exactly as it had been (two row SheetTab, EmptyRule on an
empty slot, FileTab's gauge seat holding the UnsavedDot) and the page edge
gauge stayed removed. GaugeBar draws under each tab and on TimeRailView; the
prose everywhere says "page edge gauge removed, per tab gauge kept". The
header CountdownButton was kept in strip mode and removed only in day mode
(item 6), narrowing the item as written.

**Why:** a short bar framed by its tab is not what anyone takes for a
horizontal scroll bar; a thin bar running the width of the text surface's
bottom edge is. The "duplicate" countdown item 6 cited lives in
DayScrollView's day gutter, and PageContentView mounts DayScrollView only
while `showsTimeUnits` is on, which is off by default and exclusive with the
strip. `BackdropRootView.showsHeaderCountdown` holds the rule.

**How to apply:** do not remove the per tab gauge again on the scroll bar
argument; it has been made and rejected. Any future indicator must not be a
thin full width bar along the bottom edge (constraint recorded in
ABERRATIONS, the SheetTab comment, design spec 04's superseded note and issue
#156). When a task says "X is already shown in the gutter", check which mode
mounts the gutter first. Two
phase 4 questions were left for the maintainer rather than fixed: whether a
login item launch should still rest instead of raising, and whether the post
modal re-raise in `modalSessionEnded` should be gated on `NSApp.isActive`.

Also learned on this run: parallel workflow lanes share one scratchpad
directory. Another lane overwrote `commit1.txt` seconds after I committed
from it. Name scratch files with a lane prefix and confirm `head -1` before
`git commit -F`.
