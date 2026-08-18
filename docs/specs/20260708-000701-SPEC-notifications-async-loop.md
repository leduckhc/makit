# SPEC-notifications-async-loop — Notifications: async loop with lock-screen actions

**Status:** scoped · **Depends on:** none (parallel to active work) · **Touches:**
`app/lib/services/notification_service.dart`, `app/lib/ui/notifications/`, `server/src/adapters/`, `app/test/notifications_test.dart`

## Goal

Enable first-time users to stay engaged with running agent sessions from their phone's lock screen. When an agent is awaiting approval (tool call, code review, user input), the app sends a timed notification with quick-action buttons. Users tap an action from the lock screen, the app resolves the approval, and the agent continues — all without unlocking the phone.

## Why

- **Superpowers the lock screen:** A desktop chat UI doesn't live in your pocket. The phone's unique leverage is **"I'm away from my desk but I can unblock an agent waiting on me."**
- **First-timer killer feature:** Users immediately feel the app is indispensable — not a curiosity, but a daily tool for async agent triage.
- **Reduces friction:** Without notifications, users check the app manually ("did my agent make progress?"). With lock-screen actions, they resolve blockers in 2 taps.

## Non-goals

- Rich notifications (images, large payloads). Start simple: title, body, action buttons.
- Deep notification history. Lock-screen actions are ephemeral — once resolved, the notification disappears.
- Cross-device notifications (e.g., watching a desktop agent from a tablet). Start with phone only.

## Design

### Notification types (by session status)

| Status | Trigger | Actions | Timeout |
|---|---|---|---|
| `awaiting-approval` | Server sends `srv.request` frame (approval ack needed) | "Approve" (yes), "Deny" (no), "Review" (open app) | 5 min |
| `session.error` | Unrecoverable error (e.g., auth expired, network timeout) | "Dismiss", "Retry" (resubscribe) | none (persistent) |
| `tool.call.end` + manual review flagged | Agent completed tool call; user set notification policy to "ask on risky" | "View" (navigate to message), "Mark read" | 2 min |

### Flow

```
1. Server detects awaiting-approval (sends srv.request)
   ↓
2. App receives srv.request frame → NotificationService schedules lock-screen alert
   ↓
3. User taps "Approve" from lock screen
   ↓
4. App wakes (background task), resolves approval via reverse RPC (server.approve)
   ↓
5. Session continues; notification clears
```

### Approval payload threading

The server's `srv.request` frame already carries:
- `requestId` (to echo back in the approval)
- `kind` ("ask_user_question" or similar)
- `options` (buttons for the dialog)

The app's `NotificationService` should:
1. Extract `options` → map to lock-screen action buttons
2. Queue the action (via `storeProvider.notifier.resolveApproval(requestId, choice)`)
3. That action triggers a reverse RPC: `server.approve { requestId, choice }`

### Platform-specific notes

- **iOS:** Use `UNUserNotificationCenter` (via `flutter_local_notifications` 22.0.1). Background task handling via `UNNotificationResponse`.
- **macOS:** Similar, but surface as a banner (not lock screen). Users can configure "critical" alerts if they want sound.
- **Android:** Use `NotificationCompat` (via `flutter_local_notifications`). Foreground service keeps the session alive during notification action handling.

## Acceptance criteria

- [ ] On `srv.request` frame, app schedules a notification with appropriate action buttons
- [ ] Tapping an action from the lock screen (without opening the app) resolves the approval
- [ ] Server-side approval ack is sent via reverse RPC (`server.approve`)
- [ ] Notification clears once the session leaves `awaiting-approval` status
- [ ] Unit tests: mock `NotificationService`, verify `storeProvider` receives the action
- [ ] Integration test: `srv.request` → lock-screen action → session continues (E2E with stub server)

## Risks & mitigation

| Risk | Mitigation |
|---|---|
| Background task thread safety (Android) | Use `WorkManager` for reliable background execution; test with device rotation + low memory kills |
| Notification permission denied | Graceful fallback: app-foreground dialog only (status quo). No breakage. |
| Race: user taps action before app receives ack | Idempotent approval: server dedupes by `(sessionId, requestId)` + timestamp |
| User spam (approves all notifications blindly) | Future: rate-limit approvals server-side; add "I didn't send that" reverse-action for now |

## Open questions

- Should notifications persist across app restarts? (Probably yes, tied to session ID.)
- Should we batch multiple pending approvals into one notification, or one per request? (Start simple: one per.)
- Notification sound/haptic on lock screen, or silent? (Silent by default; user can configure.)

## Rollout

1. **Phase 1:** Basic scaffold (notification service, lock-screen action handling, reverse RPC threading).
2. **Phase 2:** Platform-specific refinement (iOS background task reliability, Android foreground service).
3. **Phase 3:** Notification history + settings UI (let users control which session types notify).
