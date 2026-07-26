# makit — Design System (DESIGN.md)

**Status:** source of truth for makit's visual language.
Playground: [`mockups/linear-design-system.html`](../../mockups/linear-design-system.html)
· legacy lab: [`mockups/makit-design-lab.html`](../../mockups/makit-design-lab.html)

makit is a mobile-first companion for coding agents (a phone/tablet/web client
driving `pi` / `codex` / `claude-code` sessions on a desktop server). The visual
language is a **dark-first, flat surface system** adapted from Linear's marketing
design: a deep near-black canvas, a four-step surface ladder carrying hierarchy
through lift + 1px hairlines (not shadows), and a **single green accent used
scarcely**. A matching **light mode** ships alongside dark.

**iOS is the exception:** the top bar and composer use **Liquid Glass** (see
[§7](#7-liquid-glass--ios-only)). Everything else — content surfaces, cards,
lists, desktop chrome — is flat per this spec.

---

## 1. Principles

- **Flat depth via a surface ladder + hairlines.** No atmospheric gradients, no
  spotlight cards. Depth reads through `canvas → surface-1 → … → surface-4` and
  1px borders. (iOS glass chrome is the sole exception.)
- **Green is the only chromatic accent, and it is scarce.** Brand mark, primary
  CTA, active nav/tab, focus ring, send button, status dots. Nothing else.
- **Never put the accent on chat bubbles.** User messages sit on a neutral
  surface — avoids "too much green."
- **Dark and light are equal citizens.** Both derive from the same tokens; the
  hierarchy relationships hold in both.
- **Monospace only in code contexts** — tool cards, diffs, IDs, paths, code.

---

## 2. Color tokens

Both modes share token *names*; only values differ. Never use `#000000` true
black for canvas, and never a pure-white content surface as the page floor.

### Surface ladder

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| `canvas` | `#010102` | `#f7f8fa` | page floor; **darker chrome** (desktop sidebar + topbar) |
| `surface-1` | `#0c0d10` | `#ffffff` | cards, panels, **lifted chat content column** |
| `surface-2` | `#16171b` | `#f0f1f4` | agent bubbles, hovered/featured cards, settings rows on lifted surfaces |
| `surface-3` | `#1d1f24` | `#e8eaee` | user bubbles, active nav item, sub-nav |
| `surface-4` | `#25272d` | `#dfe1e7` | deepest lifted surface, toggles-off |
| `hairline` | `#23252a` | `#e4e5ea` | default 1px borders, dividers |
| `hairline-strong` | `#33363d` | `#cfd2d9` | input focus borders, featured cards |
| `hairline-tertiary` | `#1a1c20` | `#eceef1` | nested-surface borders |

### Accent (green — scarce)

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| `primary` | `#4cb782` | `#1f9d63` | primary CTA fill, active states, focus |
| `primary-hover` | `#63d29c` | `#38b27f` | hovered CTA, active-nav glyph, presence |
| `primary-focus` | `#4cb782` | `#1f9d63` | focus ring (2px @ 50% opacity) |
| `on-primary` | `#04130b` | `#ffffff` | content on a green fill |
| `brand-mark` | `#4ADE80` | `#4ADE80` | the `makit` logo mark + connection dot (decorative, both modes) |

> Light mode darkens `primary` to `#1f9d63` so white `on-primary` text keeps
> ≥4.5:1 contrast; the bright brand-mark green `#4ADE80` stays decorative only.

### Ink

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| `ink` | `#f7f8f8` | `#0b0d0f` | headlines, primary text/icons |
| `ink-muted` | `#d0d6e0` | `#3c4149` | secondary text |
| `ink-subtle` | `#8a8f98` | `#6b7280` | tertiary text, meta, deselected |
| `ink-tertiary` | `#62666d` | `#9aa0a8` | disabled, footnotes, line numbers |

### Semantic & status

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| `success` | `#27a644` | `#1f9d57` | success pills, "done", cert-pinned, diff `+` |
| `tool-risky` | `#E8A33D` | `#E8A33D` | tool-call *risky* icon / status dot |
| `tool-destructive` | `#E5544B` | `#E5544B` | tool-call *destructive* icon, diff `−` |

Status-dot palette (session state): running `tool-risky`-adjacent amber,
awaiting `primary-hover`, done `success`, idle `ink-tertiary`, error
`tool-destructive`. Keep muted — risk affordances sit *with* the surfaces, not
shouting.

---

## 3. Typography

makit ships **two type scales**: a **landing/marketing** scale (large hero
display) and the **product (dashboard/chat) scale** used by the app itself. The
values below are the **product scale** — dense and information-first, anchored
at a **13px body**. (The marketing scale — display 40–56, body 16 — lives only
in landing pages, never in the client.)

- **Display / Text:** system font — SF Pro on Apple platforms; **Inter**
  (500/600/700) is the cross-platform substitute.
- **Mono:** `ui-monospace` / SF Mono; **JetBrains Mono** as substitute. Code,
  diffs, IDs, repo paths only.
- Titles carry **negative tracking** (-0.1 at 13px → -0.4 at 24px); body holds
  ≈-0.05px. Tiny meta (`caption`) gets **positive** tracking (+0.2px) for
  legibility.
- Titles weight 600, body 400, labels 500 — resist heavier display weights at
  these small sizes.
- Body is **13px**, line-height ~1.45. A dashboard rarely needs hero type, so
  `display`/`headline` stay small (20–24px).

| Role | Material slot | Size / weight | Track | Use |
|------|---------------|---------------|-------|-----|
| display | `displaySmall` | 24 / 600 | -0.4 | empty-state hero (rare) |
| headline | `headlineSmall` | 20 / 600 | -0.3 | screen / onboarding hero |
| title-lg | `titleLarge` | 17 / 600 | -0.3 | dialog & settings titles |
| title | `titleMedium` | 15 / 600 | -0.2 | card / section titles |
| subtitle | `titleSmall` | 13 / 600 | -0.1 | row / pane titles, session name |
| body-lg | `bodyLarge` | 14 / 400 | -0.1 | emphasized body |
| **body** | `bodyMedium` | **13 / 400** | -0.05 | default text, chat |
| body-sm | `bodySmall` | 12 / 400 | 0 | secondary text, previews, meta |
| button | `labelLarge` | 13 / 500 | -0.1 | button labels |
| label | `labelMedium` | 12 / 500 | 0 | small controls |
| caption | `labelSmall` | 11 / 500 | +0.2 | timestamps, status, footnotes |
| mono | — | 12–13 / 400 | 0 | code, diffs, IDs, paths |

---

## 4. Spacing, radius, layout

- **Base unit 4px.** Tokens: `xxs 4 · xs 8 · sm 12 · md 16 · lg 24 · xl 32 · xxl 48`.
- **Product density is tighter than the landing page.** In the dashboard/chat
  client: card / group padding `sm 12`–`md 16` (landing uses `lg 24`); button
  padding `8×14`; input padding `9×10`; compact list rows ~30–34px high.
- **Radius:** `xs 4` (chips/badges) · `sm 6` (tags) · `md 8` (**buttons, inputs,
  tabs, segmented knobs**) · `lg 12` (**cards, dialogs, menus**) · `xl 16`
  (screenshot/phone/window frames) · `pill 9999` (status pills, toggles) ·
  `full 9999` (avatars). **Never pill-round CTAs.**
- Desktop content max ~1280px; readable chat column capped ~720px.

### Chat transcript tokens (from `app/lib/ui/session/chat_metrics.dart`)

The transcript is **gutter-agnostic**: item widgets carry no horizontal padding;
the surface (mobile `SessionScreen`, desktop `DesktopChatPane`) applies one
gutter + inter-row gap via `transcriptRow`.

| Token | Value | Role |
|-------|-------|------|
| `kChatGutter` | 20 | horizontal inset, applied once by the surface |
| `kChatRowGap` | 10 | space between adjacent rows |
| `kChatRadiusSmall` | 8 | code blocks |
| `kChatRadiusMedium` | 12 | tool cards, error banners |
| `kChatRadiusLarge` | 16 | message bubbles |

---

## 5. Elevation & depth

Depth is carried by the surface ladder + 1px hairlines. **Dark mode uses no drop
shadows;** light mode adds a soft shadow (`0 1px 2px` + `0 8px 24px`, low alpha)
to lift cards/frames off the off-white canvas. A subtle 1px white top-edge
highlight (`inset 0 1px 0 rgba(255,255,255,.04)`) gives dark lifted panels a
faint rendered feel.

**Desktop chrome is darker than content, in both modes:**

- Sidebar + topbar → `canvas` (recessed chrome).
- Chat content column → `surface-1` (lifted).
- Settings rows on a lifted content column bump to `surface-2` for contrast.

This holds in dark (canvas `#010102` < surface-1 `#0c0d10`) and light
(canvas `#f7f8fa` < surface-1 `#ffffff`).

---

## 6. Components

### Buttons
- `button-primary` — green fill (`primary`), `on-primary` text, `md 8` radius,
  padding `8×14`. Hover → `primary-hover`.
- `button-secondary` — `surface-1` fill, `ink` text, 1px `hairline`.
- `button-tertiary` — transparent, `ink-muted` text.

### Cards & lists
- `card` / `feature-card` — `surface-1`, 1px `hairline`, `lg 12` radius, `lg 24` padding.
- `project-card` — name (`card-title`), mono repo path (`ink-subtle`), meta row,
  status pill.
- `session-row` — mono agent avatar tile, title + timestamp, 1-line preview,
  status badge; `hairline` bottom rule between rows.
- `status-badge` — `surface-2` fill, `ink-muted`, `pill` radius, leading state dot.

### Chat
- **User bubble** — `surface-3`, `ink`, 1px `hairline`, right-aligned. **Never accent.**
- **Agent bubble** — `surface-2`, `ink`, left-aligned; thinking = muted italic.
- **Tool card** — `surface-1` + `hairline`, `md 8`; mono header with a 1-line
  summary and `+n`/`−n` diff counts (green `+` / red `−`). Collapsed by default;
  expands to a mono body / opens a fullscreen (mobile) or right-pane (desktop) diff.
- **Approval banner** — `surface-2` + `hairline-strong`, `lg 12`; leading
  `primary-hover` dot, mono command, Deny (secondary) + Approve (primary) row.
- Busy indicator = a shimmering work-flavoured word, shared by mobile + desktop.

### Composer
- `surface-1` input, 1px `hairline`, `md 8`; focus ring 2px `primary-focus` @ 50%.
- Green send button (`primary`), fades in only when non-empty.
- Quick-action chips above the field when awaiting input/approval; `/` slash and
  `@` mentions; 🎙 hold-to-talk.
- 1-line at rest → grows on focus.

### Inputs & settings
- `text-input` — `surface-1`, `ink`, `md 8`, padding `8×12`.
- Setting rows — `surface-1` (or `surface-2` on lifted content), leading icon
  tile, name + value/toggle. Toggle on = `primary`, off = `surface-4`.
- Radio/policy options — selected option is the **only** green-accented row.

### Navigation
- **Mobile:** bottom tab bar (Projects · Devices · Settings); active tab uses
  `primary-hover`.
- **Desktop:** left sidebar (projects → sessions tree) on `canvas`; active nav
  item `surface-3` with `primary-hover` glyph.

### Desktop title bars

The desktop pane column stacks two title rows with deliberate hierarchy:

- **Window title strip** (`_WorktreeTitle`) — worktree/branch as a quiet
  **muted, letter-spaced context label** (`labelMedium`, `outline`, `w600`,
  `letterSpacing 0.8`) with a leading `gitBranch` icon (case preserved).
- **Pane title** (`_PaneHeaderStrip`) — session name as the **primary** line
  (`titleSmall`, `w500`, `onSurface`) with a leading `SessionStatusDot`, then
  session-actions + close-pane controls.
- A **1px hairline** separates the window-title zone from the pane header below.
- Leading edges align at the pane gutter.

`SessionStatusDot` (`desktop/chat/session_status_dot.dart`) is shared by sidebar
tiles and the pane header so a session's status reads identically everywhere.

---

## 7. Liquid Glass — iOS only

On **iOS**, the floating **top bar** and **composer** use Liquid Glass instead of
flat surfaces. This is the one place the "no atmospherics" rule is lifted.
Implemented in `app/lib/ui/widgets/glass.dart` (`GlassSurface`), backed by the
`liquid_glass_renderer` shader; `fakeGlassProvider` swaps to a cheap
backdrop-blur fallback. **All other platforms/surfaces stay flat.**

| Param | Value | Notes |
|-------|-------|-------|
| tint (light) | `#FFFFFF` @ 50% → `0x80FFFFFF` | legible, not milky |
| tint (dark) | `#181818` @ 50% → `0x80181818` | neutral, not blue |
| blur | 18 | frost strength |
| saturation | 1.8 | anti-"milky" lever — pops refracted colour |
| lightIntensity | light `0.9` / dark `0.5` | keep light ≤ ~1.0 |
| ambientStrength | light `0.3` / dark `0.2` | |
| refractiveIndex | 1.3 | subtle liquid bend |
| border | 1px white @ `0.35` (light) / `0.14` (dark) | edge highlight |
| shadow | `0 8 24`, black @ `0.15` | depth |
| radius | 26 (bars) / 28 (composer) | |

Glass chrome still follows the accent rule: the connection dot and send button
are green; the mark is `brand-mark` green.

---

## 8. Contrast (WCAG)

- Dark: `ink #f7f8f8` on `canvas #010102` ≈ 18:1 ✓ · `ink-subtle #8a8f98` ≈ 5.4:1 ✓
  · white `on-primary` guidance N/A (dark on-primary used).
- Light: `ink #0b0d0f` on `canvas #f7f8fa` ≈ 18:1 ✓ · `ink-subtle #6b7280` ≈ 4.9:1 ✓
  · white `on-primary` on `primary #1f9d63` ≈ 4.6:1 ✓.
- CTAs hold ≥40px tap height; pills ≥36px (≥44px on touch); inputs ≥44px on touch.

---

## 9. Do's & Don'ts

**Do**
- Reserve `canvas` as the anchor floor (the faint blue tint in dark is intentional).
- Use green ONLY for: brand mark, primary CTA, focus ring, active nav, send, status dots.
- Use the four-step ladder for hierarchy; don't skip levels.
- Keep desktop sidebar/topbar darker than the chat content in both modes.
- Pair display 600 with body 400; apply negative display tracking.

**Don't**
- Don't put the accent on chat bubbles (user bubbles are `surface-3`).
- Don't introduce a second chromatic accent.
- Don't add atmospheric gradients or spotlight cards on flat surfaces.
- Don't use Liquid Glass anywhere except the iOS top bar + composer.
- Don't pill-round CTAs. Don't use `#000000` canvas or a pure-white page floor.

---

## Responsive

| Breakpoint | Width | Key change |
|------------|-------|------------|
| Desktop | ≥1024px | 3-pane desktop layout (sidebar · chat · detail) |
| Tablet | 768–1024px | card grids 3-up → 2-up |
| Mobile | <768px | single column; bottom tab bar; nav hamburger |

Product/diff panels keep aspect ratio and never crop.
