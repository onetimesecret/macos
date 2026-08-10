# docs/spec/icon/about-longshadow.md

---
longshadow is now a generated matrix instead of one hardcoded look.

What's there

scripts/render-icon.swift gained two axes that cross into 56 styles named longshadow-<angle>-<treatment>:

- angles (se sw ne nw s e low steep): se is the classic 45 down-right; low (22.5) and steep (67.5) probe off the diagonal; the rest walk the compass.
- treatments (solid deep fade stub dusk beam stencil): solid is the original, deep drives the ink far darker, fade ramps to nothing, stub cuts the run to 0.42 tile heights so the mark reads raised rather than flattened, dusk fades toward a sky blue rather than black, beam inverts the whole thing so the mark leaks light onto a darkened tile, stencil abandons the extrusion entirely and casts one translated copy of the mark cut through a plate.

stencil is the odd one out and reads differently from the rest. A mark that encloses an area gets a plate (for the maruhi, a disc on the ring's outer circle, measured off a rendering rather than guessed, since the enclosed glyph comes from whatever CJK face the system font falls back to) and the mark is knocked out of it, in the shadow and in the motif alike. An open mark has no plate and casts its own outline, which still works. It is the only treatment whose eight angles differ from one another on the maruhi; see the first surprise below for why the other six cannot. It is also a large-size look: at 16px it collapses to a light disc with a smudge, meaningfully worse than solid, which at least keeps the ring.

New study sheet, laid out as a real matrix (row per treatment, column per angle):

scripts/build-icons.sh --mark logo   --shadows 8c3b1c
scripts/build-icons.sh --mark maruhi --shadows 8c3b1c

Both are rendered in dist/icons/shadows-{logo,maruhi}-8c3b1c.png. Any cell is buildable as a real icon: scripts/build-icons.sh --mark logo Trial longshadow-low-dusk 8c3b1c.

The fade is done by building the trail opaque inside a transparency layer and multiplying the layer's alpha by a ramp. Drawing each of the 240 copies faintly does not work: overlapping translucent copies pile up to opaque within the first tenth of the run.

longshadow still exists and still means longshadow-se-solid, so build-icons.sh with no arguments builds the same standard icon. It is not bit-identical: 468 of 262144 pixels changed at 512px, max channel delta 33, all of it on the shadow's own edges. See the surprise below.

---
Origin story

The long shadow is a June 2013 artifact with much older parents. iOS 7 stripped skeuomorphism out of icon design, and the flat result had no depth cues at all: no bevel, no gradient, no texture, no drop shadow. The long shadow was the compromise designers reached within weeks, on Dribbble, almost entirely as a peer-to-peer convention rather than a published spec. It adds depth using nothing but flat geometry and one extra flat color, so it stays inside the flat rules while breaking the flatness.

The convention that settled: 45 degrees down and to the right, running roughly 2.5 times the icon's diagonal so it always exits the tile, terminating hard, and colored as a flat step darker rather than a gradient. Gradient falloff was considered slightly illegitimate at the time, a way of sneaking the old depth back in.

Its ancestry is poster design. Constructivist and WPA-era posters, Cassandre, and mid-century ski and travel lithographs all use a raking sun to throw a huge graphic shadow, because a shadow is a second shape you get for free in a printing process where every additional color costs money. Same economics, different century.

It died fast. Google's Material Design in 2014 explicitly rejected it for physically modeled elevation shadows, and by 2015 the long shadow read as "dated 2013." It survives in icon work because it does one thing that nothing cheaper does: it separates figure from ground at large sizes with zero rendering cost.

Surprise, the first: the look was decided by the implementation, not by a designer. The 2013 CSS technique was a Sass loop emitting box-shadow: 1px 1px, 2px 2px, 3px 3px, … for a couple hundred stacked offsets. Hard edge, flat color, exact 45 degrees, and unbounded length are all just what that loop can produce. drawLongShadow in this repo is the same loop in Swift, 240 iterations of the same offset trick. The aesthetic is a rendering constraint that outlived its renderer.

---
Mental models for shadow direction

1. The light-from-above prior. Human vision assumes light comes from above, with a documented bias slightly toward the left. A downward shadow lets the mark read as convex, sitting on the tile. An upward shadow cannot be reconciled with that prior, so the brain flips the other variable instead: it reads the mark as concave, punched into the tile. This is the crater illusion. ne and nw are therefore not "the same icon lit differently," they are a different object. Look at nw deep on either sheet; the mark sinks.
2. Angle is time of day, length is sun altitude. Azimuth sets direction, altitude sets length. A long shadow means a low sun, so low at 22.5 degrees reads as late afternoon and slightly nostalgic, while steep reads as closer to noon and more institutional. Note that s at full length is physically impossible outdoors, since the sun cannot be both overhead and low. It reads as a stage light rather than a sun, which is why it feels the most synthetic of the eight.
3. Reading order. In a left-to-right script, se puts the shadow after the mark: the mark leads, the shadow trails, and the whole thing reads as consequence, as something that has already happened. sw puts the shadow first, so the mark emerges from it. Geometrically equivalent, semantically reversed. This is most of why se is the default, and it is a cultural fact rather than an optical one.
4. Where the viewer is standing. A shadow implies a lamp, and a lamp implies a room. Down-and-right means the light is over your left shoulder, which is exactly where a right-handed person puts a desk lamp so they do not shadow their own writing. se is desk lighting. For a notes app that is a better argument than convention.
5. Shadow color is the ambient, not the absence of light. A shadow is lit by everything except the primary source. Outdoors shadows go blue rather than black. dusk is that idea, and on the sheet it looks more physical than deep even though deep has far more contrast. Blackening a shade is the shortcut, not the truth.
6. Edge softness is source size; opacity falloff is neither. A hard edge means a small or distant source, a soft edge means a large or near one. Real shadows soften at their edges with distance; they do not lose opacity along their length while keeping razor edges. fade is a graphic convenience that no lighting arrangement on Earth produces. It looks fine anyway, which is its own lesson.

---
Three surprises, all from the render

The maruhi's shadow carries no information, and the ring is not why. Put the two sheets side by side. All eight maruhi columns cast the same capsule, merely rotated, and the 秘 strokes inside contribute nothing. The obvious reading is that ㊙ is enclosed, so its silhouette is a disc and a disc casts a capsule at every angle. That reading is wrong, or at least it names the wrong culprit. What discards the strokes is the extrusion. A long shadow is the union of copies one step apart, and a union closes any hole narrower than the run; every gap in 秘 is narrower than the run. Any closed region would be flattened the same way, and so would the interior of an open mark if it had one.

The distinction matters because it decides what the criterion applies to. "The long shadow rewards open marks and is wasted on closed ones" is true of the extruded construction, not of shadows, so it is an argument about the construction rather than an argument for the logo over the maruhi. Change the construction and the maruhi keeps its strokes: see the stencil treatment, which casts one translated copy instead of sweeping, because a thin plate held above a surface casts its outline with every hole intact. Extrusion models a tall prism standing on the tile. Both are real objects; only one of them throws away the inside of the mark.

The old shadow never reached the corner. The original loop moved tile/160 on each axis for 120 steps, which is 0.75 tile heights. The mark's trailing edge needs about 0.82 to clear the corner. A faint un-shadowed crescent sat in the lower right of every icon built since the style was added. The pixel diff above is that crescent plus some anti-aliasing seams from the denser stepping; it is invisible below 512px, which is why it survived. The new code derives the run from the tile diagonal, so it clears at any angle.
