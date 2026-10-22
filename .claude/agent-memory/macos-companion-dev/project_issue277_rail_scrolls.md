---
name: issue277-rail-scrolls
description: Issue #277 (PR 303, app 0.40.4): the stream navigator column scrolls inside a SwiftUI ScrollView; scrollTo on offset placed rows did nothing in a hosted test, so RailReveal drives the NSScrollView; visibleRect lies in an unordered window
metadata:
  type: project
---

PR 303 (2026-10-21, `fix/277-dense-rail-scrolls`) removed `StreamNavigator.layout`'s
backward foot cap. `Layout.contentHeight` is the drawing's height, the sliver box runs
from `Placed.rowTop` (`floor(drawnTop) - 1`) to `Placed.rowBottom`
(`ceil(drawnTop + rowHeight) - 1`), so neighbouring boxes may share a point or two,
which is harmless; `seatsDropTarget` is gone, and `StreamNavigatorView` draws
inside `ScrollView(.vertical, showsIndicators: true)` sized to `contentHeight`.

**Why:** the maintainer's decision on #277: the rail scrolls like the Finder sidebar,
rows are never compressed or folded.

**How to apply:**
- `ScrollViewReader.scrollTo(id)` on rows positioned with `.offset(y:)` did not move
  the clip at all in the hosted `TabDropTests` run (unordered window, main queue
  drained). `RailReveal` (a representable behind the drawing, `isFlipped`) asks its
  `enclosingScrollView` for `StreamNavigator.revealOffset` one hop later. It fires once
  per active node id, so a layout change never snaps the reader's own scroll back, and
  records the id only once the hop finds the clip with a height and the drawing at
  least as tall. Until then it watches both views' `frameDidChangeNotification` and
  asks again on a change, or on coming into a window; leaving the window drops the watch.
  A retry that waits for `updateNSView` waits until the next selection, since at mount
  the request does not change.
- `NSView.visibleRect` is garbage in a never ordered window; a row is clipped iff
  `clip.bounds` does not intersect `clip.convert(target.bounds, from: target)` for the
  nearest `NSClipView` (`TabDropTests.isClipped`). SwiftUI's ScrollView hierarchy on
  macOS is HostingScrollView > HostingClipView (clips) > DocumentView (flipped), and
  representables inside the content do sit under the clip view.
- The wheel relay is installed only while `layout.contentHeight <= column height`;
  a dense rail takes the wheel itself (D-38 dated note). The relay must stay inside the
  ScrollView's content so the hit view is its ancestor.
- PR 286 (`fix/269-review-follow-ups`) renames the same hunks (`rowClearance`,
  `liftGaps`); the second to merge conflicts there.

Related: [[issue267-timeline-node-drops]], [[project_issue79_time_rail]].
