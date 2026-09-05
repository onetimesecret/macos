# docs/research/2026-0904-how-do-nerd-fonts-work.md

---

Nerd Fonts are **patched developer fonts**: they take a normal monospaced font (for example JetBrains Mono) and add thousands of icon glyphs from sets such as Font Awesome, Devicons, Octicons, Material Design Icons, and Powerline. A terminal/editor renders an icon when it sees the corresponding character code point and the active font contains its glyph. [^3]

They are mainly for prompts, statuslines, file explorers, and editor UIs—not a new text encoding.

## Do they use Unicode variation selectors?

**No, not for their icons.** Nerd Fonts generally assign icons to fixed Unicode code points, primarily in Unicode’s **Private Use Areas (PUA)**, such as BMP PUA `U+E000–U+F8FF` and supplementary PUA ranges. [^5f8a6d#103]

A variation selector is a _following_ character that requests a registered rendering variant of a preceding Unicode character—for example text versus emoji presentation. Only registered sequences have standardized meaning. [^2] Nerd Font icons are instead typically single PUA characters such as `U+E0B0`.

That means these differ fundamentally:

```text
Nerd Font icon:       U+E0B0                 # one private-use character
Emoji/text variation: U+2764 U+FE0F          # base character + selector
```

PUA assignments have no Unicode-defined universal meaning. The same PUA character can render differently—or as a missing-glyph box—in a non-Nerd Font. So Nerd Fonts establish a **project convention**, not a Unicode standard.

## Conventions they follow

| Area                | Convention                                                                                                                                                                                                                                      |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Character mapping   | A published Nerd Fonts mapping assigns icon sets to particular code-point ranges. Some ordinary Unicode symbols are also used where appropriate (e.g. box drawing, Braille, IEC power symbols). [^5f8a6d#23-25]                                 |
| Collision avoidance | Imported icon fonts may be relocated from their original mappings so multiple icon sets can coexist. [^5f8a6d#105-133]                                                                                                                          |
| PUA use             | Most custom icons live in PUA blocks. For example, Powerline symbols use `U+E0A0–U+E0A2` and `U+E0B0–U+E0B3`; Devicons use `U+E700–U+E958`; Material Design Icons use supplementary PUA `U+F0001–U+F1AF0`. [^5f8a6d#33][^5f8a6d#48][^5f8a6d#63] |
| Font technology     | The patched file is an ordinary OpenType font (`.ttf`/`.otf`): its `cmap` table maps character code points to glyphs; the terminal/editor selects glyphs using usual font fallback and shaping behavior.                                        |
| Width               | The project aims for terminal-friendly, typically single-cell icon glyphs. Exact behavior still depends on the terminal, font metrics, and Unicode-width handling.                                                                              |
| Naming/API          | Tools commonly expose icons with names like `nf-fa-*`, `nf-md-*`, and `nf-cod-*`, plus aliases. The names are a convenience layer; at runtime the emitted PUA code point is what matters.                                                       |
| Compatibility       | The mappings are versioned project data. Pin the Nerd Fonts version or use its supplied symbols font if reproducible rendering matters. A PUA code point should not be treated as durable interchange text.                                     |

## What standards are involved?

- **Unicode** supplies scalar values, PUA ranges, general character properties, and standard variation-sequence rules—but does **not** standardize Nerd Font icon meanings.
- **OpenType** supplies the actual font-file mechanism: codepoint-to-glyph mapping, metrics, and optional substitution/positioning.
- **Terminal conventions** determine whether a glyph occupies one or two cells and whether fallback fonts are used. This remains less consistent than ordinary text rendering.

Practical rule: treat Nerd Font symbols as a **font-dependent icon API encoded in PUA**, not as portable Unicode text.

**References**

[^1]: [Glyph Sets and Code Points · ryanoasis/nerd-fonts Wiki · GitHub](https://github.com/ryanoasis/nerd-fonts/wiki/Glyph-Sets-and-Code-Points) (50%)

[^2]: [Unicode – The World Standard for Text and Emoji](https://www.unicode.org/Public/UNIDATA/StandardizedVariants.txt) (26%)

[^3]: [Nerd Fonts - Iconic font aggregator, glyphs/icons collection, & fonts ...](https://www.nerdfonts.com/) (24%)

## How would a Nerd Font use Variation Selectors?

A Nerd Font _could_ use variation selectors, but it would be a different encoding scheme from the one it normally uses.

A variation sequence is:

```text
base character + variation selector
```

For example:

```text
U+E0B0 U+FE0E
```

A font can declare, via an OpenType `cmap` **format 14** table, that this pair selects a particular glyph. It could use that to distinguish icon styles or variants:

```text
U+E700         → default Devicon glyph
U+E700 U+FE0E  → monochrome/text-style glyph
U+E700 U+FE0F  → colored/emoji-style glyph
U+E700 U+E0100 → alternate glyph 1
```

`U+FE0E` and `U+FE0F` are the standard text/emoji variation selectors; `U+E0100–U+E01EF` are additional variation selectors. But for Nerd Font PUA icons, none of those sequences would have a Unicode-defined meaning. The font author and application would have to agree on what they mean.

### What happens in rendering

A capable renderer:

1. Reads the base code point, e.g. `U+E700`.
2. Sees the following selector.
3. Checks whether the selected font declares that exact sequence in `cmap` format 14.
4. Uses the variant glyph if declared; otherwise behavior varies—commonly it renders the base glyph and suppresses the selector.

This is not primarily an OpenType `GSUB` ligature feature. Variation sequences are selected through Unicode-aware character-to-glyph mapping. `GSUB` could offer alternates too, but that normally requires enabling a font feature and does not give the sequence a portable textual representation.

### Why Nerd Fonts mostly do not do this

| Issue                               | Consequence                                                                                                                                         |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal support                    | Many terminals and TUI libraries have incomplete or inconsistent variation-sequence handling, especially for PUA bases.                             |
| Cell-width handling                 | The selector must be zero-width; buggy width calculation can cause alignment problems in terminal UIs.                                              |
| Copy/paste and storage              | A visually identical icon could be one code point or a two-code-point sequence. Tools that truncate, sanitize, or compare strings may mishandle it. |
| Font fallback                       | The renderer must keep the base and selector together and find a font supporting the exact sequence. Fallback behavior is often inconsistent.       |
| Little pressure on code-point space | Nerd Fonts already have large PUA ranges available, so assigning a separate code point per icon is simpler and more robust.                         |
| No interoperable semantics          | Unicode does not register Nerd Font variation sequences, so a sequence means nothing outside the project’s convention.                              |

### A reasonable hypothetical design

Use a stable PUA base for the semantic icon, then selectors only for true presentation variants:

```text
U+E900                 “git branch” — default Nerd Font style
U+E900 U+FE0E          text/monochrome variant
U+E900 U+FE0F          emoji/color variant
U+E900 U+E0100         filled variant
U+E900 U+E0101         outline variant
```

That would reduce duplicate base assignments for variants. But it would require:

- documented sequence mappings;
- `cmap` format 14 support in the fonts;
- renderer/terminal support;
- a fallback rule, usually “render the default base glyph if the variant is unavailable.”

For current terminal-oriented Nerd Font use, one PUA code point per icon remains the safer convention.


## Other approaches


### invisible variation selectors after each character

Caveats: 
- These are not valid standardized variants of a. You are repurposing default-ignorable format characters as an application-private encoding.
- Editors may reveal them, normalization/sanitization pipelines may remove them, and comparisons/searches/cursors can behave unexpectedly.
- They are poor for auditing: an ordinary reader cannot tell the source category.
- Do not use FE0E/FE0F; those are strongly associated with text/emoji presentation and are more likely to interact with existing behavior.
- Store provenance separately as canonical data if it matters; derive this invisible form only for rendering/transport.


### add cmap format 14 entries

If you control the font, the cleaner sophisticated version is: use the same selector mapping but add cmap format 14 entries that render a very subtle, zero-advance visual cue—for example a faint underline color or tiny corner mark. But that is a custom patched font/application, not something existing Nerd Fonts can reliably do.

This would work if the modified Nerd Font uses a normal OpenType mechanism that the renderer already supports. You should not need a custom *application renderer*. But you do need the host text stack—terminal, editor, browser, OS—to support the particular mechanism.

### OpenType ligatures

For this purpose, use **OpenType ligatures**, not variation selectors.

```text
a + U+E000  →  glyph “a marked human”
a + U+E001  →  glyph “a marked model”
a + U+E002  →  glyph “a marked mixed”
a + U+E003  →  glyph “a marked unknown”
```

Where `U+E000`–`U+E003` are private-use marker characters. Your modified Nerd Font would contain:

- ordinary glyphs for `a`, `b`, …;
- PUA marker glyphs (normally zero-width/invisible);
- a `GSUB` `liga` rule replacing each pair with a **single, same-width composite glyph**—e.g. a subtly colored, underlined, or corner-marked `a`.

The renderer sees ordinary Unicode text plus a font with standard ligatures enabled. The ligature collapses `a + marker` to one glyph, so terminal columns remain aligned.

#### Why this is more practical than variation selectors

Variation-selector mappings use `cmap` format 14, which is the proper OpenType table for Unicode variation sequences. [^1] But support in terminal-oriented stacks is less predictable, especially for arbitrary variation sequences on Latin letters and PUA-oriented custom conventions.

`GSUB` ligatures are extremely widely implemented because programming fonts routinely use them for sequences such as:

```text
->   =>   !=   ===
```

The font handles the rendering; the surrounding program only needs to enable ligatures. Many terminals still offer a “disable ligatures” setting, so it is not universal.

### Encoding proposal

| Provenance | Stored after `a` | Font output |
|---|---|---|
| Unknown | `a` + `U+E003` | ordinary `a`, or an `a` with a neutral cue |
| Human | `a` + `U+E000` | `a` with human cue |
| Model | `a` + `U+E001` | `a` with model cue |
| Mixed | `a` + `U+E002` | `a` with mixed cue |

You can use a tiny but legible cue: an underline pattern, dot in a corner, or a colour only if the environment supports color-font formats. Shape-based cues are safer.

### Important constraint

A font alone cannot make the distinction **both invisible and recoverable to an unmodified text system**. The raw string contains the PUA marker, so copy/paste, searching, cursor positions, and character counts still see an extra code point. The font can make it visually one-cell, but cannot change the underlying text model.

Also, Nerd Fonts itself is incidental: it is a collection/patcher of icon glyphs, and can patch custom glyphs into a font. [^2] You would be making a custom OpenType font convention layered on a Nerd Font, not using an existing Nerd Font feature.

**References**

[^1]: [cmap — Character to Glyph Index Mapping Table](https://learn.microsoft.com/en-us/typography/opentype/spec/cmap) (52%)
[^2]: [Nerd Fonts - Iconic font aggregator, glyphs/icons collection ...](https://www.nerdfonts.com/) (48%)

## More About Copy & Pastability

The marker is **real text data**, not external metadata:

```text
a<U+E000>   # human
a<U+E001>   # model
a<U+E002>   # mixed
a<U+E003>   # unknown
```

A modified font uses ligatures to render each pair as one visually ordinary—or subtly marked—`a`. Copy/paste normally transfers the underlying two-code-point sequence, so the provenance travels with it. Pasting into the same modified-font environment restores the rendering automatically.

The constraint is not that this fails at copy/paste; it is that the copied text has extra code points. That is intentional in your design.

| Property | Result |
|---|---|
| Copy/paste between compatible apps | Provenance survives |
| Paste into an app without the custom font | It may show a replacement box, blank, or other marker behavior |
| Search / equality | Must decide whether markers count; e.g. `a<human>` is not byte-identical to plain `a` |
| Cursor/backspace | Apps may move/delete the marker separately unless they respect the ligature cluster |
| Text-processing/sanitizing systems | May preserve PUA characters, but some can strip or replace them |

For robustness, use **four PUA marker code points**, rather than variation selectors:

- They are ordinary, non-ambiguous code points in your application’s encoding.
- They survive UTF-8/UTF-16 transport as normal Unicode scalar values.
- You can define fallback behavior, such as rendering them visibly as `[H]`, `[A]`, `[X]`, `[?]` when the custom font is absent.
- The custom font can use `GSUB` ligatures to hide the marker and produce a one-cell composite glyph.

So the model is: **steganographic-but-decodable inline provenance**, with a font as its pleasant presentation layer. It is reasonable, provided every consumer that needs semantic text comparison/searching knows to either preserve, inspect, or deliberately strip the markers.
