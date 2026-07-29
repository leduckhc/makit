---
name: makit
description: Mobile companion for coding agents — a floating Liquid-Glass top bar and composer over a calm, neutral Material 3 surface, accented by a single brand green.
version: 1.0.0
tags: [mobile, flutter, material3, liquid-glass, minimal, developer-tool]
---

## Design Philosophy

makit is a quiet, focused surface for driving coding agents from your phone (and
desktop). The interface should feel **calm and neutral**, letting the agent's
output — chat, code, diffs, tool calls — be the loud part.

- **One hue.** Everything is neutral grey except a single brand green
  (`#4ADE80`), used sparingly for the logo, send button, status/connection dot,
  active states, and list avatars. Green is a highlight, never a wash.
- **Neutrals stay hueless.** Greys are chroma-0 (no blue/slate drift) so the app
  reads the same in light and dark.
- **Glass floats, content grounds.** Only the top bar and composer use Liquid
  Glass; the transcript beneath is flat and legible.
- **One scale, no magic numbers.** Type, spacing, and radius come from fixed
  scales. When a case isn't covered, prefer the nearest token over a new value.

This is a Flutter + Material 3 app: tokens map to `ColorScheme` /
`TextTheme` roles, defined once in
[`app/lib/app/theme.dart`](app/lib/app/theme.dart). Playground:
[`mockups/makit-design-lab.html`](mockups/makit-design-lab.html).

## Colors

The palette derives from a single green seed via `ColorScheme.fromSeed`
(`kMakitAccent = #4ADE80`). M3 supplies `primary` and all on-colors (contrast is
handled by the tonal system); the neutral surface ramp is overridden back to
pure grey in `theme.dart`. Values below are `light` / `dark`.

> Each colour is given as sRGB hex **and** OKLCH — they describe the exact same
> colour (the hex round-trips through `sRGB → OKLab → OKLCH` and back). OKLCH is
> the design intent (perceptual lightness `L`, chroma `C`, hue `H`); hex is for
> code that needs sRGB. Neutrals are `C = 0` (achromatic — hue is `0`/none), which
> is what keeps them hueless.

### Brand & semantic
- `--color-primary`: `#4ADE80` · `oklch(80.0% 0.182 151.7)` (seed-derived per
  mode) — brand green: logo, send button, links, active states,
  connection/status dot, "ok" check.
- `--color-on-primary`: M3-derived — content on a primary fill.
- **Status semantics.** Beyond the neutral ramp + brand green, these tuned hues
  are the *only* sanctioned colours (defined in `theme.dart`, read by
  `SessionStatusChip`/`Dot`, connection chip, settings, sessions list). No raw
  `Colors.orange/red/green/blue` in UI code.
  - running / connected / active / ok → `--color-primary`
  - error / offline → `colorScheme.error`
  - idle / exited / draft / muted → `colorScheme.outline`
  - `--status-warning` (awaiting input, connecting, dev-fake): `#E0A72E` · `oklch(76.3% 0.144 81.2)`
  - `--status-caution` (awaiting approval — stronger "act now"): `#E07B39` · `oklch(68.5% 0.148 50.8)`
- Risk affordances (tool calls), tuned to sit with the neutrals:
  - `--tool-risky`: `#E8A33D` · `oklch(76.5% 0.140 72.9)` — risky tool-call icon.
  - `--tool-destructive`: `#E5544B` · `oklch(63.9% 0.182 27.0)` — destructive tool-call icon.
  - Diff add / delete: `#3FB950` · `oklch(69.5% 0.181 145.6)` /
    `#F85149` · `oklch(66.5% 0.205 27.0)`.
- **Pull-request state** (worktree glyphs in the desktop sidebar row, the
  composer status pill, the window title strip and the mobile worktree pill —
  all resolved by `prStateStyle` in `ui/widgets/pr_state_style.dart`, so a state
  reads identically everywhere):
  - open → `--color-primary` + pull-request symbol
  - merged → `--pr-merged`: `#8957E5` · `oklch(58.4% 0.205 295.6)` (GitHub's
    merged purple) + merge symbol
  - closed → `colorScheme.error` +
    `assets/icons/git-pull-request-closed-light.svg` (Phosphor ships no
    closed-PR glyph, so this mark is in-house). It ships in the whole Phosphor
    weight range — `-{thin,light,regular,bold,fill}.svg` — drawn parametrically
    on Phosphor's 256 grid: node columns x72/x200 and ring centre radius 24 stay
    fixed, the weight is only the stroke (8/12/16/24, plus solid nodes for
    `fill`). **Light** is the one wired up, because every glyph the app renders
    is `PhosphorIconsLight`; reach for a heavier sibling only alongside a heavier
    Phosphor set. `test/ui/widgets/closed_pr_glyph_test.dart` guards the family.
  - no PR → `colorScheme.outline` + branch symbol
  - `gitMerge` means *merged* everywhere — an **open**-PR count (repo card meta)
    uses the pull-request symbol instead.
- **Contrast-safe text variants (light theme).** The vivid status/diff hues
  above are correct for dots, icons, and washes, but as small *text* on the
  `#FAFAFA` surface they only reach ~2–3:1 (below WCAG AA). Labels use darker,
  AA-passing foregrounds on light (dark keeps the vivid hues): resolved via the
  `ColorScheme` getters `diffAddText`/`diffDelText`/`statusWarningText`/
  `statusCautionText` in `theme.dart`. `--pr-merged` needs a variant on *both*
  surfaces (4.4:1 light / 3.9:1 dark as text): `prMergedText` resolves to
  `#6E40C9` (light) / `#A371F7` (dark) and reaches labels as
  `PrStateStyle.textColor`.

### Neutral surface ramp (chroma-0)

| Token | Role | Light (hex · oklch) | Dark (hex · oklch) |
|-------|------|---------------------|--------------------|
| `--surface` | scaffold background | `#FAFAFA` · `oklch(98.5% 0 0)` | `#171717` · `oklch(20.5% 0 0)` |
| `--surface-container-lowest` | raised over bg (cards) | `#FFFFFF` · `oklch(100% 0 0)` | `#121212` · `oklch(18.2% 0 0)` |
| `--surface-container-low` | | `#F3F3F3` · `oklch(96.4% 0 0)` | `#1E1E1E` · `oklch(23.5% 0 0)` |
| `--surface-container` | | `#EDEDED` · `oklch(94.6% 0 0)` | `#242424` · `oklch(26.0% 0 0)` |
| `--surface-container-high` | user message bubble | `#E7E7E7` · `oklch(92.8% 0 0)` | `#2E2E2E` · `oklch(30.1% 0 0)` |
| `--surface-container-highest` | | `#E1E1E1` · `oklch(91.0% 0 0)` | `#383838` · `oklch(34.1% 0 0)` |
| `--on-surface` | primary text / "black" icons | `#1B1B1B` · `oklch(22.2% 0 0)` | `#F5F5F5` · `oklch(97.0% 0 0)` |
| `--on-surface-variant` / `--outline` | secondary text, muted icons | `#636363` · `oklch(50.0% 0 0)` | `#9E9E9E` · `oklch(69.9% 0 0)` |
| `--outline-variant` | borders, dividers, hairlines | `#DEDEDE` · `oklch(90.1% 0 0)` | `#333333` · `oklch(32.1% 0 0)` |

### Rules
- **Never reintroduce blue/slate-tinted greys** — neutrals stay chroma-0.
- **User bubbles are grey**, never the accent (avoids "too much green").
- Icons: default = `on-surface`; accent = `primary`; disabled = `on-surface-variant`.

## Typography

**One canonical type scale**, pinned in `_makitTextTheme`
([`app/lib/app/theme.dart`](app/lib/app/theme.dart)) on a Material 2021 base and
applied to both themes. Widgets read roles via
`Theme.of(context).textTheme.<role>` — **never** hardcode `fontSize`,
`fontFamily`, or a bare sized `TextStyle`.

- **Font family (UI):** `SF Pro Text, system-ui, sans-serif` (`kSansFontFamily`)
- **Font family (code):** `kMonoFontFamily` + `kMonoFallback`
  (`SF Mono, Menlo, Consolas, Roboto Mono, Courier New, monospace`) — apply with
  the `.mono` extension: `theme.textTheme.bodyMedium?.mono`.

### Scale

| Role | Size | Weight | Use case |
|------|------|--------|----------|
| `titleLarge` | `20` | `600` | screen / dialog titles |
| `titleMedium` | `16` | `600` | section titles, nav headers |
| `titleSmall` | `14` | `600` | tool-view titles, card headers |
| `bodyLarge` | `15` | `400` | rare emphasis body |
| `bodyMedium` | **`13`** | `400` | **primary body** — chat text, markdown, code |
| `bodySmall` | `12` | `400` | secondary text, captions, hints, diffs |
| `labelLarge` | `14` | `500` | buttons, prominent labels |
| `labelMedium` | `12` | `500` | pills, chips, badges (weighted) |
| `labelSmall` | `11` | `500` | timestamps, tiny tags, "coming soon" |
| `labelXs` (extension) | `10` | `500` | dense pills/badges/chip-actions — PR pill, PR action, status/tag chips (one step below `labelSmall`, reads as secondary to body) |

Dense pills read smaller than body: their **text** uses `textTheme.labelXs` and
their **leading glyph** uses `kPillIconSize` (`11`), both from `theme.dart`.

Line height: ~`1.3–1.5` for body/mono where set locally.

**Normalization contract:** pick the nearest role instead of a new size.
`copyWith` may change `color`, `fontWeight`, or `fontStyle` — **not** `fontSize`.
A new numeric size is a design change and belongs in the scale.

## Spacing

Base unit `4px` with `2px` half-steps for tight icon/label gaps. Tokens live in
[`app/lib/app/theme.dart`](app/lib/app/theme.dart); prefer them over raw literals
for `padding`, gaps, and `SizedBox` spacers. One-off values off this scale
(`3, 5, 7, 9, 14, …`) are allowed sparingly but should be rare.

| Token | Value | Use case |
|-------|-------|----------|
| `kSpace2` | `2px` | hairline gaps (icon↔label, chip vertical padding) |
| `kSpace4` | `4px` | tight gaps, icon padding |
| `kSpace6` | `6px` | small inline gaps (most common icon↔text spacer) |
| `kSpace8` | `8px` | default inline spacing / chip padding |
| `kSpace10` | `10px` | medium gaps, list-tile insets |
| `kSpace12` | `12px` | default card / control padding |
| `kSpace16` | `16px` | comfortable padding, stack spacing |
| `kSpace20` | `20px` | chat gutter (`kChatGutter`), wide insets |
| `kSpace24` | `24px` | section / screen padding, sheet insets |
| `kSpace32` | `32px` | large separators |

Applies to `EdgeInsets.all` / `.symmetric` and `SizedBox` spacers. `EdgeInsets.only`
/ `fromLTRB` and `Positioned` use the same values but are left as literals (their
named args collide with non-spacing widgets).

### Radius
Tokens in [`app/lib/app/theme.dart`](app/lib/app/theme.dart); the chat surface
re-labels `kRadius8/12/16` as `kChatRadiusSmall/Medium/Large`.

| Token | Value | Use case |
|-------|-------|----------|
| `kRadius6` | `6px` | tiny tags / badges |
| `kRadius8` | `8px` | chips, pills, code blocks, small controls |
| `kRadius10` | `10px` | list tiles, medium controls |
| `kRadius12` | `12px` | cards, banners (tool cards, error banners) |
| `kRadius16` | `16px` | message bubbles, large sheets |
| `--radius-glass-bar` | `26px` | glass top bar |
| `--radius-glass-composer` | `28px` | glass composer |
| `--radius-pill` | `9999px` | avatars, circular buttons, status dots |

### Chat transcript layout
The transcript is **gutter-agnostic**: item widgets carry no horizontal padding;
the surface applies one gutter + inter-row gap via `transcriptRow` so every row
shares one edge and a uniform rhythm. Tokens:
[`app/lib/ui/session/chat_metrics.dart`](app/lib/ui/session/chat_metrics.dart).

| Token | Value | Role |
|-------|-------|------|
| `kChatGutter` | `20` | horizontal inset, applied once by the surface |
| `kChatRowGap` | `10` | space between adjacent rows |

## Components

### Liquid Glass (top bar + composer)
Unified recipe for all floating glass surfaces
([`app/lib/ui/widgets/glass.dart`](app/lib/ui/widgets/glass.dart), `GlassSurface`,
backed by the `liquid_glass_renderer` shader; `fakeGlassProvider` falls back to a
cheap backdrop blur).

| Param | Value | Notes |
|-------|-------|-------|
| tint (light) | `#FFFFFF` @ 50% (`0x80FFFFFF`) | keeps text legible, not milky |
| tint (dark) | `#181818` @ 50% (`0x80181818`) | neutral, not blue |
| blur | `18` | frost strength |
| saturation | `1.8` | the anti-"milky" lever — pops refracted colour |
| lightIntensity | `0.9` light / `0.5` dark | keep light ≤ ~1.0 |
| ambientStrength | `0.3` light / `0.2` dark | |
| refractiveIndex | `1.3` | subtle "liquid" bend |
| border | 1px white @ `0.35` light / `0.14` dark | edge highlight |
| shadow | `0 8 24`, black @ `0.15` | depth |

### Composer
Floating glass; 1-line at rest → grows on focus. Send button fades in only when
the field is non-empty (SPEC-06). Cancel button appears only while running with
empty input.

### Chat
- **User message:** grey bubble (`surface-container-high`), right-aligned,
  `--radius-bubble`. Never the accent colour.
- **Agent message:** plain text, left-aligned, `bodyMedium`.
- **Thinking:** muted italic (`bodyMedium`, `on-surface-variant` @ 65%).
- **Tool call:** monospace card (`--radius-card`) with green `+` / red `−`
  diffs; risk icons use `--tool-risky` / `--tool-destructive`.
- **Busy indicator:** a shimmering work-flavoured word (`labelLarge` italic),
  shared by mobile + desktop.

### Chips, pills & badges
- Tinted background at ~`12–15%` alpha of the accent colour, `--radius-code`.
- Text uses `labelMedium` (weighted) or `labelSmall` (tiny tags); icon-in-chip
  size `12`, gap `sm`.

### Top bar
Glass, circular back/quit buttons (`--radius-pill`), title + `model · thinking`
subtitle, green connection dot.

### Desktop title bars
The pane column stacks two rows for hierarchy, split by a 1px `outline-variant`
hairline:
- **Window title strip** (`_WorktreeTitle`) — worktree/branch as a quiet
  context label (`labelMedium`, `outline`, `letterSpacing 0.8`, leading
  `gitBranch` icon; case preserved).
- **Pane title** (`_PaneHeaderStrip`) — session name as the primary line
  (`titleSmall`, `on-surface`) with a leading `SessionStatusDot`, then
  session-actions + close-pane controls.

`SessionStatusDot` (`desktop/chat/session_status_dot.dart`) is shared by sidebar
tiles and the pane header so a session's status reads identically everywhere.

### Logo
Green `makit` wordmark (`makit_mark.dart`, `#4ADE80`).

## Contrast (WCAG)
- Light: `on-surface #1B1B1B` on `surface #FAFAFA` ≈ 15:1 ✓ · `on-surface-variant
  #636363` ≈ 5.6:1 ✓
- Dark: `on-surface #F5F5F5` on `surface #171717` ≈ 15:1 ✓ · `on-surface-variant
  #9E9E9E` ≈ 6.6:1 ✓
