# Onetime Secret — Design System

Design system distilled from the Astro/Vue redesign of onetimesecret.com (`develop` branch, 2026), plus sibling properties.

**Product family:**
- **onetimesecret.com** — main site & create-a-secret app (Astro 5 + Vue 3 + Tailwind 4)
- **docs.onetimesecret.com** — Starlight docs
- **blog.onetimesecret.com** — Astro blog
- **secretarylinks.com** — sibling product (secure inbound collection, Astro + DM Serif Display + Inter)
- **Regional instances** — us / ca / eu / nz / uk subdomains for data sovereignty

**Sources referenced** (not pre-attached; browse via GitHub import):
- `onetimesecret/onetimesecret.com@develop` → `src/styles/tailwind.css`, `src/styles/global.css`, `.interface-design/system.md`, `src/components/vue/**`, `public/etc/img/*.svg`
- `onetimesecret/secretarylinks.com@main` → `src/styles/global.css` (different visual system — DM Serif Display + 4 themes)
- Logo: `uploads/onetime-logo-v3-md.png` + `public/logo.svg`
- Fonts: `uploads/ZillaSlab*.woff2` (Highlight Regular/Bold, SemiBoldItalic, LightItalic). Body weights pulled from Google Fonts at runtime — **flagged**, see Caveats below.

---

## Index

```
README.md                     — this file
SKILL.md                      — agent-invocable summary
colors_and_type.css           — design tokens (colors, themes, type scale, utilities)
fonts/                        — Zilla Slab woff(2) files
assets/                       — logo(s), favicon, brand marks
preview/                      — design-system tab specimen cards
ui_kits/
  marketing-site/             — onetimesecret.com homepage recreation
  secret-app/                 — create/view/reveal secret flow
```

---

## CONTENT FUNDAMENTALS

**Voice.** Direct and mechanism-forward. We explain what things do, not how they'll transform your business. Short declaratives. No corporate hedging.

**Words we don't use:** *empower, unlock, vault, archive, forever, transform, journey, seamless, leverage, synergy*. No "we believe" homilies. No em-dash manifestos.

**Words we do use:** *share, view, burn, expire, delete, encrypt, retain, comply, sovereignty*. Mechanism verbs, compliance nouns.

**Person.** "You" for the reader, "we" for the product/company sparingly. Not first-person plural for every feature — features do things, they don't "help you unlock X".

**Casing.** Sentence case everywhere in UI. Headings are sentence case. Buttons are sentence case ("Create a secret link", not "Create A Secret Link"). Section labels are ALL CAPS with 0.15em tracking ("HOW IT WORKS"). Product name: **Onetime Secret** (two words, capitalized).

**Sample copy from the live site:**
- Hero: "Keep sensitive information *out of* your inboxes and chat logs."
- Subtitle: "Share passwords, API keys, and private messages through links that self-destruct after one view."
- CTA: "Create a secret link" (not "Get started" or "Try it free")
- Trust: "Operating since 2011" / "Zero retained" / "Regional data residency"
- How it works: "Paste." "Share." "Burns after reading."

**Trust signals.** Empirical, not testimonial. Years operating, secrets shared (count), jurisdictions supported, zero retained. Logos of regulated-industry customers are fine, pull-quotes from their CTOs are not.

**No emoji.** Technical audience. If a status needs a visual, use an icon or colored dot.

**Error copy.** Tells you what happened and what to do. "This secret was already viewed or has expired." not "Oops! Something went wrong."

---

## VISUAL FOUNDATIONS

### Colors

Two families. **Brand** is a warm red-orange (`#dc4a22` — the signature logo color) with a 50–950 scale. **Brandcomp** is a cyan/teal complement used sparingly (API feature, secondary accent, gradient endpoint). Neutrals are Tailwind zinc, mapped to a semantic surface-0..4 scale that flips with theme.

Themes are **first-class, not afterthoughts**: Light, Dark, Sepia, High Contrast. Dark is canonical (SSG renders dark-first). All text tokens must pass WCAG AA on all three surfaces in both modes — the `tailwind.css` comment block in the source is a contrast audit, not an aspiration.

### Type

Brand serif: **Zilla Slab** (Mozilla's open-source slab). Applied to all headings via `var(--font-brand)` with `letter-spacing: -0.02em`. Body is system sans — no custom body face in the main site. Hero h1 is `font-extrabold` (800), section h2 is `font-bold` (700).

`secretarylinks.com` uses **DM Serif Display + Inter + JetBrains Mono** instead — sibling property, different serif voice, but same underlying semantic token system.

### Spacing & layout

Section vertical padding: `py-16 sm:py-20` standard, `py-20 sm:py-28` for emphasis (hero, CTA). Container: `max-w-7xl mx-auto px-4 sm:px-6 lg:px-8` standard, narrower (`max-w-5xl`, `max-w-3xl`) for hero and CTA. Bento grid gap: `gap-4`. HowItWorks uses a clever `gap-[2px]` over `bg-surface-3` to create divider lines.

Section background alternation: `surface-0, surface-0, surface-1, surface-0, surface-1, surface-0`. GlobalInfrastructure adds a `border-y border-surface-3` for section-level emphasis.

### Backgrounds & texture

Noise overlay on every page: `body::before` applies an SVG fractal noise at `opacity: 0.03`, `z-index: 9999`, `pointer-events: none`. Subtle — you see it more on solid dark areas.

Ambient glows: large blurred circles behind hero & CTA. `bg-brand-500 opacity-[0.06] blur-[120px]` with sizes 500–600px. Never hardcoded colors — always `color-mix()` or brand token with opacity.

No hand-drawn illustrations. No stock photography. No abstract 3D. No gradient blobs. The visual vocabulary is **mechanism and transit**, not abundance.

### Animation

Minimal. Reduced-motion respected globally (every animation wrapped in `@media (prefers-reduced-motion: no-preference)` or disabled in the global `*` selector). Badge dot pulses at 2s ease-in-out. Scroll reveal (secretarylinks) uses `cubic-bezier(0.16, 1, 0.3, 1)` (ease-out expo) with staggered children 80ms apart. No spring bounces on the main site. No page transitions.

### Hover / press states

- **Links:** color shift only — `hover:text-brand-600 dark:hover:text-brand-400`
- **Buttons:** background darkens one step (`bg-brand-600 hover:bg-brand-700`)
- **Cards:** border brightens (`border-surface-3 hover:border-surface-4`) with `transition-colors duration-200`. No lift, no shadow swell.
- **Press:** no shrink, no translate. Color-change only.

### Borders & shadows

**Borders-only depth model.** No `box-shadow` on cards. Exception: the hero secret form uses `shadow-2xl shadow-black/40` for focal hierarchy. Nothing else.

Border colors come from surface-3 (default) and surface-4 (hover/emphasis). Brand-tinted borders use fractional opacity: `border-brand-500/15`, `border-brand-500/30`.

### Corner radii

- `rounded-lg` (Tailwind) → **overridden to 20px** in the theme (`--radius-lg: 1.25rem`). Card default.
- `rounded-xl` (16px) — icon containers.
- `rounded-2xl` (24px) — larger card / bento grid.
- `rounded-full` — pills, badges, status dots.

### Transparency & blur

Used sparingly. Header has `bg-white/95 dark:bg-gray-900/95 backdrop-blur-sm`. Ambient glows use low opacity + heavy blur. Brand-tinted accents use `/10` or `/8` opacity over solid surface. No frosted-glass cards.

### Icons

Icon-font approach with **multiple CDN-sourced collections** sprited inline as Vue components (`IconSources.vue` includes Heroicons, Phosphor, Material Symbols, MDI, Tabler, Font Awesome 6, Simple Icons, Carbon). Usage is gated by a custom `<OIcon collection="heroicons-outline" name="lock-closed" />` component. Icon container is `size-12` (48px) `rounded-xl` with brand or brandcomp tint. Icon itself is `size-6` (24px).

Lucide is imported directly on FeatureHighlights (`lucide-vue-next`). So **Lucide is the closest single-library substitute** for design work — same stroke weight, same 24px sizing.

### Cards

```
bg-surface-1 + rounded-2xl + border border-surface-3
hover: border-surface-4
p-6 sm:p-8
```

No shadow. No gradient fill. Icon container top-left, title below, description below that.

### Protection gradients vs capsules

No protection gradients. The site uses **capsules** (rounded-full pills) for badges, trust markers, and enterprise capability tags — not gradient overlays on content. Pills are `border border-surface-3 bg-surface-1` (neutral) or `border-brand-500/30 bg-brand-500/10` (brand).

### Layout rules

- Sticky header, 4rem default (`--header-height: 4rem`, also `scroll-padding-top`).
- Max content width: 80rem (`max-w-7xl`) for standard sections, narrower for hero/CTA.
- Scroll behavior: smooth. Scroll padding accounts for header.
- Footer is separate component; two-column grid of link lists.

### Accessibility (encoded in the system)

- Every `<section>` must have `aria-labelledby` pointing to its heading `id`.
- Decorative elements use `aria-hidden="true"`.
- Focus visible: `focus-visible:outline-2 outline-offset-2 outline-brand-600`.
- Reduced-motion respected (global `*` selector override).
- Contrast ratios documented inline in `tailwind.css` — do not drift lighter.

---

## ICONOGRAPHY

The main site's icon approach is **multi-library sprited SVG**, chosen per-context. The available collections (from `src/components/vue/icons/`):

| Collection        | Typical use                          |
|-------------------|--------------------------------------|
| Heroicons outline | Navigation, menus, close/open        |
| Heroicons solid   | Status, filled actions               |
| Lucide            | Feature cards (homepage)             |
| Phosphor          | Illustrative / editorial             |
| Material Symbols  | Dense UI (settings, admin)           |
| MDI               | Fallback / general purpose           |
| Tabler            | Secondary                            |
| Font Awesome 6    | Brand icons, social                  |
| Simple Icons      | Third-party logos (GitHub, etc)      |
| Carbon            | Enterprise / infrastructure          |

**For this design system:** we default to **Lucide** (CDN) because it's the single collection actually imported directly in the Vue source (not just sprited). Same stroke weight, 1.5px, 24×24 default. If a specific icon isn't in Lucide, fall back to Heroicons outline at the same size.

**Loading:** `<script src="https://unpkg.com/lucide@latest"></script>` then `lucide.createIcons()`. This is a **substitution** — the real app ships pre-sprited SVGs from mixed sources. Flagged.

**Emoji:** not used. **Unicode chars as icons:** used sparingly for arrows (`→`, `&rarr;`) in CTAs and menu items. That's it.

**Assets copied in:**
- `assets/onetime-logo-v3-md.png` — 640px PNG logo (user-provided)
- `assets/onetime-logo-v3.svg` — large SVG (from `public/logo.svg` / `public/v3/img/onetime-logo-v3-xl.svg`, both identical)
- `assets/favicon.svg` — favicon
- `assets/safari-pinned-tab.svg` — monochrome pinned-tab variant

Logo is **geometric lowercase "s"** (for "secret") knocked out of a brand-orange square with rounded corners. The "s" is custom — thick slab terminals, with a distinctive angled upper curve that echoes Zilla Slab. It's the *only* brand illustration. There is no mascot, no spot illustration set, no pattern library. **Do not draw new logo variants** — use what's in `assets/`.

---

## CAVEATS / FONT SUBSTITUTIONS

- **Zilla Slab body weights missing.** Uploaded files cover only italic variants and the "Highlight" display cut. I pull body weights (300/400/500/600/700 regular) from Google Fonts at runtime. Please upload `ZillaSlab-Regular.woff2`, `ZillaSlab-Medium.woff2`, `ZillaSlab-SemiBold.woff2`, `ZillaSlab-Bold.woff2` for fully self-hosted.
- **Icons are substituted to Lucide (CDN).** Real app uses a mixed sprite bank (9 collections). If you need a specific icon from Phosphor/Material Symbols/etc, say so and I'll swap.
- **High-Contrast theme is my extrapolation.** The source only implements Light and Dark. Sepia is extrapolated from `secretarylinks.com`'s sepia; High Contrast is built to WCAG AAA from scratch.
- **No secret-view screen code imported** — the `Secret` / `Reveal` pages live in the **Ruby app repo** (`onetimesecret/onetimesecret`), not in the Astro front-end. I recreated those screens from llms.txt / docs descriptions, flagged in `ui_kits/secret-app/README.md`.

---

## Ask

**I need you to confirm a few things before this lands:**

1. **Font substitution OK?** Zilla Slab regular/medium/bold come from Google Fonts CDN at runtime. Acceptable, or do you want me to hold until you upload the woff2s?
2. **Icon library?** I used Lucide as the single-library substitute. If the mixed-sprite-bank approach matters for production, confirm which subset (Heroicons? Phosphor?) you want as the primary.
3. **High-Contrast theme.** I invented it — WCAG AAA, pure black on white, brand-800 as accent. Need your design review.
4. **Secretary Links + docs/blog.** Do you want dedicated UI kits for those properties (different fonts, different vibe) or is this main-site + app enough?
