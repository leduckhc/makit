# SPEC-09 — First-run onboarding wizard + macOS tray polish

**Status:** planned · ready for implementation · **Depends on:** none
**Roadmap:** M1 (onboarding wizard) + M4 (macOS control-app UX polish) from
[`docs/specs/README.md`](./README.md)

**Touches (new):**
`app/lib/pairing/readiness.dart`,
`app/lib/pairing/onboarding_screen.dart`,
`app/test/readiness_test.dart`,
`app/test/onboarding_screen_test.dart`

**Touches (edit):**
`app/lib/app/router.dart` (route `/pair` → wizard),
`app/lib/pairing/pairing_screen.dart` (becomes the "pair" step body),
`app/lib/notifications/notification_service.dart` (expose permission *status*, not just request),
`app/lib/store/connection.dart` (surface a `reachable` probe)

---

## Goal

A brand-new user gets from **installed → paired → first message** without
getting stuck. Replace the passive single `PairingScreen` with a **stateful
readiness wizard** that, for whatever step is currently failing, shows the *one
concrete fix* — not a screenshot carousel (carousels get swiped past, go stale,
and can't clear the real blockers, which are connection/permission gates).

**Non-goal (explicit YAGNI):** marketing screenshot carousel. That's an App
Store / getmakit.dev asset (M2), not in-app.

## The readiness state machine

Model onboarding as an ordered list of gates. The wizard renders the **first
unsatisfied** gate with its fix, and advances automatically as each clears.

```
1. reachable?      → can we reach a makit server at all?
                     fix: "Start the server on your Mac" + the pnpm command,
                          + "Is Tailscale up on both devices?" hint
2. paired?         → do we have stored bearer creds? (connection.paired)
                     fix: Scan QR / paste makit://pair URL  (existing PairingScreen body)
3. notifications?  → OS notification permission granted?
                     fix: "Enable notifications so you're alerted when an agent
                          needs you" → button triggers the OS prompt / deep-links
                          to Settings if previously denied
4. ready           → land on Home
```

Each gate is a pure predicate over already-existing signals plus one new probe:

| Gate | Signal (grounded in current code) |
|------|-----------------------------------|
| reachable | new: `connection.dart` exposes a lightweight reachability result derived from `WsState` + mDNS browse (`MakitConnState.wsState`, `browseLan`) |
| paired | existing `MakitConnState.paired` (`connection.dart:79`) |
| notifications | new: `NotificationService.permissionStatus()` — split the *query* out of the current `init()` which only *requests* (`notification_service.dart:120`) |

`readiness.dart` computes `OnboardingStep` from a `MakitConnState` +
`NotificationPermission`. It is **pure and unit-tested** (`readiness_test.dart`)
— no widgets, no plugins — so every gate transition is verified in isolation.

## Why a wizard, not a redirect tweak

Today `router.dart` only branches on `paired` (redirect to `/pair`). The wizard
keeps that single redirect (`/pair` when `!paired || !ready`) but the `/pair`
screen becomes step-aware. This avoids adding new routes and keeps the
GoRouter-built-once invariant (`router.dart:16` comment) intact.

## Slice split

- **Slice 1 (M1 core):** `readiness.dart` + `OnboardingScreen` wrapping the
  existing pairing UI as step 2, plus the reachable/notifications steps.
  Ships the "never get stuck" outcome. **This is the priority.**
- **Slice 2 (M4 tray polish):** the macOS menu-bar app
  (`app/lib/desktop/tray/`, `app/lib/desktop/screens/`) already has
  status/devices/qr/sessions/session_log screens. Polish = coherent visual
  pass + one-tap server start/stop affordance. **Design-led; needs mockups
  before code** (see open questions). Do NOT start Slice 2 until Slice 1 lands
  and mockups are approved.

## Open questions (must resolve before coding the flagged parts)

1. **Reachability probe cost.** How aggressively do we probe when unpaired
   (no server URL yet)? Proposal: only mDNS browse on `--lan`; otherwise the
   "reachable" gate is informational (show the start-server instructions) and
   auto-advances once a pair URL is scanned. Confirm.
2. **Notifications gate = required or skippable?** Proposal: skippable with a
   "you can enable later in Settings" link, since the core loop works without
   it. Confirm.
3. **Slice 2 scope (M4).** Menu-bar-only vs. a real settings window? Minimum
   surface that feels "done"? Needs a design pass — this spec does not
   prescribe the visual design.

## Test plan (TDD)

- `readiness_test.dart`: table-driven — every `(MakitConnState ×
  NotificationPermission)` combination maps to the expected `OnboardingStep`.
  Red first.
- `onboarding_screen_test.dart`: widget test — given a step, the correct fix UI
  renders and its action fires the right controller call. Reuses the existing
  `pairing_screen_test` patterns.
- No changes to `connection_controller_test.dart` behavior beyond the new
  `reachable`/`permissionStatus` seams.
