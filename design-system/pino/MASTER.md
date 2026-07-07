# pino — Design System (MASTER)

**Status:** locked 2026-07-07 · Source of truth for colors, glass, and component styling.
Playground: [`mockups/pino-design-lab.html`](../../mockups/pino-design-lab.html)

pino is a mobile companion for coding agents: a **terminal-neutral** aesthetic —
pure-grey neutrals (zero hue) + a single **green** accent, over a floating
**Liquid-Glass** top bar and composer.

## Color model

Neutrals are defined in **OKLCH with chroma = 0** (mathematically hueless) so
light and dark share identical character — no blue/slate drift. The accent is a
single hue (150°) with lightness tuned per mode. Hex values are sRGB conversions
for code that needs them.

### Palette

| Token | Role | Light — OKLCH · hex | Dark — OKLCH · hex |
|-------|------|---------------------|--------------------|
| `accent` | brand / primary (logo, send, active) | `0.62 0.17 150` · `#03A14A`¹ | `0.80 0.19 150` · `#49DE78` |
| `onAccent` | content on accent | `#FFFFFF` (or dark green) | `#0B2612` |
| `bg` | app background | `0.985 0 0` · `#FAFAFA` | `0.205 0 0` · `#171717` |
| `surface` | cards, sheets, raised | `1 0 0` · `#FFFFFF` | `0.26 0 0` · `#242424` |
| `bubbleUser` | user message bubble (grey, **not** accent) | `0.94 0 0` · `#EBEBEB` | `0.30 0 0` · `#2E2E2E` |
| `text` | primary text / "black" icons | `0.22 0 0` · `#1B1B1B` | `0.97 0 0` · `#F5F5F5` |
| `muted` | secondary text, disabled icons | `0.50 0 0` · `#636363` | `0.70 0 0` · `#9E9E9E` |
| `hairline` | borders, dividers | `0.90 0 0` · `#DEDEDE` | `0.32 0 0` · `#333333` |

¹ **Shipped accent = the logo green `#4ADE80`** in both modes (approved look). The
`#03A14A` light value is the stricter-contrast alternative if accent-as-text/
border ever needs 4.5:1 on white.

### Rules
- **Neutrals must stay `C=0`.** Never reintroduce slate/blue-tinted greys.
- **Green is the only hue.** Use it sparingly: logo, send button, status dot,
  active states, list avatars. Everything else is neutral.
- **User bubbles are grey** (`bubbleUser`), never the accent — avoids "too much green."
- Icons: default = `text` ("black"); accent icons = green; disabled = `muted`.

## Liquid Glass (top bar + composer)

Unified recipe for all floating glass surfaces (identical top bar & composer):

| Param | Value | Notes |
|-------|-------|-------|
| tint (light) | `#FFFFFF` @ **50%** → `0x80FFFFFF` | ~50% keeps text legible; not milky |
| tint (dark) | `#181818` @ 50% → `0x80181818` | neutral, not blue |
| blur | **18** | frost strength |
| saturation | **1.8** | **the anti-"milky" lever** — pops refracted colour |
| lightIntensity | light `0.9` / dark `0.5` | keep light ≤ ~1.0 or it reads too white on device |
| ambientStrength | light `0.3` / dark `0.2` | |
| refractiveIndex | `1.3` | subtle "liquid" bend |
| border | 1px, white @ `0.35` (light) / `0.14` (dark) | edge highlight |
| shadow | `0 8 24`, black @ `0.15` | depth |
| radius | 26 (bars) / 28 (composer) | |

Implemented in `app/lib/ui/widgets/glass.dart` (`GlassSurface`), backed by the
`liquid_glass_renderer` shader. `fakeGlassProvider` swaps to a cheap backdrop-blur
fallback.

## Typography
System font (SF Pro Text / Inter). Monospace (`ui-monospace`) for tool cards, diffs,
and code. Body ≥ 15px, line-height ~1.5.

## Components (see Design Lab)
- **Composer** — floating glass; 1-line at rest → 3 lines on focus; send fades in only when non-empty (SPEC-06).
- **Chat** — user = grey bubble (right); agent = plain text (left); thinking = muted italic; tool call = monospace card with green `+` / red `−` diffs.
- **Top bar** — glass, circular back/quit buttons, title + `model · thinking`, green connection dot.
- **Logo** — green `pino` mark (`pino_mark.dart`, `#4ADE80`).

## Contrast (WCAG)
- Light: `text #1B1B1B` on `bg #FAFAFA` ≈ 15:1 ✓ · `muted #636363` on bg ≈ 5.6:1 ✓
- Dark: `text #F5F5F5` on `bg #171717` ≈ 15:1 ✓ · `muted #9E9E9E` on bg ≈ 6.6:1 ✓
