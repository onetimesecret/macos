# 2026-0904-inline-typographic-provenance-for-nerd-fonts.md

# Inline Typographic Provenance for Nerd Fonts

## Status

This document proposes a lightweight convention for distinguishing human-written and AI-written text using Unicode code points embedded directly in the text.

It is intentionally **not** a comprehensive provenance, authentication, or cryptographic attestation system. The encoded character sequence is the metadata. A modified Nerd Font provides the preferred presentation layer.

## 1. Goals

The design should:

- Preserve provenance during ordinary copy and paste.
- Allow provenance to survive when only part of a document is copied.
- Require no sidecar file, manifest, signature, or external service.
- Let existing programs participate without modification.
- Render pleasantly with a supporting Nerd Font.
- Offer two fallback behaviors:
  - **Soft fallback:** unsupported fonts show ordinary text.
  - **Hard fallback:** unsupported fonts show tofu for AI-written text.
- Permit simple, reversible inspection and conversion.
- Avoid conflicts with existing Nerd Font icon code points.

## 2. Non-goals

The design does not attempt to:

- Prove that text was written by a human or an AI.
- Authenticate the person, model, or application making the designation.
- Prevent someone from removing or changing provenance.
- Represent a complete editing history.
- Verify that text assumed human was in fact written by a human.

This is a labeling convention, not a trust system.

## 3. Provenance model

The initial profile defines four states:

| State          | Encoding                            | Meaning                                                                                          |
| -------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------ |
| Assumed human  | Plain Unicode, no selector          | The default. Nothing has marked this text, and readers already treat plain text as human-written |
| Explicit human | `<base> + VS_HUMAN`                 | Positively designated as human-written by the producing tool                                     |
| AI             | `<base> + VS_AI` or PUA counterpart | Explicitly designated as AI-written                                                              |
| Unknown        | `<base> + VS_UNKNOWN`               | The producing tool could not determine the source and says so                                    |

An optional future profile may add states such as `human-edited AI` or `mixed`.

Plain Unicode is assumed human rather than treated as unmarked. This is a deliberate adoption choice. Every existing program already produces plain text, and readers already take plain text to be human-written. Naming that assumption lets existing programs participate without modification. Only tools that emit AI text need to change, which is where the marking obligation belongs.

The assumption is a default, not a claim. Explicit human is the forward-compatibility path: a program that wants to opt in can assert authorship rather than inherit it, and text it produces stays distinguishable from the assumed-human pool if a later profile tightens the default. Unknown exists for tools that handle text of mixed or lost origin, such as an editor receiving a paste, and prefer to say so rather than let it fall into the default.

## 4. Dual encoding

A single supporting font implements two encodings for AI provenance.

### 4.1 Variation-selector encoding

A variation selector follows each marked base character:

```text
<base character> <provenance variation selector>
```

Conceptually:

```text
A + VS_HUMAN   → explicit human A
A + VS_AI      → AI A
A + VS_UNKNOWN → unknown A
```

Variation sequences consist of a base character followed by a variation selector. Unsupported selectors are default-ignorable, giving the desired plain-text fallback.[^1] OpenType represents supported variation sequences with a format 14 `cmap` subtable.[^2]

Example private convention:

| Sequence           | Meaning                   |
| ------------------ | ------------------------- |
| `<base> + U+E0100` | Explicit human            |
| `<base> + U+E0101` | AI                        |
| `<base> + U+E0102` | Unknown                   |
| `<base> + U+E0103` | Human-edited AI, reserved |
| `<base> + U+E0104` | Mixed or other, reserved  |

These assignments are a private protocol between encoders, decoders, and supporting fonts. They are not standardized Unicode variation sequences.

The font maps the sequences to provenance-aware glyphs:

```text
U+0041 U+E0100 → A.human
U+0041 U+E0101 → A.ai
```

Without a supporting font:

```text
U+0041 U+E0101 → ordinary-looking A
```

This is the **soft provenance** representation.

### 4.2 PUA encoding

AI-written characters may instead be replaced by corresponding Private Use Area code points:

```text
U+0041 → U+F0041
```

The exact mapping is defined by a distributed mapping table, not inferred universally from this illustrative arithmetic.

The supporting font maps the private character to the appropriate glyph:

```text
U+F0041 → A.ai
```

Without that font, the character normally appears as tofu or another missing-glyph indicator:

```text
U+F0041 → □
```

This is the **hard provenance** representation. Failure is visible rather than silently degrading to ordinary-looking text.

Unicode provides two supplementary private-use ranges: `U+F0000–U+FFFFD` and `U+100000–U+10FFFD`.[^3] The profile should use these supplementary areas rather than the crowded BMP PUA.

### 4.3 Combined font behavior

Both encodings can resolve to the same glyph:

```text
A + VS_AI ───┐
              ├──→ A.ai
PUA_AI_A ────┘
```

A single font therefore supports:

| Input            | Supporting font             | Unsupported font |
| ---------------- | --------------------------- | ---------------- |
| Plain `A`        | Ordinary `A`, assumed human | Ordinary `A`     |
| `A + VS_HUMAN`   | Explicit-human `A`          | Ordinary `A`     |
| `A + VS_AI`      | AI-designated `A`           | Ordinary `A`     |
| `A + VS_UNKNOWN` | Unknown-designated `A`      | Ordinary `A`     |
| `PUA_AI_A`       | AI-designated `A`           | Tofu             |

The author or application chooses whether AI text uses soft or hard fallback.

## 5. Character coverage

The initial implementation should cover a practical subset rather than attempting to duplicate all of Unicode:

- Basic Latin
- Latin-1 Supplement
- Common punctuation
- Common symbols
- Characters already present in the source font

Variation selectors can mark any supported base character without allocating another encoded character. PUA mode requires one private mapping for every supported base character.

The project must publish a machine-readable mapping, for example:

```json
{
  "version": 1,
  "variation_selectors": {
    "human": "U+E0100",
    "ai": "U+E0101",
    "unknown": "U+E0102",
    "edited": "U+E0103",
    "mixed": "U+E0104"
  },
  "pua": {
    "U+F0041": {
      "base": "U+0041",
      "provenance": "ai"
    },
    "U+F0061": {
      "base": "U+0061",
      "provenance": "ai"
    }
  }
}
```

The mapping version must remain stable. Once a PUA code point has been published, it must not later be assigned to a different base character or provenance state.

## 6. Granularity

Provenance should normally be encoded per character or grapheme cluster.

For simple characters carrying an explicit designation:

```text
H + VS_HUMAN
e + VS_HUMAN
l + VS_HUMAN
l + VS_HUMAN
o + VS_HUMAN
```

For combining sequences, the provenance selector should be placed after the complete grapheme’s ordinary code-point sequence, subject to shaping tests:

```text
<base> <combining marks> <provenance selector>
```

Punctuation should be marked according to its originating span. Whitespace may remain unmarked in the first profile, reducing rendering and text-processing edge cases.

Per-character encoding means that copying a word or fragment also copies its provenance. It avoids document-level envelopes and chunk-boundary rules.

## 7. Presentation

The supporting Nerd Font may provide several visual styles while using the same underlying encoding.

### Identical presentation

Human and AI variants use visually identical outlines:

```text
A.human ≈ A.ai ≈ A
```

Provenance remains machine-readable but is not visually emphasized.

### Subtle presentation

AI glyphs receive a restrained distinction, such as:

- A small notch.
- A dot or corner mark.
- A modified terminal.
- A light underline or overline.
- A stylistic alternate.

### Explicit presentation

AI glyphs are visibly marked throughout the text. This is useful for inspection, editing, and demonstrations but may reduce readability.

All provenance variants should retain the base glyph’s normal metrics:

- Same advance width.
- Same side bearings where practical.
- Same vertical metrics.
- No unexpected change in line height.

Nerd Fonts distinguishes Mono, regular, and Propo variants. Mono fonts are intended for single-cell terminal use, while regular variants may contain larger icons and Propo variants serve proportional interfaces.[^116853#46-48] Provenance glyphs should remain character-width rather than adopting Nerd Fonts’ larger icon metrics. Double-width behavior varies between terminals and should be avoided.[^116853#76-76]

## 8. Nerd Fonts integration

The feature should be implemented as an optional `font-patcher` capability:

```bash
font-patcher Input.ttf --provenance
```

Possible presentation options:

```bash
font-patcher Input.ttf --provenance=identical
font-patcher Input.ttf --provenance=subtle
font-patcher Input.ttf --provenance=explicit
```

The patching process would:

1. Read the provenance mapping definition.
2. Duplicate or derive the required base glyphs.
3. Create `.human`, `.ai`, and optional extension glyphs.
4. Add ordinary `cmap` entries for the PUA mappings.
5. Add a format 14 `cmap` subtable for variation sequences.
6. Preserve the source font’s Mono, regular, or Propo metrics.
7. Record the supported profile version in font metadata.

Nerd Fonts’ development toolchain already includes FontForge and recommends or uses FreeType, HarfBuzz, `ttfautohint`, and fontTools.[^24618e#34-48][^24618e#121-127] FontForge can remain the primary patching environment, with fontTools used to construct or validate format 14 mappings. fontTools explicitly supports creating format 14 `cmap` subtables for Unicode variation sequences.[^6]

## 9. Avoiding Nerd Fonts conflicts

Nerd Fonts already remaps several icon sets because their original PUA assignments collide. Examples include Devicons, Font Awesome Extension, Material Design, Weather Icons, and Octicons.[^a42ef7#17-27]

The provenance profile therefore must:

- Avoid the BMP PUA used extensively by existing icon sets.
- Use an explicitly reserved supplementary PUA range.
- Maintain a registry within the project.
- Test for overlap with all existing Nerd Font mappings.
- Never recycle published provenance assignments.

PUA rendering can also require application-specific configuration. For example, recent versions of `less` may require `LESSUTFCHARDEF` to recognize private-use ranges correctly.[^116853#136-146] Such behavior is acceptable for hard provenance: unsupported software may expose or reject the private characters instead of quietly presenting them as ordinary text.

## 10. Copy and paste

Both representations store provenance in the Unicode text itself:

```text
Soft: base character + selector
Hard: private-use character
```

Copying rendered text should ordinarily copy those code points. Copying a substring preserves the provenance of the selected characters without needing surrounding context.

The two modes make different tradeoffs:

| Property                      | Variation selector                   | PUA                         |
| ----------------------------- | ------------------------------------ | --------------------------- |
| Plain fallback                | Yes                                  | No                          |
| Visible failure               | No                                   | Usually tofu                |
| Independent encoded character | No                                   | Yes                         |
| Likely sanitizer treatment    | May be stripped as default-ignorable | May be retained or rejected |
| Reversible                    | Yes                                  | Yes, with mapping table     |
| Partial-copy provenance       | Yes                                  | Yes                         |

No Unicode mechanism can guarantee preservation through every clipboard, sanitizer, normalization pipeline, or plain-ASCII conversion. If provenance code points are removed, the remaining text falls back to assumed human.

That fallback favors whoever emitted the AI text. Stripping an AI selector promotes the text to the default rather than to unknown. This asymmetry is the strongest argument for PUA mode on AI text: an unsupported or rejected PUA character fails visibly instead of quietly joining the assumed-human pool.

## 11. Conversion and inspection

A small reference tool should support:

```bash
nfprov inspect file.txt
nfprov mark --human file.txt
nfprov mark --unknown file.txt
nfprov mark --ai --mode=vs file.txt
nfprov mark --ai --mode=pua file.txt
nfprov convert --from=vs --to=pua file.txt
nfprov convert --from=pua --to=vs file.txt
nfprov strip file.txt
```

Core transformations are straightforward:

```text
Plain A → A + VS_HUMAN
Plain A → A + VS_AI
Plain A → A + VS_UNKNOWN
Plain A → PUA_AI_A

A + VS_AI ↔ PUA_AI_A

A + VS_HUMAN   → Plain A
A + VS_AI      → Plain A
A + VS_UNKNOWN → Plain A
PUA_AI_A       → Plain A
```

Stripping returns text to the assumed-human default. It is a lossy operation and the tool should say so.

Decoders must preserve unrecognized code points rather than guessing their intended base characters.

## 12. Editing behavior

Editors that understand the profile should:

- Preserve provenance when moving text.
- Apply the current provenance mode to newly typed characters.
- Preserve existing provenance when changing presentation.
- Provide explicit conversion among plain, explicit human, AI, and unknown states.
- Treat deletion and replacement using ordinary character-editing semantics.
- Avoid silently converting PUA characters into ordinary Unicode.

A minimal integration needs one insertion mode, since human input can stay plain:

```text
Human input → base, assumed human
AI input    → base + VS_AI or PUA counterpart
```

Explicit human and unknown are opt-in refinements. A program that adopts explicit human marks its human input with `VS_HUMAN` and keeps the AI mode unchanged.

An application may use PUA mode for generated output and VS mode for human input, making unsupported AI text fail visibly while human text falls back normally.

## 13. Testing

Testing should cover:

- HarfBuzz shaping.
- FreeType rendering.
- Terminal emulators.
- GUI editors.
- Browsers.
- Clipboard round trips.
- Unicode normalization.
- Search and selection.
- PDF generation and extraction.
- Mono, regular, and Propo builds.
- Mixed plain, VS, and PUA text.
- Unsupported-font fallback.

The Nerd Fonts workflow calls for testing with:

```bash
fontforge --script ./font-patcher \
  src/unpatched-fonts/XYZ/XYZ.ttf \
  --complete --debug 2
```

Generated test fonts should be deleted rather than committed; patched font artifacts are produced by project workflows.[^797aba#40-43] All font variations should then be exercised through the project’s patching script.[^797aba#45-47]

## 14. Reference example

Logical text:

```text
Written by a human. Generated by AI.
```

Soft encoding:

```text
Written by a human. G<VS_AI>e<VS_AI>n<VS_AI>...
```

Hard AI encoding:

```text
Written by a human. <PUA_G><PUA_e><PUA_n>...
```

The human sentence stays plain and is assumed human. A program that has opted into explicit human writes it as `W<VS_H>r<VS_H>i<VS_H>...` instead, with the same rendering under every font.

Presentation:

| Environment                       | Result                                                |
| --------------------------------- | ----------------------------------------------------- |
| Supporting font, identical style  | Ordinary readable sentence                            |
| Supporting font, subtle style     | Readable sentence with subtle provenance distinctions |
| Unsupported font, VS AI encoding  | Entire sentence appears as ordinary text              |
| Unsupported font, PUA AI encoding | Human portion is readable; AI portion appears as tofu |

## 15. Summary

The design uses one Nerd Font to support two complementary forms of inline provenance:

- **Variation selectors** attach provenance to ordinary Unicode characters and degrade gracefully to plain text.
- **PUA counterparts** make provenance part of the encoded character itself and cause unsupported AI text to fail visibly as tofu.
- Both representations map to the same provenance-aware glyphs in the supporting font.
- Copying any marked fragment carries its character-level metadata with it.
- Ordinary Unicode remains unmarked rather than being treated as proof of human authorship.

The core model is:

```text
Base character + variation selector = soft provenance
Private-use counterpart             = hard provenance
Nerd Font glyph                      = presentation
```

**References**

[^1]: [UTR #28: Unicode 3.2](https://www.unicode.org/reports/tr28/tr28-3.html) (8%)

[^2]: [cmap — Character to Glyph Index Mapping Table](https://learn.microsoft.com/en-us/typography/opentype/spec/cmap) (17%)

[^3]: [Private-Use Characters, Noncharacters & Sentinels FAQ](https://www.unicode.org/faq/private_use.html) (5%)

[^4]: [FAQ and Troubleshooting · ryanoasis/nerd-fonts Wiki · GitHub](https://github.com/ryanoasis/nerd-fonts/wiki/FAQ-and-Troubleshooting) (29%)

[^5]: [Contributor Developer Setup · ryanoasis/nerd-fonts Wiki · GitHub](https://github.com/ryanoasis/nerd-fonts/wiki/Contributor-Developer-Setup) (6%)

[^6]: [fontTools.ttLib.tables._c_m_a_p — fontTools Documentation](https://fonttools.readthedocs.io/en/latest/_modules/fontTools/ttLib/tables/_c_m_a_p.html) (13%)

[^7]: [Codepoint Conflicts · ryanoasis/nerd-fonts Wiki · GitHub](https://github.com/ryanoasis/nerd-fonts/wiki/Codepoint-Conflicts) (9%)

[^8]: [contributing.md](https://github.com/ryanoasis/nerd-fonts/blob/master/contributing.md#steps-for-updating-an-existing-font) (12%)
