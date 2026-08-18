# SPEC-desktop-settings-rework — Desktop Settings rework (M3 two-pane, searchable, immediate-effect)

**Status:** Implemented (this PR) — the original design plan is retained below for reference · **Depends on:** SPEC-desktop-control-app (desktop control app), SPEC-desktop-chat-app (desktop chat app), SPEC-desktop-sidebar-topbar-restructure (sidebar/topbar restructure)
**Roadmap:** realizes milestone **M4** ("real settings window" + macOS control-app UX/UI polish) from `docs/specs/README.md`.
**Scope:** **desktop / macOS only.** The mobile settings screen (`app/lib/ui/settings/settings_screen.dart`) and mobile notification section are **out of scope** for this spec and left untouched.

---

## Goal

Replace the desktop app's ad-hoc "Settings & Server" surface with a single,
modern **Material 3 two-pane Settings window** that is fast, searchable, and
fully configurable. Today's settings are spread across three unrelated places
and conflate *operational control*, *connection config*, and *true
preferences*:

- `_SettingsServerPage` → `DesktopDashboard`: a `NavigationRail` of **Devices /
  Pair QR / Sessions / Status / Server** plus a header with **Start/Stop/Restart**
  daemon controls (`app/lib/desktop/desktop_app.dart`).
- `KeymapSettingsScreen`: keyboard shortcuts (`app/lib/desktop/settings/keymap_settings_screen.dart`).
- `ServerSettingsScreen`: host/port with an explicit **Save** button
  (`app/lib/desktop/settings/server_settings_screen.dart`).
- Theme is hardcoded `ThemeMode.system` — no user control.

The rework unifies all of this into one **two-pane Settings** experience and
establishes a **preferences architecture** the app currently lacks.

**Explicit decision (this spec):** *Everything* lives in Settings — including
operational server control (start/stop), device pairing/management, and live
sessions/status. Settings is the single home for both configuration and
control.

## Consensus decisions (source of truth)

These are locked answers gathered before design; they override anything below
if they conflict.

1. **Scope = desktop/macOS only** for this pass. Mobile settings are a later
   spec.
2. **Total rework**, not a reshuffle of the existing widgets. The current
   `DesktopDashboard`, `ServerSettingsScreen`, `KeymapSettingsScreen`, and
   `_SettingsServerPage` are replaced/absorbed.
3. **Everything lives in Settings** — operational control (Start/Stop/Restart),
   Devices, Pair-QR, live Sessions, and Status are sections *inside* the new
   Settings, not a separate dashboard.
4. **Two-pane, M3, minimalistic.** Left = section list; right = section detail.
5. **Fast open, no animation, resume last position.** Opening Settings shows
   instantly (no page transition); the previously selected section is restored.
6. **Searchable** across section + item labels/keywords/help.
7. **Every item is self-explanatory** — tooltip/help text and/or a visual
   selector on each item.
8. **Immediate effect** — no Save button anywhere; every change applies at once.
9. **Show values changed from default** — a per-item "modified" badge + reset.
10. **Top-caliber & highly configurable** — reserve forward-looking sections
    now (rendered as "coming soon" or hidden) so the taxonomy is stable.

## Non-goals (explicit YAGNI)

- **No mobile changes.** `app/lib/ui/settings/**` untouched.
- **No new backend/protocol.** `[future]` items that would need server support
  (agent config sync, telemetry, software update) are **placeholders only** —
  shown disabled/"coming soon", wired to nothing. This spec ships the
  *architecture* + the `[now]`/`[new]` leaves.
- **No settings that don't yet have a real effect.** A `[new]` leaf ships only
  if it drives real behavior (e.g. Theme actually switches `themeMode`). Purely
  speculative controls stay `[future]` placeholders.
- **No animated pane transitions.** Section switches are instant rebuilds.

---

## Section taxonomy (8 top-level sections)

Left pane lists the 8 sections. Right pane renders that section's subsections
and items. Leaf tags: **[now]** = code exists today, **[new]** = small wire-up
to real behavior, **[future]** = reserved placeholder (disabled / "coming
soon").

### 1. General
- Startup — launch at login, restore last window/session `[future]`
- Language & region `[future]`
- Software update — channel, check for updates `[future]`

### 2. Appearance
- **Theme** — System / Light / Dark `[new]` (today hardcoded `ThemeMode.system`)
- Accent color `[future]`
- **Text & code** — UI text scale; **monospace code font** `[new]`
  (complements the code-font fallback fix in `chat_message.dart`)
- **Layout** — density; default **sidebar width**; **start collapsed** `[new]`
  (persists `sidebarWidthProvider` / `sidebarCollapsedProvider`, today in-memory)
- Chat rendering — markdown on/off, code highlight theme, show timestamps `[new]`

### 3. Agents & Chat
- Default agent & model `[future]`
- Per-agent config — binary path, API-key location `[future]`
- Approval & permissions policy `[future]`
- Composer — send-on-Enter vs ⌘-Enter `[future]`

### 4. Server & Devices
- **Endpoint** — host / port `[now]` (`ServerConfigController`)
- **Lifecycle** — Start / Stop / Restart; autostart `[now]` (daemon header)
- **CLI** — resolved path; copy install command `[now]` (`CliMissingBanner`)
- **Paired devices** — list + revoke `[now]` (`DevicesScreen`)
- **Pair new device** — QR `[now]` (`QrScreen`)
- **Running sessions** `[now]` (`SessionsScreen`); history & cleanup `[future]`
- **Fingerprint / TLS trust** `[now]`

### 5. Notifications
- Local notifications, background wake `[now]` (desktop reminder policy)
- Per-type mute, approval reminders `[future]` (today's "Coming soon")

### 6. Shortcuts
- Chat scope / Window scope `[now]` (`keymapProvider`, rebind + reset)

### 7. Advanced
- Developer — **fake server toggle**, logs / diagnostics `[new]`
- Status — pid, uptime, protocol version `[now]`
- Telemetry `[future]`
- **Reset all settings** `[new]`

### 8. About
- Version, protocol, links `[now]`
- **Unpair this device** (danger) `[now]`

---

## Architecture

Three new seams: a **preferences store**, a **settings registry** (metadata +
search index), and the **two-pane shell**. Operational controls (server
lifecycle, devices, sessions) are embedded as section bodies that reuse
existing widgets/providers — they are *not* modeled as preferences.

### A. Preferences store (generalize the keymap pattern)

`KeymapController` already does exactly what we want, per-feature: keep the
**defaults in code**, persist **only the diffs** as JSON in
`SharedPreferences`, and derive reset/modified from the base. Generalize it.

```text
lib/desktop/settings/prefs/
  preference.dart          // PreferenceEntry<T>: id, defaultValue, codec
  preferences_controller.dart  // reads/writes SharedPreferences, diff-only
  preferences_providers.dart   // Riverpod providers per entry + "isModified"
```

- `PreferenceEntry<T>` declares a stable `id`, a `defaultValue`, and a JSON
  codec. Entries live in a central list (also feeds the registry, §B).
- The controller stores a single JSON map `{ id: encodedValue }` containing
  **only entries whose value != default** (same philosophy as
  `kKeymapPrefsKey`). Setting a value == default removes the key.
- Requirement **#8 (immediate effect):** every setter writes through
  immediately and updates the provider; no staging/Save.
- Requirement **#9 (modified badge):** `isModified(entry) == store.contains(id)`
  — trivially derived because we only persist diffs.
- Per-item **reset** removes the key; **Reset all** clears the user-facing
  overrides while preserving internal bookkeeping entries such as
  `settings.lastSection` (Advanced §7).
- Keymap and server host/port keep their existing dedicated controllers but are
  surfaced through the same registry (they already store diffs / their own
  keys); we do **not** force-migrate their storage.

### B. Settings registry (metadata + search index)

A declarative list of section → subsection → item descriptors. Each **item**
carries:

- `id`, owning `section`, `subsection`
- `title`, `help` (tooltip/long description) — requirement **#7**
- `keywords` for search — requirement **#6**
- `control`: one of the render kinds below
- `availability`: `now | comingSoon` (drives disabled/"coming soon" chrome)

**Control kinds** (the "visual selector" for #7, immediate-apply for #8):
- `SwitchControl` (bool)
- `SegmentedControl` (small enum, e.g. Theme System/Light/Dark)
- `DropdownControl` (larger enum, e.g. code highlight theme)
- `SliderControl` (double, e.g. text scale, sidebar width)
- `TextFieldControl` (string/int, e.g. host/port — validated, applied on commit)
- `ActionControl` (button, e.g. Start/Stop/Restart, Reconnect, Copy install)
- `InfoControl` (read-only, e.g. pid/uptime/protocol/fingerprint)
- `NavControl` (opens an embedded list body, e.g. Shortcuts, Devices, Sessions)

The registry is the single source of truth for both **rendering** and the
**search index**. Adding a setting = adding one descriptor (+ a
`PreferenceEntry` if it's a stored pref).

### C. Two-pane shell (requirements #4, #5)

```text
lib/desktop/settings/
  settings_window.dart      // the 2-pane Scaffold (replaces _SettingsServerPage)
  settings_nav_pane.dart    // left: section list + search field
  settings_detail_pane.dart // right: selected section body (registry-driven)
  sections/…                // one body widget per section (embeds existing widgets)
```

- **Layout:** `Row(left nav ~260px, VerticalDivider, Expanded(detail))`. Matches
  the existing desktop chat shell idiom (`desktop_chat_shell.dart`).
- **Fast open, no animation (#5):** open Settings by swapping the shell body /
  showing an in-window panel — **not** a `MaterialPageRoute` push (today's
  `_openSettings` pushes a route with a transition). No `PageTransition`.
- **Resume last position (#5):** the selected section id is itself a stored
  preference (`settings.lastSection`), so closing and reopening restores the
  same spot. Scroll offset restoration within the detail pane is best-effort via
  a `PageStorageKey` per section.
- **Search (#6):** a search field atop the left pane filters the registry by
  title/keywords/help across *all* sections; results render as a flat list that
  deep-links to the item (scrolls the detail pane to it and briefly highlights).

### D. Modified/reset affordances (#9)

- Each stored item shows a subtle "Modified" dot/badge when
  `isModified(entry)`, with an inline **Reset** (↺) affordance (mirrors the
  keymap row's per-action reset icon).
- Each section header shows a count of modified items; **Advanced → Reset all**
  clears every user-facing override (internal bookkeeping such as
  `settings.lastSection` is preserved) after a confirm dialog.

---

## Migration map (requirements #2, #3 — the "bold move")

Every existing surface gets a home; nothing is dropped.

| Existing (today) | New home | Change |
|---|---|---|
| `ServerSettingsScreen` (host/port + **Save**) | **Server & Devices → Endpoint** | Drop the Save button; apply on field commit (validated). Keep Save-&-restart as an `ActionControl`. |
| Daemon header Start/Stop/Restart | **Server & Devices → Lifecycle** | `ActionControl`s + status line. |
| `CliMissingBanner` / install command | **Server & Devices → CLI** | Show resolved path; "Copy install command" action. |
| `DevicesScreen` | **Server & Devices → Paired devices** | Embedded via `NavControl`; reuse widget. |
| `QrScreen` | **Server & Devices → Pair new device** | Embedded; reuse widget. |
| `SessionsScreen` | **Server & Devices → Running sessions** | Embedded; reuse widget. |
| `StatusScreen` (pid/uptime/protocol) | **Advanced → Status** | Read-only `InfoControl`s. |
| Fingerprint copy | **Server & Devices → Fingerprint / TLS** | `InfoControl` + copy action. |
| `KeymapSettingsScreen` | **Shortcuts** | Embedded list; existing rebind/reset dialogs unchanged. |
| Notification permission/wake (desktop reminder policy) | **Notifications** | Reuse the reminder-delay knob; per-type mute is `[future]`. |
| Theme (hardcoded `ThemeMode.system`) | **Appearance → Theme** | **New** stored pref drives `MaterialApp.themeMode`. |
| `sidebarWidthProvider` / `sidebarCollapsedProvider` (in-memory) | **Appearance → Layout** | Back with prefs so they persist (SPEC-desktop-sidebar-topbar-restructure left this as a deliberate seam). |
| Fake-server toggle | **Advanced → Developer** | Surface existing `useFake` path. |
| App/version/protocol/links | **About** | `InfoControl`s + links. |
| Unpair | **About → Unpair (danger)** | Existing `unpair()` flow. |

---

## Testing (TDD — red → green → refactor)

- **Preferences store:** diff-only persistence (set==default removes key; set!=default stores; `isModified` reflects the map; reset removes; reset-all clears). Pure unit tests, no widget.
- **Registry/search:** query matches by title/keyword/help; disabled/`comingSoon` items excluded from being toggled but shown in results.
- **Shell:** `settings_window` renders the last-selected section on open; selecting a section persists `lastSection`; no `MaterialPageRoute` is pushed (open is in-window).
- **Theme wire-up:** changing the Theme pref flips `MaterialApp.themeMode` (widget test).
- **Layout persistence:** sidebar width/collapsed survive a controller reload.
- **Regression:** existing keymap tests (`keymap_controller` / settings screen) and server-config tests keep passing; embedded Devices/Sessions/QR widgets still render.

Gate (from `docs/specs/README.md`): `flutter analyze --fatal-infos` clean;
`app/tool/audit.sh` passes. (Use the repo/CI Flutter toolchain; do not hard-code
a machine-specific Flutter path.)

## Suggested phasing (implementation, later)

1. **Prefs store + registry** (pure Dart, fully tested) — no UI yet.
2. **Two-pane shell** (nav + detail + search + resume), replacing `_openSettings`
   to open in-window; wire the first real leaf (**Theme**) end-to-end.
3. **Migrate Server & Devices** (Endpoint immediate-apply, Lifecycle, CLI,
   embed Devices/QR/Sessions, Fingerprint) — retire `ServerSettingsScreen` +
   `DesktopDashboard`/`_SettingsServerPage`.
4. **Migrate Shortcuts, Notifications, Advanced (Status/Developer/Reset-all),
   About**; back sidebar layout prefs.
5. **Appearance polish** (text scale, code font, chat rendering) + `[future]`
   placeholders (General, Agents & Chat, Accent, Telemetry) as disabled rows.

## Open questions (please confirm during planning)

1. **Open surface:** Settings as a full-window body swap inside the existing
   desktop window (recommended, matches "no animation / resume spot"), or a
   separate native window? Assumed: **in-window body swap**.
2. **Left-pane style:** flat section list (recommended) vs. `NavigationRail`
   with icons. Assumed: **list with leading icons**, ~260px.
3. **`[future]` visibility:** show reserved sections as visible-but-disabled
   ("Coming soon"), or hide until built? Assumed: **General / Agents & Chat and
   the `[future]` leaves render disabled with a "coming soon" tag** so the
   taxonomy is discoverable.
4. **Notifications on desktop:** confirm the desktop-relevant knobs (reminder
   delay, per-session mute) — the mobile permission model doesn't fully apply.
