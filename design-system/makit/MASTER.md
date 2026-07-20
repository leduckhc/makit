# makit — Design System (MASTER)

**Status:** updated 2026-07 · Source of truth for glass and component styling.
Playground: [`mockups/makit-design-lab.html`](../../mockups/makit-design-lab.html)

> **2026-07 — Color model migrated to stock Material 3.** The app now derives
> its entire palette from a single green seed via `ColorScheme.fromSeed`
> (`kMakitAccent = #4ADE80`), with **no neutral overrides**. This intentionally
> supersedes the earlier "terminal-neutral / chroma-0" color model documented
> below: M3 surfaces now carry a subtle seed-derived tonal tint and elevation
> reads through the `surfaceContainer*` hierarchy. `primary` and all on-colors
> are M3-derived (contrast handled by the tonal system, so the old per-mode
> WCAG accent pin is gone). Brand-accent affordances use `colorScheme.primary`.
> The **glass** and **component** guidance below still applies; the palette
> table is retained only as historical reference.

makit is a mobile companion for coding agents: a floating **Liquid-Glass** top
bar and composer over a Material 3 surface palette seeded from the brand green.

## Color model (historical — superseded by stock M3, see note above)

Neutrals are defined in **OKLCH with chroma = 0** (mathematically hueless) so
light and dark share identical character — no blue/slate drift. The accent is a
single hue (150°) with lightness tuned per mode. Hex values are sRGB conversions
for code that needs them.

### Palette

| Token | Role | Light — OKLCH · hex | Dark — OKLCH · hex |
|-------|------|---------------------|--------------------|
| `primary` | accent-as-foreground (text, icons, `TextButton`, links) | **`#15803D`** (green-700, 4.8:1 on bg) | `#4ADE80` (≈9:1 on bg) |
| `brand` | logo mark, status dot, filled-button fill accent | `#4ADE80` | `#4ADE80` |
| `onPrimary` | content on primary fill | `#FFFFFF` (5:1 on `#15803D`) | `#06210F` |
| `bg` | app background | `0.985 0 0` · `#FAFAFA` | `0.205 0 0` · `#171717` |
| `surface` | cards, sheets, raised | `1 0 0` · `#FFFFFF` | `0.26 0 0` · `#242424` |
| `bubbleUser` | user message bubble (grey, **not** accent) | `0.94 0 0` · `#EBEBEB` | `0.30 0 0` · `#2E2E2E` |
| `text` | primary text / "black" icons | `0.22 0 0` · `#1B1B1B` | `0.97 0 0` · `#F5F5F5` |
| `muted` | secondary text, disabled icons | `0.50 0 0` · `#636363` | `0.70 0 0` · `#9E9E9E` |
| `hairline` | borders, dividers | `0.90 0 0` · `#DEDEDE` | `0.32 0 0` · `#333333` |

**Per-mode accent (WCAG):** bright logo green `#4ADE80` fails 4.5:1 as text/icon on
the light `#FAFAFA` bg (~1.7:1), so light mode uses a **darker green `#15803D`**
(4.8:1) for `ColorScheme.primary`; dark mode keeps `#4ADE80` (~9:1). The bright
`#4ADE80` remains the brand mark / status-dot colour in both modes (decorative).

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

## Chat transcript layout tokens

The transcript is **gutter-agnostic**: item widgets carry no horizontal padding;
the surface (mobile `SessionScreen`, desktop `DesktopChatPane`) applies one
gutter + inter-row gap via `transcriptRow` so every row — messages, tool cards,
thinking/error lines, working indicator — shares one left/right edge and a
uniform vertical rhythm. Tokens live in `app/lib/ui/session/chat_metrics.dart`.

| Token | Value | Role |
|-------|-------|------|
| `kChatGutter` | 20 | horizontal inset, applied once by the surface |
| `kChatRowGap` | 10 | space between adjacent rows |
| `kChatRadiusSmall` | 8 | code blocks |
| `kChatRadiusMedium` | 12 | tool cards, error banners |
| `kChatRadiusLarge` | 16 | message bubbles |
| `kToolRiskyColor` | `#E8A33D` | tool-call *risky* icon (was `Colors.orange`) |
| `kToolDestructiveColor` | `#E5544B` | tool-call *destructive* icon (was `Colors.red`) |

Tuned tool-risk hues match the sidebar `_StatusDot` palette so risk affordances
sit with the neutral surfaces instead of shouting. The tool-call *ok* check and
the code-block *copied* check use `colorScheme.primary` (seed green).

## Desktop title bars

The desktop pane column stacks two title rows; they carry a deliberate
hierarchy so one reads as context and the other as the active thing:

- **Window title strip** (`_WorktreeTitle`) — the worktree/branch as a quiet
  **muted, letter-spaced context label** (`labelMedium`, `outline`, `w600`,
  `letterSpacing 0.8`) with a leading `gitBranch` icon. Matches the sidebar
  repo-header treatment (case preserved — branch names are not uppercased).
- **Pane title** (`_PaneHeaderStrip`) — the session name as the **primary**
  line (`titleSmall`, `w500`, `onSurface`) with a leading [SessionStatusDot]
  for icon parity, then Session-actions + Close-pane controls.
- A **1px hairline** (`Divider(height: 1)`, `outlineVariant`) separates the
  window-title zone from the pane header + transcript below.
- Leading edges align at the 12px pane gutter (the status dot sits under the
  worktree fork icon) when the sidebar is shown.

`SessionStatusDot` (`desktop/chat/session_status_dot.dart`) is shared by the
sidebar tiles and the pane header so a session's status reads identically
everywhere.

## Components (see Design Lab)
- **Composer** — floating glass; 1-line at rest → 3 lines on focus; send fades in only when non-empty (SPEC-06).
- **Chat** — user = grey bubble (right); agent = plain text (left); thinking = muted italic; tool call = monospace card with green `+` / red `−` diffs. Busy indicator = a shimmering work-flavoured word, shared by mobile + desktop.
- **Top bar** — glass, circular back/quit buttons, title + `model · thinking`, green connection dot.
- **Logo** — green `makit` mark (`makit_mark.dart`, `#4ADE80`).

## Contrast (WCAG)
- Light: `text #1B1B1B` on `bg #FAFAFA` ≈ 15:1 ✓ · `muted #636363` on bg ≈ 5.6:1 ✓
- Dark: `text #F5F5F5` on `bg #171717` ≈ 15:1 ✓ · `muted #9E9E9E` on bg ≈ 6.6:1 ✓
