# Notifications — actionable approvals, background wake & the Activity record

Makit notifies you when an agent needs input, an approval, or finishes a long
turn. Three slices work together:

| Slice | Spec | When it works |
|-------|------|---------------|
| **Actionable notifications** | [SPEC-08](specs/2026-07-08-SPEC-08-actionable-notifications.md) | App is alive (foreground or backgrounded with a live/recent socket) |
| **Background wake** | [SPEC-07](specs/2026-07-08-SPEC-07-background-wake-notifications.md) | App is force-quit or long-suspended — needs APNs (see [PUSH.md](PUSH.md)) |
| **Activity record** | [SPEC-48](specs/2026-08-09-SPEC-48-status-and-activity.md) | Always, in-app — the durable copy of what happened |

## What you get

- **Status notifications** — session becomes `awaiting-input`, `awaiting-approval`, or finishes while you're away.
- **Actionable notifications** — Approve / Deny / Reply buttons on the lock screen for `confirmAction` and `askUserQuestion` requests.
- **Background wake** — a content-free APNs ping when no device has a live socket; the app reconnects over your tailnet and pulls the real request.
- **Activity** — the bell in the home bar (phone) / sidebar footer (desktop): every
  outcome the app reported, with the error text still attached and copyable.

All session data stays on your private tailnet. APNs carries at most a generic
"you have pending item(s)" alert — never message content. The Activity record is
in-memory and never leaves the device except through the diagnostics log you
choose to send.

## The Activity record (SPEC-48)

An OS notification is a tap on the shoulder that then vanishes, and until SPEC-48
nothing in the product could answer *"which session wanted something, and when?"*
So the same judgement that decides whether to buzz your phone
(`diffStatusNotifications`) now also writes to the in-app record:

| Session moves into | Activity severity |
|---|---|
| `error` | failure |
| `awaiting-input`, `awaiting-approval` | warning |
| `idle`/`exited` **from** `running` | success |
| `running` | nothing (silent by policy) |

These posts are **silent** (`StatusCenter.post(..., silent: true)`): no toast, and
they do not light the unread badge — a session you are looking at already shows its
own status dot, and the OS notification is what handles "you weren't looking". What
was missing was the *history*, and that is what lands in Activity.

What the app tells you about its **own** actions (a failed worktree delete, a
refused port kill, a copied URL) posts loudly instead: a toast plus a permanent,
copyable row. See [SPEC-48](specs/2026-08-09-SPEC-48-status-and-activity.md).

**Not covered:** *which answer* you gave an approval. `connection.responded`
carries only a request id, and threading the answer through would change the
response path SPEC-08 made idempotent — for a fact the `awaiting-approval` row
already implies. Deferred deliberately.

---

## On-device checklist — SPEC-08 (actionable)

Requires a paired iPhone with notification permission granted.

1. Pair the phone with a running `makit` server over Tailscale.
2. Grant notification permission during onboarding (or Settings → Notifications).
3. Open a session, then **background** the app (home button / swipe up).
4. On the desktop, trigger a `confirmAction` from any installed agent extension
   or tool that needs approval (for Pi, this is a `ctx.ui.confirm` request).
5. Within a few seconds the phone shows a notification with **Approve** and
   **Deny**.
6. Tap **Approve** on the lock screen. The agent continues **without** opening
   Makit or navigating to the session.
7. Repeat with `askUserQuestion` → tap **Reply**, type an answer → verify
   `answers[0]` reaches the agent.
8. **Idempotency:** trigger an approval, tap **Approve** on the lock screen,
   then open the app and try to approve again in the dialog → exactly one
   `srv.response` is sent.
9. **Foreground path:** with the app open, trigger an approval → an in-app
   dialog appears (no duplicate notification).
10. **Android:** confirm action buttons and inline reply work when the app
    process is alive.

### Known limitations (SPEC-08)

- Locked-screen **foreground** actions may require unlock on some iOS versions
  before the tap is delivered.
- Requests that arrive while the app is **foreground** are not re-fired as
  notifications if you background without answering (fast-follow).

---

## On-device checklist — SPEC-07 (background wake)

Requires a real iPhone, APNs key configured on the server ([PUSH.md](PUSH.md)),
and a TestFlight or development build with push entitlements.

1. Configure `~/.makit/push.json` (sandbox for dev builds). Restart the server
   and confirm the log line `push: APNs sender active`.
2. Pair the device; confirm `push.register` was sent (Settings → Notifications
   shows "Background wake: registered", or `makit devices` lists a push token).
3. **Force-quit** the app and **lock** the phone.
4. Trigger `confirmAction` on the desktop. Within a few seconds the phone
   buzzes with a generic alert.
5. If the app got background time: the alert upgrades to actionable Approve/Deny;
   tap **Approve** → approval resolves on the desktop.
6. If not: tap the generic alert → app launches, reconnects, presents the
   pending request (dialog or notification).
7. **Force-quit tap capture:** while alive, background so an actionable
   notification is shown; force-quit; tap **Approve** from the lock screen;
   relaunch → queued action drains and approval resolves exactly once.
8. `askUserQuestion` wake → Reply → `answers[0]` reaches the agent.
9. **Privacy:** capture the APNs payload (Console.app) — no session/message
   content present.
10. **Degradation:** remove `push.json` → no wake, Slice-1 only; decline push
    permission → no `push.register`, same fallback.
11. **Revoke:** `makit devices revoke <id>` → no further wakes to that device.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No notifications at all | iOS Settings → Makit → Notifications enabled; permission granted in app |
| Status notifications but no Approve/Deny | Request kind must be `confirmAction` or `askUserQuestion`; `input` has no buttons |
| Actions don't reach agent | WebSocket must be connected or reconnecting; check Connection chip |
| No wake when force-quit | `push.json` on server, push permission on phone, TestFlight/dev build |
| Wake but no approval after tap | Tailscale must be up on phone; server must still be running |

See also [DEVELOPMENT.md](DEVELOPMENT.md) for simulator E2E commands.
