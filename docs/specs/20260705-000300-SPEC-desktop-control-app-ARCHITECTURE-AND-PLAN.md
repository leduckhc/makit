# SPEC-desktop-control-app Architecture & Parallel Implementation Plan

**Status:** done — Phase 1 merged (PR #11); Phase 4 merged (PR #16).
See [`20260705-000300-SPEC-desktop-control-app.md`](./20260705-000300-SPEC-desktop-control-app.md)
for the consensus scope. Note: v1 scope is **control-first** (start/stop/restart,
QR show+regen, devices revoke); session/log screens are a retained bonus. Native
SwiftUI was considered and **rejected** — we reuse the Flutter app.
**Depends on:** SPEC-daemon-control-plane (daemon control socket)
**Blocks:** —

---

## Architecture Overview

### Decision: Flutter Desktop (macOS) with Control-Plane Bridge

**Why reuse the Flutter app:**
- Session/chat UI already built + tested (7,942 LOC)
- Store/transport layer exists (chat, models, session state)
- Notifications infrastructure in place
- Single codebase: `flutter run -d macos` vs `flutter run -d ios`
- Desktop build skips mobile-only features (`Platform.isMacOS` gates)

**Why add a control-plane bridge:**
- Daemon lifecycle (start/stop) requires unix socket client
- QR/devices/status endpoints live in SPEC-daemon-control-plane daemon, not in the WS server
- Desktop app = control UI + session UI (two data flows)

```
┌─────────────────────────────────────────────────┐
│          Flutter macOS Desktop App              │
├──────────────────┬──────────────────────────────┤
│  Control Panel   │    Session View (shared)    │
│  (start/stop,    │    - Chat/tool UI           │
│   QR, devices)   │    - Store (Riverpod)       │
│                  │    - Transport (ws client)  │
├──────────────────┼──────────────────────────────┤
│      Darwin FFI  │         WebSocket            │
│      Unix Socket │      (wss://127.0.0.1)      │
│      Client      │                              │
└──────────────────┴──────────────────────────────┘
         ↓                      ↓
    ┌─────────────┐    ┌───────────────┐
    │  Daemon     │    │  WS Server    │
    │ (SPEC-daemon-control-plane)   │    │   (existing)   │
    │ - start     │    │ - sessions    │
    │ - stop      │    │ - logs        │
    │ - QR        │    │ - tools       │
    │ - devices   │    │ - models      │
    │ - status    │    │ - messages    │
    └─────────────┘    └───────────────┘
```

---

## Layering

### Layer 1: Control-Plane Socket Client (`lib/daemon/`)

**Responsibility:** Talk to the unix socket (SPEC-daemon-control-plane), wrap responses.

**New files:**
- `daemon/control_client.dart` — Dart FFI / `InternetAddress` binding to unix socket
- `daemon/models.dart` — Typed responses (`DaemonStatus`, `DeviceInfo`, `SessionInfo`)
- `daemon/provider.dart` — Riverpod providers for daemon state (current status, devices, sessions)

**Contract with SPEC-daemon-control-plane:**
- Reuse the protobuf/JSON schemas from `server/src/daemon/protocol.ts`
- All verbs: `server.start`, `server.stop`, `pair.current`, `pair.mint`, `devices.list`, `devices.revoke`, `status`, etc.

### Layer 2: Desktop-Specific UI (`lib/ui/desktop/`)

**Responsibility:** Menubar, QR panel, devices panel, sessions panel.

**New files:**
- `ui/desktop/main_window.dart` — Main window scaffold (tabs: QR, Devices, Sessions)
- `ui/desktop/qr_panel.dart` — QR display + Refresh button
- `ui/desktop/devices_panel.dart` — List + revoke
- `ui/desktop/sessions_panel.dart` — Live sessions + deep-link to session view
- `ui/desktop/menubar_item.dart` — macOS menubar presence via `tray_manager` or native `NSStatusItem` shell

### Layer 3: Shared App State (`lib/store/` — existing)

**No changes needed.** Desktop app reuses:
- `store/store.dart` — session/chat/models store
- `transport/ws_client.dart` — WS connection to `127.0.0.1:<port>`
- `notifications/` — policy, events

### Layer 4: Main Entry Point (`lib/main_desktop.dart` — new)

**Responsibility:** Separate bootstrap for desktop (no mobile-specific inits).

- Skip mobile plugins (camera, local_notifications init waits for user).
- Init daemon client + menubar.
- Boot WS client for session data.

---

## File Structure

```
app/
├── lib/
│   ├── main.dart (existing, mobile entry)
│   ├── main_desktop.dart (NEW)
│   ├── daemon/ (NEW)
│   │   ├── control_client.dart
│   │   ├── models.dart
│   │   ├── provider.dart
│   │   └── control_client_test.dart
│   ├── ui/
│   │   ├── desktop/ (NEW)
│   │   │   ├── main_window.dart
│   │   │   ├── qr_panel.dart
│   │   │   ├── devices_panel.dart
│   │   │   ├── sessions_panel.dart
│   │   │   └── menubar_item.dart
│   │   ├── home/ (existing)
│   │   ├── session/ (existing)
│   │   └── ...
│   ├── store/ (existing, shared)
│   ├── transport/ (existing, shared)
│   └── ...
├── macos/ (NEW or minimal tweaks)
│   ├── Runner.xcodeproj/
│   ├── Runner/
│   ├── Podfile
│   └── GeneratedPluginRegistrant.swift
└── pubspec.yaml (add tray_manager, etc.)
```

---

## Acceptance Criteria (Grouped by Task)

### Task 1: Control-Plane Socket Client
- [ ] `control_client.dart` connects to unix socket at `~/.makit/control.sock`
- [ ] Parses daemon responses (JSON or protobuf TBD)
- [ ] Riverpod providers expose `currentDaemonStatus()`, `pairedDevices()`, `currentPairToken()`
- [ ] Tests: mock socket responses, assert typed models, error handling (ECONNREFUSED)
- [ ] `pnpm test` + `flutter analyze` green

### Task 2: Menubar + Main Window
- [ ] Menubar item shows running/stopped state + device count + session count
- [ ] Click menubar → opens main window (or shows menu + open option)
- [ ] Main window: tabbed UI (QR | Devices | Sessions)
- [ ] **Start/Stop server** button: `server.start` / `server.stop` verbs, menubar updates in real-time
- [ ] Tests: verify buttons call the right verbs, state reflects changes
- [ ] `flutter analyze --fatal-infos` clean

### Task 3: QR Panel
- [ ] Display current pair QR (via `pair.current` → `qrcode` Dart package)
- [ ] Show URL + fingerprint
- [ ] **Refresh** button → `pair.mint` → renders new QR
- [ ] Countdown timer if TTL is present
- [ ] Copy URL button
- [ ] Tests: mock `pair.current` and `pair.mint`, assert QR renders, URL copied

### Task 4: Devices Panel
- [ ] List paired devices (label, last-seen, connected indicator)
- [ ] **Revoke** button per device → `devices.revoke <id>`
- [ ] Real-time refresh (poll `devices.list` or listen to daemon events)
- [ ] Tests: mock device list, verify revoke call, UI updates

### Task 5: Sessions Panel
- [ ] List live sessions (id, title, status, project, last activity)
- [ ] Click session → opens session view (reuse existing `session/` UI)
- [ ] Auto-refresh or event-driven
- [ ] Tests: mock session list, verify navigation

### Task 6: Notifications
- [ ] Native macOS notification on device paired event
- [ ] Native macOS notification on session finished/errored
- [ ] Reuse `notifications/notification_policy.dart` logic
- [ ] Manual test: pair a device, see notification

### Task 7: Integration & Desktop Build
- [ ] `flutter run -d macos` launches the app
- [ ] Mobile build still works: `flutter run -d ios`
- [ ] Both targets pass `flutter analyze --fatal-infos`
- [ ] No unintended platform-specific code in shared layers
- [ ] Manual smoke test: menubar works, QR pairs a device, sessions sync from phone

---

## Parallel Work Breakdown

**Dependency graph:**
```
TASK 1 (control-plane client)
  ↓ (blocks all UI tasks)
├→ TASK 2 (menubar + main window) [uses Task 1]
├→ TASK 3 (QR panel)             [uses Task 1]
├→ TASK 4 (devices panel)         [uses Task 1]
└→ TASK 5 (sessions panel)        [uses Task 1]

TASK 6 (notifications)            [independent, can start with existing notification infra]
TASK 7 (integration)              [after tasks 2–5 complete]
```

### Suggested subagent distribution (parallel on 3–4 cores):

**Phase 1:** Tasks 1 + 6 (foundation + notifications)
- Agent A: Control-plane client (Task 1) — 40–50 LOC + tests
- Agent B: Notification bridge (Task 6) — 20–30 LOC

**Phase 2:** Tasks 2–5 (UI panels, parallel after Task 1 done)
- Agent C: Menubar + main window (Task 2) — 80–100 LOC
- Agent D: QR panel (Task 3) — 60–80 LOC
- Agent E: Devices + Sessions panels (Tasks 4 + 5) — 100–120 LOC

**Phase 3:** Task 7 (integration, after all above)
- Final agent: Build config + smoke test + mobile compat check

---

## Tech Decisions to Confirm

### 1. Menubar Implementation
- **Option A:** `tray_manager` + `window_manager` (pure Dart, easier to share code with mobile)
- **Option B:** Native `NSStatusItem` shell (better macOS feel, requires Swift)
- **Recommendation:** Start with **Option A** (code reuse, sufficient for v1). Switch to Option B if UX is noticeably worse.

### 2. Socket Client Library
- **Option A:** Dart `InternetAddress(..., type: InternetAddressType.unix)` + raw bytes (no external deps)
- **Option B:** `package:unix_socket` or similar FFI wrapper
- **Recommendation:** **Option A** — simpler, fewer deps. Mimics the SPEC-daemon-control-plane `control-client.ts` closely.

### 3. Cert Trust for WS Client
- Desktop app connects to `wss://127.0.0.1:<port>` on the same machine.
- Phone pinned the server cert in `pairing/cert.dart`.
- **Recommendation:** Reuse fingerprint from `status` verb (already trusted by phone).

### 4. Spawn `makit start` or Embed Server?
- **Option A:** Desktop app calls `Process.run('makit', ['start'])` (daemon management via CLI)
- **Option B:** Embed server in-process (Flutter can't easily host Node)
- **Recommendation:** **Option A** — one server implementation (SPEC-daemon-control-plane), cleaner separation.

---

## Implementation Order

1. **Read & confirm** tech decisions (30 min spike)
2. **Implement Task 1** (control-plane client) — 1–2 hrs, foundational
3. **Parallel: Task 6 + Task 2** (notifications + menubar) — 2 hrs
4. **Parallel: Task 3 + 4 + 5** (QR, devices, sessions panels) — 3–4 hrs
5. **Integrate & test** (Task 7) — 1–2 hrs

**Total estimate:** ~8–10 hrs of focused coding.

---

## Known Constraints & Risks

### Mobile Compat
- All new code must be gated behind `Platform.isMacOS` or moved to `lib/ui/desktop/`.
- Existing store/transport/notifications remain mobile-first.
- Test on iOS simulator after each phase to catch accidental platform-specific code.

### Daemon Dependency
- Desktop app assumes daemon is running (or can spawn it via `Process.run`).
- If daemon crashes, app should gracefully retry + show an error.

### Local WS Trust
- Phone + desktop both trust 127.0.0.1 WS cert from `status` fingerprint.
- Ensure cert validation logic is in one place (`transport/ws_client.dart`), reused.

### Real-Time Updates
- Initial design polls or uses one-shot reads (simpler). If UX feels slow, add daemon event subscriptions (event stream via control socket).

---

## Success Criteria (Post-Implementation)

- ✅ App launches on macOS, menubar shows state
- ✅ Start/stop daemon from app works
- ✅ QR displays and pairs a device end-to-end
- ✅ Devices list is accurate; revoke works
- ✅ Sessions sync from phone + visible in desktop app
- ✅ Native notification fires on paired event
- ✅ Mobile build unaffected (`flutter analyze` clean for both)
- ✅ Commit + ready to ship
