# Losing the Chrome — Flutter Desktop Window Managers for a Titlebar-less, Beautiful macOS UI

> **Research question:** Which window-management approach gives us a "NO titlebar"
> Flutter desktop window (macOS-first, Windows/Linux welcome) with the **least
> plumbing**, the **best native look**, and acceptable **performance** and
> **supply-chain risk**?
>
> **TL;DR recommendation:** Keep the `window_manager` we already ship and switch
> it to `TitleBarStyle.hidden`, then add **`macos_window_utils`** for the native
> transparent-titlebar + full-size-content + vibrancy look. Skip the newer
> `icefelix_window_manager` for now (immature, AI-authored native code, and it
> only does *frameless*, not native chrome polish).

---

## 0. Current state of this repo

- `app/pubspec.yaml` already depends on `window_manager: 0.5.2` (leanflutter,
  pinned exactly).
- `app/lib/desktop/desktop_app.dart` currently sets
  `titleBarStyle: TitleBarStyle.normal` — i.e. we ship the stock gray macOS
  titlebar today.
- `app/macos/Runner/MainFlutterWindow.swift` is the unmodified Flutter template.

So the machinery to hide the titlebar is **already installed** — we simply
aren't using its titlebar-hiding mode yet.

---

## 1. A note on "performance"

Hiding a titlebar is a **one-time native window configuration at launch**
(setting `styleMask`, `titlebarAppearsTransparent`, `titleVisibility`,
`fullSizeContentView` on the `NSWindow`, or the platform equivalents). None of
the options below add per-frame or runtime overhead — there is no measurable
FPS difference between them.

The real decision axes are therefore:

1. **Plumbing** — how much code/config to wire up.
2. **Platform coverage** — macOS only vs. cross-platform.
3. **Native feel / beauty** — transparent titlebar + retained stoplights +
   vibrancy vs. a bare frameless rectangle.
4. **Supply-chain risk** — native code is a large blast radius (see
   `app/SECURITY.md` / the pinning policy in `pubspec.yaml`).

The most "native/performant" options are the ones that talk directly to the
platform window (`macos_window_utils` or a raw Swift edit); they bypass any
Dart↔platform chatter after startup.

---

## 2. The candidates

### 2.1 `window_manager` (leanflutter) — *already shipped*

- **Platforms:** macOS / Windows / Linux.
- **Plumbing:** Lowest — a **one-line** change.
- **How to hide the titlebar:**
  ```dart
  const options = WindowOptions(
    // ...
    titleBarStyle: TitleBarStyle.hidden, // was TitleBarStyle.normal
  );
  ```
  On macOS the traffic-light buttons stay (as desired), the title text/bar
  disappears, and content extends upward. You then add a `DragToMoveArea` for
  the top strip.
- **Beauty:** Good, but traffic-light layout control is coarse.
- **Maturity:** Very high — ~470k downloads, 1.1k likes, used by RustDesk,
  BlueBubbles, Ubuntu Desktop Installer, etc. We already trust it.
- **Caveat:** The package is migrating to a new C++ core
  (`libnativeapi/nativeapi-flutter`). Still works fine; factor into long-term
  bets.

### 2.2 `macos_window_utils` (macosui.dev) — *the beauty path*

- **Platforms:** macOS only.
- **Plumbing:** Low–medium (a few Dart calls + a tiny Swift change only on
  Monterey-and-older).
- **How to get the native transparent titlebar:**
  ```dart
  await WindowManipulator.initialize();
  WindowManipulator.makeTitlebarTransparent();
  WindowManipulator.enableFullSizeContentView();
  // optional native vibrancy behind a sidebar:
  WindowManipulator.setMaterial(NSVisualEffectViewMaterial.windowBackground);
  ```
  Wrap the app (or parts) in `TitlebarSafeArea`, and wrap a sidebar in
  `TransparentMacOSSidebar` for real macOS blur / wallpaper-tinting.
- **Beauty:** **Best.** Transparent titlebar, full-size content view, vibrancy
  materials, show/hide/reposition traffic lights, shadow control, style-mask
  control, `NSWindowDelegate` events. This is the "Spotify / Linear / native
  Mac app" look.
- **Maturity:** High — made by the `macos_ui` team, ~92k downloads, actively
  maintained, MIT.
- **Composes cleanly with `window_manager`** (keep `window_manager` for
  sizing/position/show-focus).

### 2.3 Pure Swift edit — *zero dependency*

- **Platforms:** macOS only.
- **Plumbing:** Medium (hand-written), but **no package**.
- **How:** in `MainFlutterWindow.swift`:
  ```swift
  self.titlebarAppearsTransparent = true
  self.titleVisibility = .hidden
  self.styleMask.insert(.fullSizeContentView)
  ```
  Multiple sources confirm this is often all you need on macOS.
- **Beauty:** Full control, but you write everything yourself.
- **Maturity:** N/A — no third-party code, smallest possible blast radius.

### 2.4 `icefelix_window_manager` (icefelix.com) — *modern but immature*

- **Platforms:** macOS 10.15+ (Swift/AppKit), Windows 10+ (C++/Win32), Linux
  X11+Wayland (GTK3) — all in **one** package (was federated in 0.2.x, collapsed
  to monolithic in 0.3.0).
- **Category:** Same as `window_manager` (size/position/state/frameless/events)
  — **not** a native-chrome beautifier like `macos_window_utils`.
- **How to hide the titlebar:**
  ```dart
  await WindowManager.instance.setFrameless(true);
  ```
  This strips the **whole** frame — including the macOS traffic lights. There is
  **no** transparent-titlebar-with-stoplights mode, and **no** vibrancy/material
  API. It solves "remove chrome," not "look like a native Mac app."
- **Genuinely modern design:**
  - **Pigeon-typed** platform channel (type-safe, codegen'd).
  - Reactive `ValueListenable<WindowSnapshot>` as single source of truth.
  - **Dart 3 sealed events** with exhaustive pattern matching
    (`WindowResizeEvent`, `WindowCloseRequestEvent` with working
    `preventDefault`).
  - Novel `setShape()` for non-rectangular / polygon windows.
  - 72 unit tests + integration tests on real `NSWindow`; 160/160 pana.
- **Maturity / supply-chain flags (decisive for this repo):**
  - **v0.5.0**, published ~5 weeks before this writing.
  - ~**70 downloads**, **5 likes**, **7 GitHub stars**, **1 maintainer**.
  - Commits are **co-authored by "Claude Opus"** — the native Swift / C++ /
    Win32 code is largely AI-generated.
  - Churned hard recently (federated → monolithic; macOS-only → +Windows →
    +Linux, all within ~2 months). Pre-1.0, API/packaging still settling.
  - Our `pubspec.yaml` explicitly pins native plugins *exactly* because
    *"native code = supply-chain blast radius."* A ~70-download, largely
    AI-authored native plugin is precisely what that policy warns against.

### 2.5 `bitsdojo_window` — *dated*

- **Platforms:** macOS / Windows / Linux.
- **Plumbing:** High — you rebuild custom min/max/close chrome.
- **Beauty:** Dated; less maintained than the above.
- **Verdict:** Not worth it given the alternatives.

---

## 3. Comparison

| Rank | Option | Plumbing | Beauty (native Mac feel) | Platforms | Maturity / risk |
|:---:|---|---|---|---|---|
| **1** | **`macos_window_utils`** | Low | **Best** — transparent titlebar, full-size content, vibrancy, movable stoplights | macOS | High (macos_ui team, ~92k dl) |
| **2** | **`window_manager`** (`TitleBarStyle.hidden`) — *already installed* | **Lowest** (1 line) | Good | macOS/Win/Linux | High (~470k dl, already trusted) |
| **3** | **Pure Swift edit** (no dep) | Medium | Full control | macOS | N/A — zero dependency |
| **4** | **`icefelix_window_manager`** | Low | Frameless only, no native chrome polish | macOS/Win/Linux | **Low** — new, ~70 dl, AI-authored native code |
| **5** | `bitsdojo_window` | High | Dated | macOS/Win/Linux | Medium, less maintained |

---

## 4. Recommendation

Because our desktop app is **macOS-first** (SPEC-03) and we want it *beautiful*,
use a **hybrid**:

1. **Keep `window_manager`** for sizing/position/show-focus (already wired in
   `desktop_app.dart`) and switch `TitleBarStyle.normal` → `TitleBarStyle.hidden`.
2. **Add `macos_window_utils`** for the native transparent titlebar +
   full-size content + optional vibrancy. It composes cleanly with
   `window_manager`.

Expected cost: ~15 lines of Dart, one small Swift edit, plus a `TitlebarSafeArea`
wrapper and a `DragToMoveArea` for the top strip.

If we ever want to stay strictly dependency-minimal, the **pure Swift edit**
(§2.3) plus `TitleBarStyle.hidden` achieves the titlebar removal with zero new
packages, at the cost of doing the native polish by hand.

**Do not adopt `icefelix_window_manager` now** — it doesn't deliver the
native-Mac look we're after (frameless ≠ transparent-titlebar-with-stoplights),
and its immaturity + AI-authored native code conflicts with our supply-chain
discipline. Worth revisiting after it reaches 1.0 with real adoption.

---

## 5. Sources

- `window_manager` — <https://pub.dev/packages/window_manager>
- `macos_window_utils` — <https://pub.dev/packages/macos_window_utils>
- `icefelix_window_manager` — <https://pub.dev/packages/icefelix_window_manager>
  and <https://github.com/ICE-Felix/icefelix-window-manager>
- "Hide title bar on macOS with Flutter" (George Herbert) —
  <https://medium.com/flutter-community/transparent-title-bar-on-macos-with-flutter-7043d44f25dc>
- "Flutter vs. macOS: The Title Bar Battle" (Hart and Vine) —
  <https://hartandvine.com/insights/flutter-vs-macos-the-title-bar-battle/>
